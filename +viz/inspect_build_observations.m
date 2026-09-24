%% Inspect build_observations without changing its inputs or outputs
% Run after producing tracks, slice_times, obs, and track_ids.
% No clear/close commands: existing workspace data and figures are preserved.
% The diagnostic variables are collected in bo_diag.

min_motion = 0;  % build_observations no longer filters by motion

assert(exist('tracks','var') == 1 && exist('slice_times','var') == 1 && ...
    exist('obs','var') == 1 && exist('track_ids','var') == 1 && ...
    exist('min_motion','var') == 1, ...
    'Run build_observations first; also define the matching min_motion.');

bo_diag.times = slice_times(:);
bo_diag.ids = track_ids(:);
bo_diag.F = numel(slice_times);
bo_diag.K = numel(tracks);
bo_diag.N = numel(track_ids);
assert(bo_diag.F > 0 && all(isfinite(bo_diag.times)) && ...
    all(diff(bo_diag.times) > 0), 'Invalid slice_times.');
assert(size(obs,1) == bo_diag.F && size(obs,2) == bo_diag.N && ...
    size(obs,3) == 4 && ndims(obs) <= 3, 'Unexpected obs dimensions.');
assert(all(bo_diag.ids >= 1 & bo_diag.ids <= bo_diag.K & ...
    bo_diag.ids == fix(bo_diag.ids)) && ...
    numel(unique(bo_diag.ids)) == bo_diag.N, 'Invalid track_ids.');

%% Independently determine which original tracks should survive
bo_diag.motion = nan(bo_diag.K,1);
bo_diag.lengths = zeros(bo_diag.K,1);
for bo_k = 1:bo_diag.K
    bo_h = tracks{bo_k};
    if isempty(bo_h), continue; end
    assert(size(bo_h,2) == 5 && all(isfinite(bo_h(:))), ...
        'Original track %d is malformed.', bo_k);
    bo_diag.lengths(bo_k) = size(bo_h,1);
    bo_diag.motion(bo_k) = max(std(bo_h(:,2:3),0,1));
end
bo_diag.expectedKeep = bo_diag.lengths >= 2 & ...
    bo_diag.motion >= min_motion;
bo_diag.actualKeep = false(bo_diag.K,1);
bo_diag.actualKeep(bo_diag.ids) = true;
bo_diag.filterOK = isequal(find(bo_diag.expectedKeep), bo_diag.ids);

%% Rebuild expected measurements from original histories for comparison
% Use nearest-time lookup, independently of build_observations' ismembertol.
bo_diag.expected = nan(bo_diag.F,bo_diag.N,4);
bo_diag.timeTolerance = 32*eps(max(1,max(abs(bo_diag.times))));
if bo_diag.F > 1
    bo_diag.timeTolerance = min(bo_diag.timeTolerance, ...
        min(diff(bo_diag.times))/4);
end
bo_diag.maxTimeError = 0;
bo_diag.timeOK = true;
bo_diag.uniqueOK = true;
for bo_j = 1:bo_diag.N
    bo_h = tracks{bo_diag.ids(bo_j)};
    if bo_diag.F == 1
        bo_idx = ones(size(bo_h,1),1);
    else
        bo_idx = interp1(bo_diag.times,(1:bo_diag.F)', ...
            bo_h(:,1),'nearest','extrap');
    end
    bo_dt = abs(bo_diag.times(bo_idx)-bo_h(:,1));
    if ~isempty(bo_dt)
        bo_diag.maxTimeError = max(bo_diag.maxTimeError,max(bo_dt));
    end
    bo_diag.timeOK = bo_diag.timeOK && all(bo_dt <= bo_diag.timeTolerance);
    bo_diag.uniqueOK = bo_diag.uniqueOK && ...
        numel(unique(bo_idx)) == numel(bo_idx);
    bo_diag.expected(bo_idx,bo_j,:) = reshape(bo_h(:,2:5),[],1,4);
end
bo_diag.expectedVisible = all(isfinite(bo_diag.expected),3);
bo_diag.actualVisible = all(isfinite(obs),3);
bo_diag.missingOK = isequal(isnan(obs),isnan(bo_diag.expected));
bo_diag.valuesOK = isequaln(obs,bo_diag.expected);
bo_diag.allOK = bo_diag.filterOK && bo_diag.timeOK && ...
    bo_diag.uniqueOK && bo_diag.missingOK && bo_diag.valuesOK;

fprintf('\nBUILD_OBSERVATIONS CHECK\n');
fprintf('Input tracks: %d; retained: %d; rejected: %d\n', ...
    bo_diag.K,bo_diag.N,bo_diag.K-bo_diag.N);
fprintf('Stored observations: %d\n',nnz(bo_diag.actualVisible));
fprintf('Checks (1 = pass, 0 = fail):\n');
fprintf('  Filtering and original IDs: %d\n',bo_diag.filterOK);
fprintf('  Timestamp matching:         %d (max error %.3g s)\n', ...
    bo_diag.timeOK,bo_diag.maxTimeError);
fprintf('  Unique track/slice samples: %d\n',bo_diag.uniqueOK);
fprintf('  Missing-value placement:    %d\n',bo_diag.missingOK);
fprintf('  All four components exact: %d\n',bo_diag.valuesOK);

%% Six visual comparisons
bo_diag.figure = figure('Color','w','Name','Observation assembly check');
tiledlayout(2,3,'TileSpacing','compact','Padding','compact');

% 1. Gray originals; colored retained outputs should lie on top of them.
nexttile; hold on;
for bo_k = 1:bo_diag.K
    bo_h = tracks{bo_k};
    if isempty(bo_h), continue; end
    plot(bo_h(:,2),bo_h(:,3),'-','Color',[0.75 0.75 0.75]);
end
bo_diag.colors = lines(max(1,bo_diag.N));
for bo_j = 1:bo_diag.N
    bo_xy = reshape(obs(:,bo_j,1:2),bo_diag.F,2);
    plot(bo_xy(:,1),bo_xy(:,2),'.-','Color',bo_diag.colors(bo_j,:));
end
axis equal; set(gca,'YDir','reverse'); grid on;
xlabel('x [pixels]'); ylabel('y [pixels]');
title({'Gray: original tracks','Color: retained obs positions'});

% 2-3. Exactly matching panels mean the same samples occupy the same slots.
for bo_panel = 1:2
    bo_ax = nexttile;
    if bo_diag.N == 0
        axis off; text(0.1,0.5,'No retained tracks','Units','normalized');
        continue;
    end
    if bo_panel == 1
        bo_mask = bo_diag.expectedVisible;
        bo_title = 'Expected visibility from original histories';
    else
        bo_mask = bo_diag.actualVisible;
        bo_title = 'Actual visibility in obs';
    end
    imagesc(bo_ax,1:bo_diag.F,1:bo_diag.N,double(bo_mask'));
    colormap(bo_ax,[1 1 1; 0.1 0.45 0.75]); caxis(bo_ax,[0 1]);
    set(bo_ax,'YDir','normal');
    xlabel('Slice index'); ylabel('Retained track column');
    title({bo_title,'Blue = present; white = missing'});
end

% 4. Filter decision, indexed by ORIGINAL track identity.
nexttile; hold on;
scatter(find(~bo_diag.actualKeep),bo_diag.motion(~bo_diag.actualKeep), ...
    24,[0.75 0.2 0.15],'x','DisplayName','Rejected');
scatter(bo_diag.ids,bo_diag.motion(bo_diag.ids), ...
    24,[0.1 0.45 0.75],'filled','DisplayName','Retained');
yline(min_motion,'k--','DisplayName','min_motion');
xlabel('Original track ID'); ylabel('max(std(x), std(y)) [pixels]');
title('Motion filter (empty tracks have no marker)');
grid on; legend('Location','best');

% 5-6. Inspect one retained track at its actual sample times.
% Change this to another retained column, e.g. 3, to inspect that track.
bo_diag.selectedColumn = 1;
if bo_diag.N > 0
    bo_j = min(max(1,bo_diag.selectedColumn),bo_diag.N);
    bo_h = tracks{bo_diag.ids(bo_j)};
    bo_diag.relativeTimes = bo_diag.times-bo_diag.times(1);
    for bo_component = 1:2
        nexttile; hold on;
        plot(bo_h(:,1)-bo_diag.times(1),bo_h(:,bo_component+1), ...
            'ko','MarkerSize',6,'DisplayName','Original samples');
        plot(bo_diag.relativeTimes,obs(:,bo_j,bo_component), ...
            'r.-','DisplayName','obs (gaps remain NaN)');
        xlabel('Time since first slice midpoint [s]');
        if bo_component == 1, ylabel('x [pixels]'); else, ylabel('y [pixels]'); end
        title(sprintf('Column %d = original track %d',bo_j,bo_diag.ids(bo_j)));
        grid on; legend('Location','best');
    end
else
    for bo_panel = 1:2
        nexttile; axis off;
        text(0.1,0.5,'No retained track to inspect','Units','normalized');
    end
end
if bo_diag.allOK
    sgtitle('PASS: observation assembly preserves samples and timing');
else
    sgtitle('FAIL: inspect the command-window checks');
    warning('Observation assembly checks failed. See bo_diag and the printed checks.');
end
% A PASS checks data assembly only, not physical tracking accuracy.
% If zero tracks survive, measurement checks are vacuous; inspect the filter.
