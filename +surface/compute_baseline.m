function [accept, flow] = compute_baseline(ev, scfg, time_range)
    %COMPUTE_BASELINE Single-grid PCA baseline for surface.compute.
    %
    %   [accept, flow] = surface.compute_baseline(ev, scfg)
    %   [accept, flow] = surface.compute_baseline(ev, scfg, time_range)
    %
    %   Fits only the unshifted grid, skips motion-compensated support,
    %   and performs no selection between grids. Keeps the same polarity
    %   grouping, normalized covariance fit, normal-flow conversion, and
    %   event-count, time-normal, and planarity thresholds as compute.
    %   scfg.stride_px, scfg.two_offset_grids, and
    %   scfg.min_warped_support are unused.
    %
    %   time_range is [start_s end_s), using the original timestamps.
    %   Supporting events outside that range complete the fitted cells.
    %   Outputs retain the full input length and original event ordering;
    %   rejected or unrequested events have accept=false and flow=[0 0].

    N = numel(ev.t);
    accept = false(N, 1);
    flow = zeros(N, 2);

    % Keep the same target/support window semantics as surface.compute.
    target = true(N, 1);
    support = true(N, 1);

    if nargin >= 3 && ~isempty(time_range)
        validateattributes(time_range, {'numeric'}, ...
            {'vector', 'numel', 2, 'real', 'finite'});
        validateattributes(scfg.cell_s, {'numeric'}, ...
            {'scalar', 'real', 'finite', 'positive'});
        assert(time_range(2) > time_range(1), ...
            'time_range must satisfy end_s > start_s.');

        eventTime = ev.t(:);
        target = eventTime >= time_range(1) & eventTime < time_range(2);
        support = eventTime >= time_range(1) - scfg.cell_s & ...
                  eventTime <  time_range(2) + scfg.cell_s;
    end

    if ~any(target)
        return;
    end

    if scfg.split_polarities
        groups = {ev.p > 0, ev.p <= 0};
    else
        groups = {true(N, 1)};
    end

    for g = 1:numel(groups)
        idx = find(groups{g} & support);
        if isempty(idx)
            continue;
        end

        % One plane per unshifted cell, with no warping/support work.
        f = surface.fit_cells(ev.t(idx), ev.x(idx), ev.y(idx), ...
            scfg, [0 0 0], false);

        % Geometric validity only: no support gate or best-grid ranking.
        ok = f.ok & f.planarity <= scfg.max_planarity_ratio;

        report = target(idx) & ok;
        accept(idx(report)) = true;
        flow(idx(report), :) = f.vel(report, :);
    end
end
