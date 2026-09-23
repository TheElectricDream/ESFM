function [map, info] = local_adjust(map, tc, cam, cfg)
    %   This function jointly refines the recent motion and the recently
    %   seen landmarks: the spline coefficients active in the last local
    %   window, and every landmark observed in it. ALL observations of
    %   those landmarks are used (not only recent ones), so their older
    %   history anchors the structure while the recent motion adjusts.
    %   The mean motion stays fixed.
    %
    %   Inputs:
    %       MAP -> Struct, current reconstruction state
    %       TC -> Scalar, slice centre time [s]
    %       CAM -> Struct, camera model
    %       CFG -> Struct, full configuration
    %
    %   Outputs:
    %       MAP -> Struct, with refined trajectory and landmarks
    %       INFO -> Struct, adjuster diagnostics from adjust.refine
    
    window = cfg.prog.local_window_s;
    
    % Landmarks observed in the recent window, and all their observations
    in_win = map.O(:, 1) > tc - window;
    pts    = unique(map.O(in_win, 2));
    rows   = in_win | ismember(map.O(:, 2), pts);
    
    % Recent spline coefficients only
    free = traj.select_free_parameters(map.traj, false, tc, tc - window, ...
        cfg.warm.free_mean_velocity);
    
    [map.traj, map.X, info] = adjust.refine(map.traj, map.X, map.O(rows, :), ...
        free, pts, cfg.prog.local_iterations, cam, cfg.adjust);

end