function [map, run_log, edges] = grow_map(map, ev, settings)
% GROW_MAP Advance through post-warm slices, adding points and updating pose.
% Requires accepted normal-flow events for the continuation interval.
% Gold scheduling is retained, including centred slices and historical f.
% The first centre is warm_end + dt for an integral warm_duration/dt.
% Logs: [time, rate_deg_s, map_count, explained_fraction, matched_count, new_count].
start_time_s = settings.start_time_s;
end_time_s = settings.end_time_s;
slice_duration_s = settings.slice_s;
event_t = ev.t;
event_x = ev.x;
event_y = ev.y;
event_flow = ev.flow;
event_accept = ev.accept & event_t>=start_time_s & event_t<end_time_s;
adjustment_settings = settings.adjustment;
association_settings = settings.association;

edges = start_time_s : slice_duration_s : end_time_s + 1e-9;
first_progressive_slice = numel(start_time_s : slice_duration_s : start_time_s + settings.warm_duration_s + 1e-9); % first batch after the warm-start window
accepted_index = find(event_accept);
accepted_t = event_t(accepted_index);
% Columns: [time, rate_deg_s, map_count, explained_fraction, matched_count, new_count].
run_log = zeros(numel(edges) - first_progressive_slice, 6);
tic_loop = tic;
for f = first_progressive_slice : numel(edges) - 1                       % f is the historical zero-based batch label; edges uses f+1
    tc = edges(f + 1);
    map.knots_free = tc >= start_time_s + settings.warm_duration_s + settings.schedule.knots_free_after_s;
    % Centred half-open slice [tc-dt/2, tc+dt/2). The final slice only
    % contains events before end_time_s, because loading already clipped them.
    lo = find(accepted_t >= tc - slice_duration_s/2, 1);
    hi = find(accepted_t < tc + slice_duration_s/2, 1, 'last');
    if isempty(lo) || isempty(hi) || hi < lo
        s = zeros(0, 1);
    else
        s = accepted_index(lo:hi);
    end
    [map, info] = pipeline.process_reconstruction_slice(f, tc, event_t(s), event_x(s), event_y(s), event_flow(s, :), map, edges, association_settings, adjustment_settings);
    if mod(f, settings.schedule.local_every) == 0 && map.knots_free       % every 1 s: knots of the last 3 s + the points seen in them
        in_win = map.O(:, 1) > tc - association_settings.local_win;
        pts = unique(map.O(in_win, 2));
        % Use ALL observations of points selected by the recent window;
        % older observations anchor their structure while active knots adjust.
        rows = in_win | ismember(map.O(:, 2), pts);
        [map.traj, map.X] = adjust.refine_motion_and_structure(map.traj, map.X, map.O(rows, :), ...
            traj.select_free_parameters(map.traj, false, tc, tc - association_settings.local_win, adjustment_settings.free_V), pts, settings.schedule.local_iterations, adjustment_settings);
    end
    if mod(f, settings.schedule.global_every) == 0 || any(f - first_progressive_slice == settings.schedule.early_global_batches)    % every 10 s (and early on): everything
        pts = find(map.alive & map.nobs >= settings.schedule.min_nobs_global);
        rows = ismember(map.O(:, 2), pts);
        if map.knots_free
            knots_upto = tc;
        else
            knots_upto = [];
        end
        [map.traj, map.X] = adjust.refine_motion_and_structure(map.traj, map.X, map.O(rows, :), ...
            traj.select_free_parameters(map.traj, true, knots_upto, [], adjustment_settings.free_V), pts, settings.schedule.global_iterations, adjustment_settings);
    end
    rate_now = traj.rate_deg_s(map.traj, tc);
    run_log(f - first_progressive_slice + 1, :) = [tc, rate_now, nnz(map.alive), mean(info.used), nnz(info.found), info.n_new];
    if mod(f, settings.schedule.print_every) == 0
        recent = map.ratio(max(1, end - 99):end);
        fprintf('t = %.1f s: map %d, found %d, explained %.0f %%, rate %.2f deg/s (omega %.3f), rows %d, model/event velocity %.2f  (%.0f s)\n', ...
            tc, nnz(map.alive), nnz(info.found), 100 * mean(info.used), rate_now, rad2deg(map.traj.omega), ...
            size(map.O, 1), median(recent), toc(tic_loop));
    end
end

end
