function [cand, taken] = update_candidates(cand, warped, slice, available, tc, cfg)
    %   This function extends the 2D candidate tracks using the events no
    %   landmark claimed. Each candidate predicts its position at TC with
    %   constant image velocity, gathers the available warped events near
    %   the prediction, and updates its position and velocity with an
    %   alpha-beta filter. Candidates that miss too many consecutive
    %   slices are dropped.
    %
    %   Inputs:
    %       CAND -> Struct array, candidates (fields x, y, vx, vy, t,
    %              hist, miss)
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
    
    % Constant-velocity prediction of every candidate at tc
    dtp = tc - [cand.t]';
    px  = [cand.x]' + [cand.vx]' .* dtp;
    py  = [cand.y]' + [cand.vy]' .* dtp;
    
    % Available events near each prediction (indices into POOL)
    pool = find(available);
    if ~isempty(pool)
        near_all = rangesearch(warped(pool, :), [px, py], cfg.prog.cand_gate_px);
    else
        near_all = repmat({zeros(1, 0)}, numel(cand), 1);
    end
    
    keep = true(numel(cand), 1);
    for i = 1:numel(cand)
        c = cand(i);
    
        % Nearby events not already used by an earlier candidate
        ids = pool(near_all{i});
        ids = ids(~taken(ids));
    
        if numel(ids) >= cfg.prog.cand_min_events
            taken(ids) = true;
    
            % Innovation: measured minus predicted position
            rx = mean(warped(ids, 1)) - px(i);
            ry = mean(warped(ids, 2)) - py(i);
    
            % Alpha-beta update of velocity and position
            c.vx = c.vx + cfg.prog.cand_vel_gain * rx / dtp(i);
            c.vy = c.vy + cfg.prog.cand_vel_gain * ry / dtp(i);
            c.x  = px(i) + cfg.prog.cand_pos_gain * rx;
            c.y  = py(i) + cfg.prog.cand_pos_gain * ry;
            c.t  = tc;
    
            % Record the filtered position and the events' mean normal
            n = geom.unit_rows(mean(slice.flow(ids, :), 1));
            c.hist(end+1, :) = [tc, c.x, c.y, n];
            c.miss = 0;
        else
            c.miss = c.miss + 1;
        end
    
        keep(i) = c.miss <= max_miss;
        cand(i) = c;
    end
    
    cand = cand(keep);

end