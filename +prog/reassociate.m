%-----%
function [map, info] = reassociate(ev, trajectory, seed, t_from, t_end, cfg, cam)
    %   This function rebuilds the map under a given motion and then
    %   refines motion and map together. The seed tracks are triangulated
    %   under the motion and refined as landmarks, the events of
    %   [T_FROM, T_END] are associated with the motion held
    %   (prog.locked_pass), and one global adjustment with everything
    %   free follows. It serves twice: in the initialisation rounds over
    %   the initialisation window, and after the offline closure over the
    %   whole recording.
    %
    %   Inputs:
    %       EV -> Struct, events with fields t, x, y, flow, accept
    %       TRAJECTORY -> Struct, the motion to rebuild under
    %       SEED -> Struct with fields slice_times, fi, ii, uv, nn, ntracks
    %              (the seed tracks in the solver's measurement-list format)
    %       T_FROM -> Scalar, first slice centre of the pass [s]
    %       T_END -> Scalar, end of the pass [s]
    %       CFG -> Struct, full configuration
    %       CAM -> Struct, camera model
    %
    %   Outputs:
    %       MAP -> Struct, the rebuilt map with the refined trajectory
    %       INFO -> Struct, adjuster diagnostics of the global adjustment

    % Seed landmarks: the seed tracks triangulated under the motion and
    % refined with the motion held
    [R, T] = traj.pose(trajectory, seed.slice_times);
    X0 = geom.triangulate(geom.select(R, seed.fi), T(seed.fi, :), seed.ii, seed.uv, seed.nn, ...
        seed.ntracks, cfg.warm.tangent_weight, cam);
    O0 = [seed.slice_times(seed.fi), seed.ii, seed.uv, seed.nn];
    [~, X0] = adjust.refine(trajectory, X0, O0, [], (1:seed.ntracks)', ...
        cfg.warm.adjust_iterations, cam, cfg.adjust);

    % Association with the motion held
    map = prog.locked_pass(ev, trajectory, X0, O0, t_from, t_end, cfg, cam);

    % Global adjustment, everything free, well-observed landmarks only
    nobs = accumarray(map.O(:, 2), 1, [size(map.X, 1), 1]);
    pts  = find(nobs >= cfg.init.min_obs);
    rows = ismember(map.O(:, 2), pts);
    free = traj.select_free_parameters(trajectory, true, t_end, [], cfg.warm.free_mean_velocity);
    [map.traj, map.X, info] = adjust.refine(trajectory, map.X, map.O(rows, :), free, pts, ...
        cfg.init.adjust_iterations, cam, cfg.adjust);

    % Predict smoothly beyond the pass
    map.traj = traj.extrapolate(map.traj, t_end);
    map.knots_free = true;
end
%-----%
