function cand = seed_candidates(cand, warped, slice, available, tc, cfg)
    %   This function starts new candidate tracks from the events that
    %   neither a landmark nor an existing candidate used. The events are
    %   binned into square grid cells, and every cell with enough events
    %   starts one candidate at the cell's mean warped position, moving
    %   with the cell's mean normal flow.
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
    
    for j = find(count >= cfg.prog.cand_min_events)'
        ids = pool(g == j);
        x = mean(warped(ids, 1));
        y = mean(warped(ids, 2));
        v = mean(slice.flow(ids, :), 1);
    
        % Field order must match map.cand for the assignment to work
        cand(end+1) = struct('x', x, 'y', y, 'vx', v(1), 'vy', v(2), 't', tc, ...
            'hist', [tc, x, y, geom.unit_rows(v)], 'miss', 0); %#ok<AGROW>
    end

end