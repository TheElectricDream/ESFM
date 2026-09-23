function [trajectory, info] = correct_motion(map, new_rows, tc, cam, cfg)
    %   This function corrects the recent motion using this slice's claims
    %   and the observations of the last local window: only the spline
    %   coefficients active in [tc - window, tc] are free, and the mean
    %   motion and every landmark stay fixed. The released window includes
    %   the coefficient that starts at tc, which no observation constrains
    %   yet -- the curvature prior sets it, so it extrapolates the motion
    %   smoothly into the next slice.
    %
    %   Inputs:
    %       MAP -> Struct, current reconstruction state
    %       NEW_ROWS -> [C, 6], this slice's claimed observations
    %       TC -> Scalar, slice centre time [s]
    %       CAM -> Struct, camera model
    %       CFG -> Struct, full configuration
    %
    %   Outputs:
    %       TRAJECTORY -> Struct, corrected trajectory
    %       INFO -> Struct, adjuster diagnostics from adjust.refine
    
    window = cfg.prog.local_window_s;
    
    % Recent observations plus this slice's claims
    recent = [map.O(map.O(:, 1) > tc - window, :); new_rows];
    
    % Only the spline coefficients active in the recent window move
    free = traj.select_free_parameters(map.traj, false, tc, tc - window, ...
        cfg.warm.free_mean_velocity);
    
    % Motion-only refinement: no landmark is free
    [trajectory, ~, info] = adjust.refine(map.traj, map.X, recent, free, [], ...
        cfg.prog.correction_iterations, cam, cfg.adjust);

end