function cand = seed_candidates(cand, warped, slice, available, tc, cfg)
    %   This function starts new candidate tracks from the events that
    %   neither a landmark nor an existing candidate used. The events are
    %   binned into square grid cells, and every cell with enough events
    %   that share one flow direction starts one candidate at the cell's
    %   mean warped position, moving with the cell's mean normal flow.
    %
    %   Inputs:
    %       CAND -> Struct array, existing candidates
    %       WARPED -> [E, 2], event positions warped to tc
    %       SLICE -> Struct with fields t, x, y [E, 1] and flow [E, 2]
    %       AVAILABLE -> [E, 1], logical, events still unused
    %       TC -> Scalar, slice centre time [s]
    %       CFG -> Struct, full configuration
    %
    %   Outputs:
    %       CAND -> Struct array, with the new candidates appended
    
    pool = find(available);
    if isempty(pool)
        return;
    end
    
    % Bin the events into grid cells (sorted by cell, as in gold)
    cells = floor(warped(pool, :) / cfg.prog.seed_cell_px);
    g     = findgroups(cells(:, 1), cells(:, 2));
    count = accumarray(g, 1);
    
    %-----%
    % A seed carries its edge normal and a starting covariance: tight
    % across the edge, loose along it and in velocity
    tcfg = cfg.track;
    D    = deployable.geom.unit_rows(slice.flow);
    
    for j = find(count >= cfg.prog.cand_min_events)'
        ids  = pool(g == j);
        mdir = mean(D(ids, :), 1);
        coh  = norm(mdir);
        if coh < tcfg.min_coherence
            continue;
        end
        n  = mdir / coh;
        tg = [-n(2), n(1)];
        x  = mean(warped(ids, 1));
        y  = mean(warped(ids, 2));
        v  = mean(slice.flow(ids, :), 1);
        Rnt  = [n; tg];
        Ppos = Rnt' * diag([tcfg.sigma_n^2, tcfg.seed_sigma_t^2]) * Rnt;
    
        % Field order must match map.cand for the assignment to work
        cand(end+1) = struct('x', x, 'y', y, 'vx', v(1), 'vy', v(2), 't', tc, ...
            'hist', [tc, x, y, n], 'miss', 0, 'n', n, ...
            'P', blkdiag(Ppos, tcfg.seed_sigma_v^2 * eye(2))); %#ok<AGROW>
    end
    %-----%

end
