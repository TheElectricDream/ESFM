function final = final_refinement(map, end_time_s, cam, cfg)
    %   This function performs the offline refinement after the loop:
    %   refine everything with well-observed landmarks, drop landmarks
    %   that reproject poorly, and refine the survivors again. It uses
    %   the whole run, so its trajectory is a smoothed OFFLINE estimate,
    %   not what a real-time system would have had.
    %
    %   Inputs:
    %       MAP -> Struct, reconstruction state after the loop
    %       END_TIME_S -> Scalar, end of the reconstruction interval [s]
    %       CAM -> Struct, camera model
    %       CFG -> Struct, full configuration
    %
    %   Outputs:
    %       FINAL -> Struct with fields:
    %              traj     refined trajectory
    %              X        [N, 3], all landmarks (only KEEP rows refined)
    %              keep     [K, 1], IDs of the landmarks kept
    %              O        [M, 6], observations of the kept landmarks
    %                       (original IDs)
    %              dn       [M, 1], normal residuals of O [px]
    %              revisit  [K, 1], logical, seen over most of a rotation
    %              info     [1, 2] struct, adjuster diagnostics per pass
    
    tr = map.traj;
    X  = map.X;
    N  = size(X, 1);
    
    % Everything free, over the whole run
    free = traj.select_free_parameters(tr, true, end_time_s, [], cfg.warm.free_mean_velocity);
    
    % Pass 1: well-observed landmarks only
    keep = find(map.nobs >= cfg.final.min_obs);
    O    = map.O(ismember(map.O(:, 2), keep), :);
    [tr, X, info1] = adjust.refine(tr, X, O, free, keep, cfg.final.iterations(1), cam, cfg.adjust);
    
    % Drop landmarks that reproject poorly across their observations
    dn = adjust.normal_residuals(tr, X, O, cam);
    point_rms = sqrt(accumarray(O(:, 2), dn.^2, [N, 1]) ./ ...
        max(accumarray(O(:, 2), 1, [N, 1]), 1));
    keep = keep(point_rms(keep) < cfg.final.max_point_rms_px);
    assert(~isempty(keep), 'Final filtering removed every landmark.');
    O = O(ismember(O(:, 2), keep), :);
    
    % Pass 2: the survivors
    [tr, X, info2] = adjust.refine(tr, X, O, free, keep, cfg.final.iterations(2), cam, cfg.adjust);
    dn = adjust.normal_residuals(tr, X, O, cam);
    
    % Landmarks seen over most of a full rotation
    first_seen = accumarray(O(:, 2), O(:, 1), [N, 1], @min, inf);
    last_seen  = accumarray(O(:, 2), O(:, 1), [N, 1], @max, -inf);
    period     = 2 * pi / abs(tr.omega);
    revisit    = (last_seen(keep) - first_seen(keep)) > cfg.final.revisit_fraction * period;
    
    final = struct('traj', tr, 'X', X, 'keep', keep, 'O', O, 'dn', dn, ...
        'revisit', revisit, 'info', [info1, info2]);

end