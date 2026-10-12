function [accept, flow] = compute(ev, scfg, time_range)
    
    %   Takes the per-cell plane fitting code and wraps it into the
    %   pipeline. Spatial cells retain their cell_px width but overlap at
    %   stride_px spacing in both image axes. Each shifted grid is fitted
    %   separately, and each event keeps the most planar valid estimate
    %   from its containing cells. With two_offset_grids, we also fit a
    %   half-window-shifted temporal grid. When
    %   polarity is included, it is treated as two different planes. Then
    %   we have a series of criteria to filter out events and return the
    %   normal-flow estimation.
    %
    %   Inputs: 
    %       EV -> Struct, contains event stream
    %       SCFG -> Struct, contains parameters for surface estimation
    %           stride_px must divide cell_px and lie in (0, cell_px].
    %           Missing stride_px, or stride_px = cell_px, preserves the
    %           original one/two-grid behavior.
    %
    %   Outputs:
    %       ACCEPT -> [N, 1], true if event is on a clean moving plane
    %       FLOW -> [N, 2], normal flow in pixels/s and zero otherwise

    % Count up the total number of events being analysed in this pass
    N = numel(ev.t);

    % Then we can predefine some variables for storage -- we will define
    % "accept" as events that have acceptable flow and "flow" to be the
    % velocity of each kernel
    accept = false(N, 1);
    flow   = zeros(N, 2);

    % Separate the events we want results FOR from events needed to FIT
    % their cells. One cell duration on either side covers the relevant
    % temporal cells of both the unshifted and half-cell-shifted grids.
    % Keep the original timestamps: changing their origin changes the grid.
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

    % Nothing requested: leave the full-length outputs false/zero.
    if ~any(target)
        return;
    end

    % Start by grouping events according to their polarity -- this way we
    % can do plane fitting using split polarity which is more robust
    if scfg.split_polarities
        groups = {ev.p > 0, ev.p <= 0};
    else 
        groups = {true(N, 1)};
    end

    % Missing stride preserves callers using the original configuration.
    stride_px = scfg.cell_px;
    if isfield(scfg, 'stride_px')
        stride_px = scfg.stride_px;
    end
    validateattributes(scfg.cell_px, {'numeric'}, ...
        {'scalar', 'real', 'finite', 'positive'});
    validateattributes(stride_px, {'numeric'}, ...
        {'scalar', 'real', 'finite', 'positive', '<=', scfg.cell_px});
    phases = scfg.cell_px / stride_px;
    assert(abs(phases - round(phases)) <= 32 * eps(phases), ...
        'surface:InvalidStride', 'stride_px must divide cell_px exactly.');

    % Retain the original grid offsets when spatial overlap is disabled.
    offsets = [0 0 0];
    if scfg.two_offset_grids
        offsets = [offsets; scfg.cell_px / 2, scfg.cell_px / 2,...
            scfg.cell_s / 2];
    end

    if round(phases) > 1
        % Interleaved full-size grids form a lattice of overlapping cells.
        % Take every x/y combination; diagonal shifts alone leave gaps.
        spatial_offsets = (0:round(phases)-1) * stride_px;
        temporal_offsets = offsets(:, 3);
        [ox, oy, ot] = ndgrid(spatial_offsets, spatial_offsets, temporal_offsets);
        offsets = [ox(:), oy(:), ot(:)];
    end

    % Start looking through all of the polarity groups
    for g = 1:numel(groups)
        idx = find(groups{g} & support);

        % If there is nothing in a group then skip
        if isempty(idx)
            continue;
        end

        % Rank all containing cells, requiring each candidate to pass the
        % original geometric and per-event warped-support checks.
        best_ok = false(numel(idx), 1);
        best_planarity = inf(numel(idx), 1);
        best_vel = zeros(numel(idx), 2);

        % Start the for-loop and loop over all offset cases
        for offset_case = 1:size(offsets, 1)

            % Calculate the surface velocities
            f = deployable.surface.fit_cells(ev.t(idx), ev.x(idx), ev.y(idx), scfg, ...
                offsets(offset_case, :), true);

            % Calculate if a grid is acceptable -- these are basically more
            % criteria that are added to indicate good flow, so looking for
            % a thin sheet relative to width, and strong indication that
            % warped events are piling up
            ok = f.ok & f.planarity <= scfg.max_planarity_ratio & ...
                f.support >= scfg.min_warped_support;

            % Check that the current planarity values is the best set
            better = ok & (f.planarity < best_planarity);

            % Populate the arrays
            best_ok(better)         = true;
            best_planarity(better)  = f.planarity(better);
            best_vel(better, :)     = f.vel(better, :);

        end

        % Fit using all supporting events, but publish only requested ones.
        % Write to original event indices so output still aligns with ev.
        report = target(idx);
        accept(idx(report))  = best_ok(report);
        flow(idx(report), :) = best_vel(report, :);
    
    end

end
