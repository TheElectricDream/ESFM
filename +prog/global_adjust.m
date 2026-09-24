function [map, info] = global_adjust(map, tc, cam, cfg)
    %   This function refines everything well observed so far: the mean
    %   motion, the spline coefficients up to TC (once they are free), and
    %   every landmark with enough observations, using all of their
    %   observations. Its cost grows with the whole history, so it is the
    %   part of the loop that is not bounded for real-time use.
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
    
    % Every live landmark and all its observations -- each one is born
    % with at least cfg.prog.cand_min_samples observations
    pts  = find(map.alive);
    rows = ismember(map.O(:, 2), pts);
    
    % Mean motion always; the spline up to tc only once it is released
    if map.knots_free
        knots_upto = tc;
    else
        knots_upto = [];
    end
    free = traj.select_free_parameters(map.traj, true, knots_upto, [], ...
        cfg.warm.free_mean_velocity);
    
    [map.traj, map.X, info] = adjust.refine(map.traj, map.X, map.O(rows, :), ...
        free, pts, cfg.prog.global_iterations, cam, cfg.adjust);

end