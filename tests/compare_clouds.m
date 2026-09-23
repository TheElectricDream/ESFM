function S = compare_clouds(A, B, label_a, label_b, opts)
% Similarity-align point cloud A onto B and report shape agreement.
%
%   S = compare_clouds(A, B, 'candidate', 'reference')
%
% Both clouds are arbitrary reconstructions of the same object in different
% gauges (origin, body-frame orientation, scale), so a single declared
% similarity transform is fitted before any distance is reported. The fit is
% robust ICP seeded from the principal axes; the seed with the lowest trimmed
% cost wins. Distances are reported BOTH ways: A->B says how much of A is
% explained by B, B->A says how much of B is covered by A. Neither is a
% ground-truth error when B is itself a reconstruction.
if nargin < 3, label_a = 'A'; end
if nargin < 4, label_b = 'B'; end
if nargin < 5, opts = struct(); end
if ~isfield(opts,'trim'),   opts.trim = 0.8;  end   % inlier fraction used by ICP
if ~isfield(opts,'iters'),  opts.iters = 60;  end
if ~isfield(opts,'fix_scale'), opts.fix_scale = false; end

ca = mean(A,1); cb = mean(B,1);
[~,~,Va] = svd(A-ca,0); [~,~,Vb] = svd(B-cb,0);
if det(Va) < 0, Va(:,3) = -Va(:,3); end
if det(Vb) < 0, Vb(:,3) = -Vb(:,3); end
sa = norm(A-ca,'fro')/sqrt(size(A,1)); sb = norm(B-cb,'fro')/sqrt(size(B,1));
best = struct('cost',inf);
signs = [1 1 1; 1 -1 -1; -1 1 -1; -1 -1 1];            % det = +1 flips
for k = 1:4
    for spin = 0:3                                      % coarse spin about axis 1
        th = spin*pi/2;
        Rspin = [1 0 0; 0 cos(th) -sin(th); 0 sin(th) cos(th)];
        R0 = Vb*Rspin*diag(signs(k,:))*Va';
        s0 = 1; if ~opts.fix_scale, s0 = sb/sa; end
        t0 = cb' - s0*R0*ca';
        f = icp_similarity(A,B,R0,s0,t0,opts);
        if f.cost < best.cost, best = f; end
    end
end
Aw = (best.s*(best.R*A') + best.t)';
S = best;
S.A_aligned = Aw;
[dab, ~] = nn_dist(Aw, B);
[dba, ~] = nn_dist(B, Aw);
S.rms_a_to_b    = sqrt(mean(dab.^2));
S.median_a_to_b = median(dab);
S.p90_a_to_b    = prctile(dab,90);
S.rms_b_to_a    = sqrt(mean(dba.^2));
S.median_b_to_a = median(dba);
S.p90_b_to_a    = prctile(dba,90);
S.scale = best.s;
S.n_a = size(A,1); S.n_b = size(B,1);
fprintf(['%s -> %s : %d vs %d points, fitted scale %.4f\n' ...
         '  %s->%s  median %.4f  rms %.4f  p90 %.4f\n' ...
         '  %s->%s  median %.4f  rms %.4f  p90 %.4f\n'], ...
    label_a,label_b,S.n_a,S.n_b,S.scale, ...
    label_a,label_b,S.median_a_to_b,S.rms_a_to_b,S.p90_a_to_b, ...
    label_b,label_a,S.median_b_to_a,S.rms_b_to_a,S.p90_b_to_a);
end

function f = icp_similarity(A,B,R,s,t,opts)
for it = 1:opts.iters
    Aw = (s*(R*A') + t)';
    [d, j] = nn_dist(Aw, B);
    thr = quantile(d, opts.trim);
    m = d <= thr;
    if nnz(m) < 4, break; end
    [R,s,t] = umeyama(A(m,:), B(j(m),:), opts.fix_scale);
end
Aw = (s*(R*A') + t)';
d = nn_dist(Aw, B);
f = struct('R',R,'s',s,'t',t,'cost',mean(mink(d,max(4,round(opts.trim*numel(d))))));
end

function [R,s,t] = umeyama(P,Q,fix_scale)
% Least-squares similarity Q ~ s R P + t (Umeyama 1991).
mp = mean(P,1); mq = mean(Q,1);
X = P-mp; Y = Q-mq;
C = (Y'*X)/size(P,1);
[U,D,V] = svd(C);
S = eye(3); if det(U*V') < 0, S(3,3) = -1; end
R = U*S*V';
if fix_scale, s = 1; else, s = trace(D*S)/max(mean(sum(X.^2,2)),eps); end
t = mq' - s*R*mp';
end

function [d,j] = nn_dist(P,Q)
[j,d] = knnsearch(Q,P);
end
