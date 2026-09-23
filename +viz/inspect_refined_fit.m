%% Compare a coarse sweep candidate with its refined result
% Required workspace variables:
%   bestCoarse, bestRefined, tau, fi, ii, uv, nn, ntracks, cam, wcfg
% Call refine_fit on bestCoarse to obtain bestRefined BEFORE this script.
% This script does not run optimization or modify either input fit.
% Requires warm.twist_structure, geom.project, warm.cauchy on your path.
% Outputs: comparison (metrics table), rf (geometry and diagnostics).
% No ground truth is assumed. Improvements mean fit to the SAME input data.
% Geometry is shown in the same original frame and temporary scale, without
% alignment, rescaling, or outlier removal that could disguise differences.

refinement_inspection_slice = []; % [] picks the best-supported common slice
                                  % or set a specific integer slice index

assert(exist('bestCoarse','var')==1 && exist('bestRefined','var')==1 && ...
    exist('tau','var')==1 && exist('fi','var')==1 && exist('ii','var')==1 && ...
    exist('uv','var')==1 && exist('nn','var')==1 && exist('ntracks','var')==1 && ...
    exist('cam','var')==1 && exist('wcfg','var')==1, ...
    'Define bestCoarse, bestRefined and the original observation inputs first.');

rf = struct;
rf.tau = tau(:); rf.fi = fi(:); rf.ii = ii(:);
rf.F = numel(rf.tau); rf.M = numel(rf.fi);
rf.colors = [0.1 0.35 0.85; 0.9 0.3 0.05];
rf.labels = {'Coarse','Refined'};
assert(rf.F>0 && rf.M>0 && numel(rf.ii)==rf.M && ...
    isequal(size(uv),[rf.M 2]) && isequal(size(nn),[rf.M 2]), ...
    'Inconsistent observation dimensions.');
assert(all(rf.fi>=1 & rf.fi<=rf.F & rf.fi==fix(rf.fi)) && ...
    all(rf.ii>=1 & rf.ii<=ntracks & rf.ii==fix(rf.ii)), ...
    'Invalid slice or retained-track indices.');
assert(isscalar(wcfg.free_mean_velocity),'Expected scalar free_mean_velocity.');
rf.fits = {bestCoarse,bestRefined};
for rf_k = 1:2
    rf_fit = rf.fits{rf_k};
    assert(numel(rf_fit.a)==3 && numel(rf_fit.q)==5 && ...
        isfinite(rf_fit.w) && all(isfinite(rf_fit.a(:))) && ...
        all(isfinite(rf_fit.q(:))), 'Malformed fit.');
    assert(abs(norm(rf_fit.a)-1)<1e-6,'Candidate axis is not unit length.');
    [rf_X,rf_R,rf_T] = warm.twist_structure(rf_fit.a,rf_fit.w,rf_fit.q, ...
        rf.tau,rf.fi,rf.ii,uv,nn,ntracks,cam,wcfg);
    [rf_pr,rf_Y] = geom.project(rf_R,rf_T,rf_X(rf.ii,:),cam);
    rf_raw = sum((uv-rf_pr).*nn,2);
    rf_valid = all(isfinite(rf_Y),2) & rf_Y(:,3)>=wcfg.min_depth & ...
        all(isfinite(rf_pr),2) & all(isfinite(uv),2) & ...
        all(isfinite(nn),2) & isfinite(rf_raw);
    rf_penalized = rf_raw;
    rf_penalized(rf_Y(:,3)<wcfg.min_depth) = 10;
    rf.data(rf_k).X = rf_X;
    rf.data(rf_k).pr = rf_pr;
    rf.data(rf_k).Y = rf_Y;
    rf.data(rf_k).raw = rf_raw;
    rf.data(rf_k).valid = rf_valid;
    rf.data(rf_k).penalized = rf_penalized;
    % Keep both score conventions visible: gold nll omits the scale^2 factor.
    rf.goldCost(rf_k,1) = sum(log1p((rf_penalized/wcfg.cauchy_px).^2));
    rf.solverCost(rf_k,1) = sum(warm.cauchy(rf_penalized,wcfg.cauchy_px).^2);
    rf.storedCost(rf_k,1) = rf_fit.cost;
    rf.invalidCount(rf_k,1) = nnz(~rf_valid);
    rf.belowDepth(rf_k,1) = nnz(isfinite(rf_Y(:,3)) & rf_Y(:,3)<wcfg.min_depth);
    rf.omega(rf_k,:) = rad2deg(rf_fit.w*rf_fit.a(:)');
    rf_q = rf_fit.q(:)';
    rf.centres(:,:,rf_k) = [rf_q(1:2) 1] + ...
        rf.tau*(rf_q(3:5)*double(wcfg.free_mean_velocity));
    % Rotation quaternion for R(tau)=exp([a*w*tau]_x), same initial frame.
    rf.halfAngle = .5*rf_fit.w*rf.tau;
    rf.quaternion(:,:,rf_k) = [cos(rf.halfAngle), ...
        sin(rf.halfAngle)*rf_fit.a(:)'];
end

% Compare raw errors on IDENTICAL observations valid under BOTH models.
rf.common = rf.data(1).valid & rf.data(2).valid;
rf.commonCount = nnz(rf.common);
rf.medianAbs = nan(2,1); rf.rms = nan(2,1); rf.p95 = nan(2,1);
rf.byTime = nan(rf.F,2);
for rf_k = 1:2
    rf_vals = abs(rf.data(rf_k).raw(rf.common));
    if ~isempty(rf_vals)
        rf.medianAbs(rf_k) = median(rf_vals);
        rf.rms(rf_k) = sqrt(mean(rf_vals.^2));
        rf_sorted = sort(rf_vals);
        rf.p95(rf_k) = rf_sorted(max(1,ceil(.95*numel(rf_sorted))));
    end
    for rf_f = 1:rf.F
        rf_rows = rf.common & rf.fi==rf_f;
        if any(rf_rows)
            rf.byTime(rf_f,rf_k) = median(abs(rf.data(rf_k).raw(rf_rows)));
        end
    end
end
comparison = table(rf.labels',rf.storedCost,rf.goldCost,rf.solverCost, ...
    rf.invalidCount,rf.medianAbs,rf.rms,rf.p95, ...
    'VariableNames',{'Stage','StoredCost','GoldLogCost','SolverCost', ...
    'InvalidObservations','CommonMedianAbs_px','CommonRMS_px','CommonP95_px'});
disp(comparison);
fprintf('Raw-error comparisons use %d / %d observations valid in BOTH fits.\n', ...
    rf.commonCount,rf.M);
fprintf('Below minimum depth: coarse %d; refined %d.\n',rf.belowDepth);
fprintf('Other invalid observations may contain nonfinite projections/values.\n');
if all(isfinite(rf.solverCost)) && rf.solverCost(1)>0
    rf.percentReduction = 100*(rf.solverCost(1)-rf.solverCost(2))/rf.solverCost(1);
    fprintf('Robust solver cost reduction: %.4f%% (negative means worse).\n',rf.percentReduction);
else
    rf.percentReduction = NaN;
    fprintf('Relative cost reduction undefined (zero/nonfinite initial or final cost).\n');
end
if rf.invalidCount(2)>rf.invalidCount(1)
    warning('Refinement increased invalid observations; inspect geometry even if cost fell.');
end
if rf.commonCount==0
    warning('No common valid observations: raw-error comparison is unavailable.');
end

rf.commonPerSlice = accumarray(rf.fi(rf.common),1,[rf.F 1]);
if isempty(refinement_inspection_slice)
    [~,rf.slice] = max(rf.commonPerSlice);
    if rf.commonCount==0
        [~,rf.slice] = max(accumarray(rf.fi,1,[rf.F 1]));
    end
else
    validateattributes(refinement_inspection_slice,{'numeric'}, ...
        {'scalar','integer','>=',1,'<=',rf.F});
    rf.slice = refinement_inspection_slice;
end

%% Figure 1: before/after geometry and image agreement
rf.fig1 = figure('Color','w','Name','Coarse versus refined warm fit', ...
    'Position',[60 60 1380 840]);
tiledlayout(2,3,'TileSpacing','compact','Padding','compact');
rf.allPoints = [rf.data(1).X;rf.data(2).X];
rf.allPoints = rf.allPoints(all(isfinite(rf.allPoints),2),:);
if isempty(rf.allPoints)
    rf.limits = [-1 -1 -1;1 1 1];
else
    rf.low = min(rf.allPoints,[],1); rf.high = max(rf.allPoints,[],1);
    rf.pad = max(.05*(rf.high-rf.low),1e-6);
    rf.limits = [rf.low-rf.pad;rf.high+rf.pad];
end
for rf_panel = 1:3
    nexttile; hold on;
    if rf_panel<3, rf_which = rf_panel; else, rf_which = 1:2; end
    for rf_k = rf_which
        rf_X = rf.data(rf_k).X;
        rf_mask = all(isfinite(rf_X),2);
        scatter3(rf_X(rf_mask,1),rf_X(rf_mask,2),rf_X(rf_mask,3), ...
            16,rf.colors(rf_k,:),'filled','DisplayName',rf.labels{rf_k});
    end
    axis equal; grid on; view(35,25);
    xlim(rf.limits(:,1)'); ylim(rf.limits(:,2)'); zlim(rf.limits(:,3)');
    xlabel('Object x'); ylabel('Object y'); zlabel('Object z');
    if rf_panel<3
        title([rf.labels{rf_panel} ' point cloud']);
    else
        title('Overlay: same frame and scale'); legend('Location','best');
    end
end
nexttile; hold on;
if rf.commonCount>0
    for rf_k = 1:2
        rf_sorted = sort(abs(rf.data(rf_k).raw(rf.common)));
        stairs(rf_sorted,(1:rf.commonCount)'/rf.commonCount, ...
            'Color',rf.colors(rf_k,:),'LineWidth',1.5,'DisplayName',rf.labels{rf_k});
    end
    legend('Location','best');
end
grid on; xlabel('Absolute normal error [pixels]'); ylabel('Fraction at or below error');
title('Common valid observations: farther left is better');
nexttile; hold on;
for rf_k = 1:2
    plot(rf.tau,rf.byTime(:,rf_k),'.-','Color',rf.colors(rf_k,:), ...
        'DisplayName',rf.labels{rf_k});
end
grid on; xlabel('tau [s]'); ylabel('Median absolute normal error [pixels]');
legend('Location','best'); title('Same observations compared at each time');
nexttile; hold on;
rf_rows = find(rf.fi==rf.slice & rf.common);
plot(uv(rf_rows,1),uv(rf_rows,2),'ko','DisplayName','Observed');
for rf_k = 1:2
    rf_P = rf.data(rf_k).pr(rf_rows,:);
    plot(rf_P(:,1),rf_P(:,2),'+','Color',rf.colors(rf_k,:), ...
        'DisplayName',rf.labels{rf_k});
end
axis equal; set(gca,'YDir','reverse'); grid on;
xlabel('u [pixels]'); ylabel('v [pixels]'); legend('Location','best');
title({sprintf('Slice %d: tau = %.3f s',rf.slice,rf.tau(rf.slice)), ...
    'Full pixel separation includes unscored tangent error'});
sgtitle('Before/after refinement: model units, no alignment or outlier trimming');

%% Figure 2: objective, validity, and motion changes
rf.fig2 = figure('Color','w','Name','Refinement metrics and motion changes', ...
    'Position',[90 90 1100 760]);
tiledlayout(2,2,'TileSpacing','compact');
nexttile;
bar(1:2,rf.solverCost); set(gca,'XTick',1:2,'XTickLabel',rf.labels);
ylabel('Sum of squared Cauchy-transformed residuals'); grid on;
title('Recomputed objective on ALL observations');
nexttile;
bar(1:2,rf.invalidCount); set(gca,'XTick',1:2,'XTickLabel',rf.labels);
ylabel('Invalid observation count'); grid on; title('Depth / finite-projection checks');
nexttile;
bar(rf.omega'); set(gca,'XTick',1:3,'XTickLabel',{'omega x','omega y','omega z'});
legend(rf.labels,'Location','best'); ylabel('Angular velocity [deg/s]'); grid on;
title('Compare a*w, avoiding axis/rate sign ambiguity');
rf.qdot = abs(sum(rf.quaternion(:,:,1).*rf.quaternion(:,:,2),2));
rf.rotationDifferenceDeg = rad2deg(2*acos(min(1,max(0,rf.qdot))));
rf.translationDifference = vecnorm(rf.centres(:,:,2)-rf.centres(:,:,1),2,2);
nexttile;
yyaxis left; plot(rf.tau,rf.rotationDifferenceDeg,'-');
ylabel('Rotation difference [deg]');
yyaxis right; plot(rf.tau,rf.translationDifference,'-');
ylabel('Translation difference [model units]');
xlabel('tau [s]'); grid on; title('Change in predicted pose, NOT error to ground truth');
fprintf('Maximum coarse/refined rotation difference: %.5g deg\n',max(rf.rotationDifferenceDeg));
fprintf('Maximum coarse/refined translation difference: %.5g model units\n',max(rf.translationDifference));
fprintf('GoldLogCost omits scale^2; SolverCost includes it. Fixed scale gives the same minimizer.\n');
fprintf('No convergence claim: these fit structs do not contain solver exit flags.\n');

% Optional runtime metric: wrap ONLY your call to refine_fit in tic/toc.
% This script times neither optimization nor the full front end.
% Refinement is an initialization result, before the gold joint warm adjust.
