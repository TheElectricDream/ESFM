%-----%
function map = locked_pass(ev, trajectory, landmarks, observations, t_from, t_end, cfg, cam)
    %   This function associates the events of [T_FROM, T_END] with the
    %   motion HELD at TRAJECTORY: the same slice processing as the loop
    %   (predict, claim, track and promote candidates) but no motion
    %   correction, and the local and global adjustments move landmarks
    %   only. With the motion right, a landmark that returns after a
    %   hidden interval is claimed under its old id, so the map carries
    %   associations across revolutions.
    %
    %   Inputs:
    %       EV -> Struct, events with fields t, x, y, flow, accept
    %       TRAJECTORY -> Struct, the motion to hold
    %       LANDMARKS -> [N, 3], seed landmarks
    %       OBSERVATIONS -> [M, 6], observations of the seed landmarks
    %       T_FROM -> Scalar, first slice centre [s]
    %       T_END -> Scalar, end of the pass [s]
    %       CFG -> Struct, full configuration
    %       CAM -> Struct, camera model
    %
    %   Outputs:
    %       MAP -> Struct from deployable.prog.create_map, with the landmarks and
    %              observations of the pass

    map = deployable.prog.create_map(trajectory, landmarks, observations);
    map.knots_free = false;

    dt      = cfg.data.slice_s;
    centers = (t_from + dt / 2 : dt : t_end - dt / 2)';
    [acc_idx, s_first, s_last] = deployable.prog.slice_events(ev.t, ev.accept, centers, dt);

    n_at_global = size(map.O, 1);
    t_prev      = t_from;
    for f = 1:numel(centers)
        tc    = centers(f);
        s     = acc_idx(s_first(f):s_last(f));
        slice = struct('t', ev.t(s), 'x', ev.x(s), 'y', ev.y(s), 'flow', ev.flow(s, :));

        map = deployable.prog.step(map, slice, tc, cfg, cam);

        % Landmarks seen in the recent window, adjusted with the motion held
        if deployable.prog.crossed(t_prev, tc, cfg.prog.local_every_s, trajectory.t0)
            in_win = map.O(:, 1) > tc - cfg.prog.local_window_s;
            pts    = unique(map.O(in_win, 2));
            rows   = in_win | ismember(map.O(:, 2), pts);
            [~, map.X] = deployable.adjust.refine(map.traj, map.X, map.O(rows, :), [], pts, ...
                cfg.prog.local_iterations, cam, cfg.adjust);
        end

        % Every landmark, whenever the map has grown enough
        if size(map.O, 1) >= cfg.prog.global_growth * n_at_global
            pts  = find(map.alive);
            rows = ismember(map.O(:, 2), pts);
            [~, map.X] = deployable.adjust.refine(map.traj, map.X, map.O(rows, :), [], pts, ...
                cfg.prog.global_iterations, cam, cfg.adjust);
            n_at_global = size(map.O, 1);
        end

        t_prev = tc;
    end
end
%-----%
