function result = package_result(final, map, run_log, online, cam, cfg)
    %   This function assembles the final result: the filtered cloud, its
    %   observations (with both original and compact IDs), the refined
    %   and online trajectories, diagnostics, and the metric scale.
    %
    %   Inputs:
    %       FINAL -> Struct from prog.final_refinement
    %       MAP -> Struct, reconstruction state after the loop
    %       RUN_LOG -> [F, 7], per-slice log from the loop
    %       ONLINE -> Struct, online pose at each slice centre
    %       CAM -> Struct, camera model
    %       CFG -> Struct, full configuration
    %
    %   Outputs:
    %       RESULT -> Struct, everything needed to evaluate and export
    
    result.traj   = final.traj;
    result.ids    = final.keep;
    result.X      = final.X(final.keep, :);
    result.nobs   = map.nobs(final.keep);
    
    % Observations: original IDs in O, compact IDs (rows of X) in
    % observations
    result.O = final.O;
    [found, compact] = ismember(final.O(:, 2), final.keep);
    assert(all(found), 'An observation refers to a filtered-out landmark.');
    result.observations = final.O;
    result.observations(:, 2) = compact;
    
    result.normal_residual_px = final.dn;
    result.normal_rms_px      = sqrt(mean(final.dn.^2));
    result.revisited          = final.revisit;
    result.log                = run_log;
    result.online             = online;
    result.camera             = cam;
    result.config             = cfg;
    
    % Metric scale (reporting only)
    result.scale = prog.calibrate_scale(result.X, result.ids, cfg.output);
    result.X_m   = result.scale.m_per_unit * result.X;
    
    % Refined poses at every slice time over the whole interval
    t_pose = (cfg.data.start_time_s : cfg.data.slice_s : cfg.data.end_time_s)';
    result.pose = traj.sample_refined_trajectory(final.traj, t_pose, result.scale.m_per_unit);

end