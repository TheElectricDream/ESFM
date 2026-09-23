%% Inspect the result of warm.sweep_axes
% Run in the SAME workspace immediately after:
%   fits = warm.sweep_axes(resid, nll, c0, V0, wcfg);
% Required: fits, tau, fi, ii, uv, nn, ntracks, cam, wcfg.
% Uses your warm.twist_structure, geom.project, and warm.cauchy functions.
% No optimization is rerun. Geometry is reconstructed for one candidate.
% No clear/close commands; existing inputs and figures are preserved.
%
% This assesses consistency with the fitted data, not ground-truth accuracy.
% All coordinates are in the reconstruction's temporary scale, not metres.

sweep_inspection_rank = 1;    % 1 = best stored cost; try 2 or 3 to compare
sweep_inspection_slice = []; % [] = slice with most valid projections
                            % Set an integer slice index to inspect another

assert(exist('fits','var')==1 && exist('tau','var')==1 && ...
    exist('fi','var')==1 && exist('ii','var')==1 && ...
    exist('uv','var')==1 && exist('nn','var')==1 && ...
    exist('ntracks','var')==1 && exist('cam','var')==1 && ...
    exist('wcfg','var')==1, ...
    'Required: fits, tau, fi, ii, uv, nn, ntracks, cam, wcfg.');
assert(~isempty(fits),'The sweep returned no candidates.');

sw = struct;
sw.cost = reshape([fits.cost],[],1);
sw.rate = reshape([fits.w],[],1);
sw.seed = reshape([fits.seed],[],1);
sw.axes = reshape([fits.a],3,[])';
sw.q = reshape([fits.q],5,[])';
sw.valid = isfinite(sw.cost) & isfinite(sw.rate) & ...
    all(isfinite(sw.axes),2) & all(isfinite(sw.q),2);
sw.validIDs = find(sw.valid);
assert(~isempty(sw.validIDs),'No candidates have finite costs and parameters.');
[~,sw.order] = sort(sw.cost(sw.validIDs));
sw.rankedIDs = sw.validIDs(sw.order);
validateattributes(sweep_inspection_rank,{'numeric'}, ...
    {'scalar','integer','>=',1,'<=',numel(sw.rankedIDs)});
sw.id = sw.rankedIDs(sweep_inspection_rank);
sw.fit = fits(sw.id);
sw.fi = fi(:); sw.ii = ii(:); sw.tau = tau(:);
sw.F = numel(sw.tau); sw.M = numel(sw.fi);
assert(sw.M>0 && numel(sw.ii)==sw.M && ...
    isequal(size(uv),[sw.M 2]) && isequal(size(nn),[sw.M 2]), ...
    'Observation array sizes are inconsistent.');
assert(all(sw.fi>=1 & sw.fi<=sw.F & sw.fi==fix(sw.fi)) && ...
    all(sw.ii>=1 & sw.ii<=ntracks & sw.ii==fix(sw.ii)), ...
    'Invalid slice or track indices.');

%% Reconstruct and reproject this candidate using the actual project code
[sw.X,sw.R,sw.T] = warm.twist_structure( ...
    sw.fit.a,sw.fit.w,sw.fit.q,sw.tau,sw.fi,sw.ii,uv,nn,ntracks,cam,wcfg);
[sw.projected,sw.Y] = geom.project(sw.R,sw.T,sw.X(sw.ii,:),cam);
sw.rawResidual = sum((uv-sw.projected).*nn,2);
sw.depthBad = isfinite(sw.Y(:,3)) & sw.Y(:,3)<wcfg.min_depth;
sw.good = all(isfinite(sw.Y),2) & sw.Y(:,3)>=wcfg.min_depth & ...
    all(isfinite(sw.projected),2) & all(isfinite(uv),2) & ...
    all(isfinite(nn),2) & isfinite(sw.rawResidual);
sw.invalid = ~sw.good;

% Reproduce the supplied twist_residual's fixed invalid-depth penalty.
sw.solverResidual = sw.rawResidual;
sw.solverResidual(sw.Y(:,3)<wcfg.min_depth) = 10;
sw.cauchyCost = sum(warm.cauchy(sw.solverResidual,wcfg.cauchy_px).^2);
sw.count = accumarray(sw.fi,1,[sw.F 1]);
sw.goodCount = accumarray(sw.fi(sw.good),1,[sw.F 1]);
if isempty(sweep_inspection_slice)
    if any(sw.goodCount)
        [~,sw.slice] = max(sw.goodCount);
    else
        [~,sw.slice] = max(sw.count);
    end
else
    validateattributes(sweep_inspection_slice,{'numeric'}, ...
        {'scalar','integer','>=',1,'<=',sw.F});
    sw.slice = sweep_inspection_slice;
end

% a*w removes the representational ambiguity between (a,w) and (-a,-w).
sw.omega = sw.axes .* sw.rate * (180/pi);
sw.topCount = min(20,numel(sw.rankedIDs));
sw.top = sw.rankedIDs(1:sw.topCount);
sw.topTable = table((1:sw.topCount)',sw.top,sw.cost(sw.top), ...
    rad2deg(sw.seed(sw.top)),rad2deg(sw.rate(sw.top)), ...
    sw.omega(sw.top,1),sw.omega(sw.top,2),sw.omega(sw.top,3), ...
    'VariableNames',{'Rank','FitIndex','StoredCost','Seed_deg_s', ...
    'FittedRate_deg_s','OmegaX_deg_s','OmegaY_deg_s','OmegaZ_deg_s'});
fprintf('\nSWEEP INSPECTION: candidate rank %d, fits(%d)\n', ...
    sweep_inspection_rank,sw.id);
fprintf('Finite candidates: %d / %d\n',numel(sw.validIDs),numel(fits));
fprintf('Axis = [%.6f %.6f %.6f]; signed rate = %.6f deg/s\n', ...
    sw.fit.a(1),sw.fit.a(2),sw.fit.a(3),rad2deg(sw.fit.w));
fprintf('Stored score = %.9g; recomputed sum(Cauchy residuals.^2) = %.9g\n', ...
    sw.fit.cost,sw.cauchyCost);
fprintf('These scores should agree if nll uses that same definition.\n');
fprintf('Below min_depth: %d / %d; invalid for plotting: %d / %d\n', ...
    nnz(sw.depthBad),sw.M,nnz(sw.invalid),sw.M);
if any(sw.good)
    fprintf('Valid-depth normal errors: median absolute %.4g px; RMS %.4g px\n', ...
        median(abs(sw.rawResidual(sw.good))),sqrt(mean(sw.rawResidual(sw.good).^2)));
end
fprintf('Chosen slice: %d, tau = %.6f s\n',sw.slice,sw.tau(sw.slice));
fprintf('Top candidates (near-equal scores need not mean the same geometry):\n');
disp(sw.topTable);
if any(sw.invalid)
    warning('Selected candidate has invalid observations. Inspect depth counts; a low cost is not sufficient.');
end

%% Figure 1: candidate search and reconstructed geometry
sw.figure = figure('Color','w','Name','Axis sweep inspection', ...
    'Position',[60 60 1350 820]);
tiledlayout(2,3,'TileSpacing','compact','Padding','compact');

% 1. Physical angular velocity, rather than the redundant axis/rate pair.
nexttile; hold on;
scatter3(sw.omega(sw.valid,1),sw.omega(sw.valid,2),sw.omega(sw.valid,3), ...
    38,sw.cost(sw.valid),'filled');
plot3(sw.omega(sw.id,1),sw.omega(sw.id,2),sw.omega(sw.id,3), ...
    'rp','MarkerSize',15,'LineWidth',2);
axis equal; grid on; view(35,25);
xlabel('\omega_x [deg/s]'); ylabel('\omega_y [deg/s]'); zlabel('\omega_z [deg/s]');
cb = colorbar; cb.Label.String = 'Stored cost (lower is better)';
title({'Fitted angular velocities a*w','Red star = inspected candidate'});

% 2. Did different starting speeds lead to different fitted speeds?
nexttile; hold on;
scatter(abs(rad2deg(sw.seed(sw.valid))),abs(rad2deg(sw.rate(sw.valid))), ...
    30,sw.cost(sw.valid),'filled');
plot(abs(rad2deg(sw.seed(sw.id))),abs(rad2deg(sw.rate(sw.id))), ...
    'rp','MarkerSize',15,'LineWidth',2);
grid on; xlabel('Starting angular speed [deg/s]');
ylabel('Fitted angular speed [deg/s]');
title('Dependence on starting rate (absolute speeds)');

% 3. Top scores do not constitute a confidence interval.
nexttile;
plot(1:sw.topCount,sw.cost(sw.top),'ko-','MarkerFaceColor',[0.2 0.5 0.8]);
grid on; xlabel('Candidate rank'); ylabel('Stored cost');
title('Best scores: similar values can hide ambiguity');

% 4. Candidate object-frame point cloud, with no geometric outlier trimming.
nexttile;
sw.finitePoints = all(isfinite(sw.X),2);
scatter3(sw.X(sw.finitePoints,1),sw.X(sw.finitePoints,2), ...
    sw.X(sw.finitePoints,3),18,'filled');
axis equal; grid on; view(35,25);
xlabel('Object x'); ylabel('Object y'); zlabel('Object z');
title({'Candidate triangulated structure','Temporary scale, not metres'});

% 5. One slice: observed points and their corresponding predictions.
nexttile; hold on;
sw.rows = find(sw.fi==sw.slice & sw.good);
sw.observedRows = find(sw.fi==sw.slice & all(isfinite(uv),2));
if ~isempty(sw.rows)
    sw.U = uv(sw.rows,:); sw.P = sw.projected(sw.rows,:);
    sw.segX = [sw.U(:,1) sw.P(:,1) nan(numel(sw.rows),1)]';
    sw.segY = [sw.U(:,2) sw.P(:,2) nan(numel(sw.rows),1)]';
    plot(sw.segX(:),sw.segY(:),'-','Color',[0.7 0.7 0.7], ...
        'HandleVisibility','off');
end
plot(uv(sw.observedRows,1),uv(sw.observedRows,2),'ko', ...
    'MarkerSize',5,'DisplayName','Observed');
plot(sw.projected(sw.rows,1),sw.projected(sw.rows,2),'r+', ...
    'MarkerSize',6,'DisplayName','Predicted (valid depth)');
axis equal; set(gca,'YDir','reverse'); grid on;
xlabel('u [pixels]'); ylabel('v [pixels]');
title({sprintf('Slice %d, tau = %.3f s',sw.slice,sw.tau(sw.slice)), ...
    'Gray segments: full 2-D error, not the scored residual'});
legend('Location','best');

% 6. Show actual normal errors, without substituting the depth penalty.
nexttile;
if any(sw.good)
    histogram(sw.rawResidual(sw.good),40);
    xline(0,'k-'); xline(wcfg.cauchy_px,'r--'); xline(-wcfg.cauchy_px,'r--');
    xlabel('Signed edge-normal error [pixels]'); ylabel('Observation count');
    title({'Raw normal errors at valid depths','Red lines = Cauchy scale (not a rejection cutoff)'});
    grid on;
else
    axis off; text(0.1,0.5,'No valid-depth residuals to display','Units','normalized');
end
sgtitle(sprintf('Sweep candidate rank %d: fit quality does not establish physical correctness', ...
    sweep_inspection_rank));

%% Figure 2: show whether fit/depth quality varies over the window
sw.timeFigure = figure('Color','w','Name','Sweep fit through time');
tiledlayout(2,1,'TileSpacing','compact');
sw.medianNormal = nan(sw.F,1);
for sw_f = 1:sw.F
    sw_mask = sw.fi==sw_f & sw.good;
    if any(sw_mask)
        sw.medianNormal(sw_f) = median(abs(sw.rawResidual(sw_mask)));
    end
end
nexttile;
plot(sw.tau,sw.medianNormal,'b.-'); grid on;
xlabel('tau [s]'); ylabel('Median absolute normal error [pixels]');
title('Valid-depth observations only; empty slices remain gaps');
nexttile; hold on;
plot(sw.tau,sw.count,'k-','DisplayName','All observations');
plot(sw.tau,sw.goodCount,'b-','DisplayName','Valid projections and depths');
grid on; xlabel('tau [s]'); ylabel('Observation count');
legend('Location','best'); title('A low error should not conceal invalid geometry');

% Results remain in sw, including X, projected, Y, rawResidual and topTable.
% fits does not store lsqnonlin exit flags, so convergence cannot be
% certified from this struct. Save exit flags in sweep_axes if needed.
