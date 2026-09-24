function [accept, flow] = compute(ev, scfg, time_range)
    
    %   Takes the per-cell plane fitting code and wraps it into the
    %   pipeline. We run the fitting twice on grids that are offset by half
    %   a cell, so that if we have an edge on the boundary of a cell it can
    %   be correctly identified. For both fits we only keep the one that is
    %   more "planar" -- i.e. the one that is more sheet-like. When
    %   polarity is included, it is treated as two different planes. Then
    %   we have a series of criteria to filter out events and return the
    %   normal-flow estimation.
    %
    %   Inputs: 
    %       EV -> Struct, contains event stream
    %       SCFG -> Struct, contains parameters for surface estimation
    %
    %   Outputs:
    %       ACCEPT -> [N, 1], true if event is on a clean moving plane
    %       FLOW -> [N, 1], normal flow in pixels/s and zero otherwise

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

    % Define the desired offsets (currently hardcoded, but maybe I will
    % move this to the config file)
    offsets = [0 0 0];

    % In the config file the user can choose to use several offset grids -- 
    % basically, we are shifting every grid box bound by some offset in all
    % axes. This minimizes the odds of a pixel falling on a gridline and
    % being split between two grids.
    if scfg.two_offset_grids
        offsets = [offsets; scfg.cell_px / 2, scfg.cell_px / 2,...
            scfg.cell_s / 2];
    end

    % Start looking through all of the polarity groups
    for g = 1:numel(groups)
        idx = find(groups{g} & support);

        % If there is nothing in a group then skip
        if isempty(idx)
            continue;
        end

        % Initialize empty arrays to handle the split offset case --
        % basically we check both cases of offset and pick the best one
        % going forward
        best_ok = false(numel(idx), 1);
        best_planarity = inf(numel(idx), 1);
        best_vel = zeros(numel(idx), 2);

        % Start the for-loop and loop over all offset cases
        for offset_case = 1:size(offsets, 1)

            % Calculate the surface velocities
            f = surface.fit_cells(ev.t(idx), ev.x(idx), ev.y(idx), scfg, ...
                offsets(offset_case, :));

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