function [map, promo] = promote_candidates(map, tc, cam, cfg)
    %   This function triangulates every mature candidate -- enough
    %   samples, tracked while the target turned enough -- and adds it to
    %   the map as a landmark if it lies in front of the camera and
    %   reprojects well across its history (the turn-angle test already
    %   guarantees a real viewing baseline).
    %   Every mature candidate is retired after its attempt, promoted or
    %   not (retained gold choice).
    %
    %   Inputs:
    %       MAP -> Struct, current reconstruction state
    %       TC -> Scalar, slice centre time [s]
    %       CAM -> Struct, camera model
    %       CFG -> Struct, full configuration
    %
    %   Outputs:
    %       MAP -> Struct, with new landmarks added and mature candidates
    %              removed
    %       PROMO -> Struct, counts: attempted, promoted, and failures of
    %              each gate (fail_depth, fail_rms; a candidate can fail
    %              both)
    
    promo = struct('attempted', 0, 'promoted', 0, ...
        'fail_depth', 0, 'fail_rms', 0);
    
    if isempty(map.cand)
        return;
    end
    
    % Mature: enough samples, and the target turned enough between the
    % first and last sample (a real viewing baseline)
    mature = false(numel(map.cand), 1);
    for i = 1:numel(map.cand)
        h = map.cand(i).hist;
        if size(h, 1) >= cfg.prog.cand_min_samples
            turn = abs(traj.angle(map.traj, h(end, 1)) - traj.angle(map.traj, h(1, 1)));
            mature(i) = turn >= deg2rad(cfg.prog.cand_min_turn_deg);
        end
    end
    
    for i = find(mature)'
        h = map.cand(i).hist;
        S = size(h, 1);
        promo.attempted = promo.attempted + 1;
    
        % Triangulate one point from the whole history, with the pose at
        % each sample time
        [R, T] = traj.pose(map.traj, h(:, 1));
        X = geom.triangulate(R, T, ones(S, 1), h(:, 2:3), h(:, 4:5), 1, ...
            cfg.adjust.tangent_weight, cam);
    
        % Check it against its own history
        [pr, Y]   = geom.project(R, T, repmat(X, S, 1), cam);
        rms_px    = sqrt(mean(sum((h(:, 2:3) - pr) .* h(:, 4:5), 2).^2));
    
        ok_depth = min(Y(:, 3)) > cfg.prog.cand_min_depth;
        ok_rms   = rms_px < cfg.prog.cand_max_rms_px;
    
        promo.fail_depth = promo.fail_depth + ~ok_depth;
        promo.fail_rms   = promo.fail_rms   + ~ok_rms;
    
        if ok_depth && ok_rms
            % New landmark, with its whole history as observations
            id = size(map.X, 1) + 1;
            map.X(id, :)         = X;
            map.O                = [map.O; [h(:, 1), repmat(id, S, 1), h(:, 2:5)]];
            map.nobs(id, 1)      = S;
            map.nrm(id, :)       = h(end, 4:5);
            map.created_s(id, 1) = tc;
            map.alive(id, 1)     = true;
            promo.promoted       = promo.promoted + 1;
        end
    end
    
    % Retire every mature candidate, promoted or not
    map.cand = map.cand(~mature);

end