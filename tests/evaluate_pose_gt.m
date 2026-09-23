function S = evaluate_pose_gt(run_dir, gt_csv, hdf5_path, opts)
% Ground-truth comparison with ONE constant frame alignment, never per-frame.
% opts.fit_interval=[t0 t1] limits alignment to a calibration prefix. Pass
% opts.alignment=S.alignment to evaluate another run with identical frames.
% Scale is FIXED to the saved wingspan calibration unless opts.fit_scale=true.
% Fitted-scale results are alignment residuals, not independent metric accuracy.
% The CSV supplies platform poses, not camera/body mounting extrinsics. We use
% the target pose relative to the red platform, including measured red motion.
% opts.pose_file selects poses.csv (live) or reconstruction_poses.csv (refined).
if nargin < 2 || isempty(gt_csv)
    gt_csv = ['/run/media/alexandercrain/Secondary_Drive/Dataset Release 1/ROT-SG/' ...
              'tracker_data_20251029_131131-processed.csv'];
end
if nargin < 3 || isempty(hdf5_path)
    hdf5_path = ['/run/media/alexandercrain/Secondary_Drive/Dataset Release 1/ROT-SG/' ...
                 'recording_20251029_131131.hdf5'];
end
if nargin < 4, opts = struct(); end
if ~isfield(opts,'status'), opts.status = [0 1]; end   % 0 = build, 1 = measured
if ~isfield(opts,'radius_m'), opts.radius_m = 0.6; end % lever arm used to weight rotation
if ~isfield(opts,'plot_dir'), opts.plot_dir = run_dir; end
if ~isfield(opts,'pose_file'), opts.pose_file = 'poses.csv'; end
if ~isfield(opts,'fit_interval'), opts.fit_interval = [-inf inf]; end
if ~isfield(opts,'fit_scale'), opts.fit_scale = false; end

% ---- estimate ----
P = readtable(fullfile(run_dir,opts.pose_file));
M = load(fullfile(run_dir,'frozen_model.mat'));
s_assumed = M.model.scale.m_per_unit;
keep = ismember(P.status, opts.status) & isfinite(P.R11) & isfinite(P.tx_model);
P = P(keep,:);
% Buffering can log the same estimate repeatedly. Count each timestamp once.
[~,j] = unique(P.time_s,'last'); P = sortrows(P(j,:),'time_s');
assert(height(P) > 50, 'Too few usable pose rows (%d).', height(P));
n = height(P);
Rest = zeros(3,3,n);
cols = {'R11','R21','R31','R12','R22','R32','R13','R23','R33'};
for k = 1:9
    [i,j] = ind2sub([3 3], k);              % column-major serialization
    Rest(i,j,:) = P.(cols{k});
end
Test = [P.tx_model, P.ty_model, P.tz_model];
te = P.time_s;

% ---- ground truth on the recording clock ----
ti=h5info(hdf5_path,'/timestamp');
first=ones(size(ti.Dataspace.Size));
ts0 = double(h5read(hdf5_path,'/timestamp',first,first));
G = readtable(gt_csv);
tg = (G.system_time_us - ts0)/1e6;
[tg,j] = unique(tg); G=G(j,:);
yaw = unwrap(G.black_angle)-unwrap(G.red_angle);
dx=(G.black_x-G.red_x)/1000; dy=(G.black_y-G.red_y)/1000;
cr=cos(G.red_angle); sr=sin(G.red_angle);
pos=[cr.*dx+sr.*dy, -sr.*dx+cr.*dy, zeros(height(G),1)];
ok = te >= tg(1) & te <= tg(end);
fprintf('%d/%d pose rows lie inside the ground-truth interval [%.2f %.2f] s\n', ...
    nnz(ok), numel(ok), tg(1), tg(end));
assert(nnz(ok) > 50, 'Pose log and ground truth barely overlap.');
Rest = Rest(:,:,ok); Test = Test(ok,:); te = te(ok); n = numel(te);
psi = interp1(tg, yaw, te, 'linear');
p   = interp1(tg, pos, te, 'linear');
rate_gt = gradient(psi, te);

% ---- fit F, G, s ----
a_seed = principal_axis(Rest);
F0 = frame_from_axis(a_seed);
x0 = [rotlog(F0); [0;0;2.3]; zeros(3,1); zeros(3,1); log(s_assumed)];
fit = te>=opts.fit_interval(1) & te<=opts.fit_interval(2);
if ~isfield(opts,'alignment'), assert(nnz(fit)>20,'Too few alignment samples.'); end
ii=find(fit); ii=ii(unique(round(linspace(1,numel(ii),min(300,numel(ii))))));
% Planar motion cannot identify offsets along the spin axis separately.
% Fix the target-body z offset to zero to remove that translation gauge.
if opts.fit_scale
    x0=[x0(1:11);x0(13)]; expand=@(x) [x(1:11);0;x(12)];
else
    x0=x0(1:11); expand=@(x) [x;0;log(s_assumed)];
end
res = @(x) residual(expand(x), Rest(:,:,ii), Test(ii,:), psi(ii), p(ii,:), opts.radius_m);
o = optimoptions('lsqnonlin','Display','off','MaxFunctionEvaluations',2e4, ...
    'MaxIterations',500,'FunctionTolerance',1e-12,'StepTolerance',1e-12, ...
    'Algorithm','levenberg-marquardt');
best = struct('cost',inf);
if isfield(opts,'alignment')
    best.x=opts.alignment.x;
else
for spin = 0:1                     % the axis sign / quarter-turn seeds
    for sgn = [1 -1]
        xs = x0; xs(1:3) = rotlog(frame_from_axis(sgn*a_seed)*rotz(spin*pi/2));
        [x,cost] = lsqnonlin(res, xs, [], [], o);
        if cost < best.cost, best = struct('x',x,'cost',cost); end
    end
end
best.x=expand(best.x);
end
x = best.x;
% Normalize older saved alignments to the same harmless axial gauge.
x(4:6)=x(4:6)+rotexp(x(1:3))*[0;0;x(12)];x(12)=0;
[r, d] = residual(x, Rest, Test, psi, p, opts.radius_m); %#ok<ASGLU>

S = struct();
S.alignment=struct('x',x,'fit_interval',opts.fit_interval, ...
    'scale_fitted',opts.fit_scale,'convention','H_cam_obj = F H_red_black G');
if isfield(opts,'alignment'),S.alignment=opts.alignment;S.alignment.x=x;end
S.fit_mask=fit; S.position_residual_m=d.pos; S.rotation_residual_rad=d.rot;
S.scale_fitted_m_per_unit = exp(x(13));
S.scale_assumed_m_per_unit = s_assumed;
S.implied_width_m = M.model.scale.known_width_m * ...
    S.scale_fitted_m_per_unit / s_assumed;
S.rot_err_deg = d.rot_deg;
S.pos_err_m = d.pos_m;
S.time_s = te;
S.status = P.status(ok);
% Incremental SO(3) rate divided by actual seconds (supports irregular logs).
wr=zeros(n-1,1);
for k=2:n
    wr(k-1)=dot(rotlog(Rest(:,:,k)*Rest(:,:,k-1)'),d.axis)/(te(k)-te(k-1));
end
S.rate_est_deg_s=rad2deg([wr(1);wr]);
S.rate_gt_deg_s = rad2deg(rate_gt);
S.axis_cam = d.axis;

fprintf('\n--- constant-transform fit (%d samples) ---\n', n);
fprintf('metric scale : used %.4f m/unit vs assumed %.4f m/unit (%.2f %% apart)\n', ...
    S.scale_fitted_m_per_unit, s_assumed, 100*(S.scale_fitted_m_per_unit/s_assumed-1));
fprintf('               => implied physical wingspan %.4f m (assumed %.3f m)\n', ...
    S.implied_width_m, M.model.scale.known_width_m);
fprintf('camera position in red platform frame (axial gauge chosen)      : [%.3f %.3f %.3f] m\n', d.cam_lab);
fprintf('object origin in target body: [%.4f %.4f %.4f] m\n', d.origin_body);
fprintf('rotation axis in camera     : [%.4f %.4f %.4f]\n', d.axis);
fprintf('\n--- pose residual after constant alignment (scale fixed unless requested) ---\n');
for st = unique(S.status)'
    m = S.status == st;
    if ~any(m), continue; end
    fprintf('status %d (%d rows, %.1f-%.1f s):\n', st, nnz(m), min(te(m)), max(te(m)));
    fprintf('   orientation  rms %.3f deg   median %.3f   p95 %.3f   max %.3f\n', ...
        rms_(S.rot_err_deg(m)), median(S.rot_err_deg(m)), ...
        prctile(S.rot_err_deg(m),95), max(S.rot_err_deg(m)));
    fprintf('   position     rms %.1f mm    median %.1f    p95 %.1f    max %.1f\n', ...
        1e3*rms_(S.pos_err_m(m)), 1e3*median(S.pos_err_m(m)), ...
        1e3*prctile(S.pos_err_m(m),95), 1e3*max(S.pos_err_m(m)));
    fprintf('   spin rate    rms %.4f deg/s  (truth mean %.3f deg/s, sd %.3f)\n', ...
        rms_(S.rate_est_deg_s(m)-S.rate_gt_deg_s(m)), ...
        mean(S.rate_gt_deg_s(m)), std(S.rate_gt_deg_s(m)));
end

if ~isempty(opts.plot_dir)
    f = figure('Visible','off','Position',[0 0 1100 800],'Color','w');
    subplot(3,1,1); plot(te,S.rot_err_deg,'.'); grid on
    ylabel('orientation error [deg]'); title('Pose residual against SPOT platform ground truth');
    subplot(3,1,2); plot(te,1e3*S.pos_err_m,'.'); grid on; ylabel('position error [mm]');
    subplot(3,1,3); plot(te,S.rate_gt_deg_s,'-',te,S.rate_est_deg_s,'.'); grid on
    ylabel('spin rate [deg/s]'); xlabel('time in recording [s]');
    legend({'ground truth','estimate'},'Location','best');
    exportgraphics(f, fullfile(opts.plot_dir,'fig_pose_vs_groundtruth.png'),'Resolution',130);
    close(f);
    save(fullfile(opts.plot_dir,'pose_evaluation.mat'),'S','opts');
    fprintf('\nwrote %s\n', fullfile(opts.plot_dir,'fig_pose_vs_groundtruth.png'));
end
end

% ------------------------------------------------------------------------
function [r, d] = residual(x, Rest, Test, psi, p, radius)
RF = rotexp(x(1:3)); tF = x(4:6);
RG = rotexp(x(7:9)); tG = x(10:12);
s  = exp(x(13));
n = numel(psi);
rot = zeros(n,3); pos = zeros(n,3); rate = zeros(n,1);
for k = 1:n
    Rl = rotz(psi(k));
    Rp = RF*Rl*RG;
    rot(k,:) = rotlog(Rest(:,:,k)'*Rp)';
    pos(k,:) = s*Test(k,:) - (RF*(Rl*tG + p(k,:)') + tF)';
end
r = [radius*rot(:); pos(:)];
if nargout > 1
    d.rot_deg = rad2deg(vecnorm(rot,2,2));
    d.pos_m = vecnorm(pos,2,2);
    d.cam_lab = (-RF'*tF)';
    d.origin_body = tG';
    d.axis = (RF*[0;0;1])';
    d.pos=pos; d.rot=rot;
end
end

function a = principal_axis(R)
% Mean rotation-increment axis over the log, in the camera frame.
n = size(R,3); v = zeros(3,1);
for k = 2:n
    w = rotlog(R(:,:,k)*R(:,:,k-1)');
    if norm(w) > 1e-9, v = v + w; end
end
a = v/max(norm(v),eps);
end

function F = frame_from_axis(a)
a = a(:)/norm(a);
u = [1;0;0]; if abs(a(1)) > 0.9, u = [0;1;0]; end
u = u - a*(a'*u); u = u/norm(u);
F = [u, cross(a,u), a];
end

function R = rotz(t), R = [cos(t) -sin(t) 0; sin(t) cos(t) 0; 0 0 1]; end

function R = rotexp(a)
th = norm(a); K = [0 -a(3) a(2); a(3) 0 -a(1); -a(2) a(1) 0];
if th < 1e-9, R = eye(3) + K; [U,~,V] = svd(R); R = U*V';
else, R = eye(3) + sin(th)/th*K + (1-cos(th))/th^2*(K*K); end
end

function a = rotlog(R)
th = acos(max(-1,min(1,(trace(R)-1)/2)));
v = [R(3,2)-R(2,3); R(1,3)-R(3,1); R(2,1)-R(1,2)];
if th < 1e-7, a = v/2;
elseif pi-th < 1e-6
    [V,D] = eig((R+R')/2); [~,j] = max(diag(D)); ax = V(:,j);
    if ax'*v < 0, ax = -ax; end
    a = th*ax;
else, a = th/(2*sin(th))*v; end
end

function y = rms_(x), y = sqrt(mean(x.^2)); end
