function [cand, taken] = update_candidates(cand, warped, slice, available, tc, cfg)
    %   This function extends the 2D candidate tracks using the events no
    %   landmark claimed. Each candidate predicts its position at TC with
    %   constant image velocity, gathers the available warped events in a
    %   small disc around the prediction that move the candidate's way,
    %   and updates a Kalman filter on position and velocity from their
    %   centroid and their mean normal flow. Candidates that miss too many
    %   consecutive slices are dropped.
    %
    %   Inputs:
    %       CAND -> Struct array, candidates (fields x, y, vx, vy, t,
    %              hist, miss, n, P)
    %       WARPED -> [E, 2], event positions warped to tc
    %       SLICE -> Struct with fields t, x, y [E, 1] and flow [E, 2]
    %       AVAILABLE -> [E, 1], logical, events no landmark claimed
    %       TC -> Scalar, slice centre time [s]
    %       CFG -> Struct, full configuration
    %
    %   Outputs:
    %       CAND -> Struct array, updated candidates (dropped ones removed)
    %       TAKEN -> [E, 1], logical, events used by a candidate this slice
    %
    %   Each history row is [tc, x, y, nx, ny]: the FILTERED position at
    %   the slice centre, and the mean normal of the events used.
    
    E = size(warped, 1);
    taken = false(E, 1);
    
    if isempty(cand)
        return;
    end
    
    % Consecutive misses allowed, from the configured gap in seconds
    max_miss = round(cfg.prog.cand_max_gap_s / cfg.data.slice_s);
    
    %-----%
    % Kalman filter on (x, y, vx, vy): constant velocity over one slice
    % with an acceleration noise of cfg.track.q_acc, the same model as
    % track.track_events
    tcfg = cfg.track;
    d = cfg.data.slice_s;
    F = [1 0 d 0; 0 1 0 d; 0 0 1 0; 0 0 0 1];
    q = tcfg.q_acc^2;
    Q = q * [d^4/4 0 d^3/2 0; 0 d^4/4 0 d^3/2; d^3/2 0 d^2 0; 0 d^3/2 0 d^2];
    D = geom.unit_rows(slice.flow);
    
    % Predict every candidate at tc (every slice is processed, so one step)
    n_c  = numel(cand);
    pred = zeros(n_c, 2);
    for i = 1:n_c
        st = F * [cand(i).x; cand(i).y; cand(i).vx; cand(i).vy];
        cand(i).P  = F * cand(i).P * F' + Q;
        cand(i).x  = st(1);
        cand(i).y  = st(2);
        cand(i).vx = st(3);
        cand(i).vy = st(4);
        cand(i).t  = tc;
        pred(i, :) = st(1:2)';
    end
    
    % Available events near each prediction (indices into POOL)
    pool = find(available);
    if ~isempty(pool)
        near_all = rangesearch(warped(pool, :), pred, cfg.prog.cand_gate_px);
    else
        near_all = repmat({zeros(1, 0)}, n_c, 1);
    end
    
    % Older candidates claim first
    ages = arrayfun(@(c) size(c.hist, 1), cand);
    [~, order] = sort(ages, 'descend');
    
    keep = true(n_c, 1);
    for i = order
        c = cand(i);
    
        % Nearby events not already used, moving the candidate's way
        ids = pool(near_all{i});
        ids = ids(:);
        ids = ids(~taken(ids));
        if ~isempty(ids)
            ids = ids(D(ids, :) * c.n' > tcfg.cos_edge);
        end
    
        if numel(ids) >= cfg.prog.cand_min_events
            taken(ids) = true;
    
            % Measurements: the centroid offset in both directions, and
            % the events' normal flow as the velocity across the edge
            n_meas = geom.unit_rows(mean(D(ids, :), 1));
            pe     = warped(ids, :) - pred(i, :);
            zv     = mean(slice.flow(ids, :) * n_meas');
            sig_v  = max(tcfg.sigma_v_floor, tcfg.sigma_v_rel * abs(zv));
            H  = [1 0 0 0; 0 1 0 0; 0 0 n_meas];
            R  = diag([tcfg.sigma_n^2, tcfg.sigma_n^2, sig_v^2]);
            zz = [mean(pe, 1)'; zv - [c.vx c.vy] * n_meas'];
    
            S  = H * c.P * H' + R;
            K  = c.P * H' / S;
            st = [pred(i, :)'; c.vx; c.vy] + K * zz;
            c.P = (eye(4) - K * H) * c.P;
            c.P = (c.P + c.P') / 2;
            c.x  = st(1);
            c.y  = st(2);
            c.vx = st(3);
            c.vy = st(4);
            c.n  = n_meas;
            c.t  = tc;
    
            % Record the filtered position and the events' mean normal
            c.hist(end+1, :) = [tc, c.x, c.y, n_meas];
            c.miss = 0;
        else
            c.miss = c.miss + 1;
        end
    
        keep(i) = c.miss <= max_miss;
        cand(i) = c;
    end
    %-----%
    
    cand = cand(keep);

end
