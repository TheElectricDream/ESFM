function ambiguous = find_ambiguous(pred, nrm, cfg)
    %   This function flags visible landmarks whose predicted edges
    %   coincide with another visible landmark's: on the same edge line,
    %   with similar orientation, moving the same way. Events near such
    %   an edge could belong to either landmark.
    %
    %   Inputs:
    %       PRED -> Struct from prog.predict
    %       NRM -> [L, 2], latest image normal of each prediction row
    %              (map.nrm(pred.ids, :))
    %       CFG -> Struct, full configuration
    %
    %   Outputs:
    %       AMBIGUOUS -> [L, 1], logical, per prediction row
    
    L = numel(pred.ids);
    ambiguous = false(L, 1);
    
    vis = find(pred.inside);
    if numel(vis) < 2
        return;
    end
    
    % Candidate pairs: visible predictions within the tangent gate of each
    % other (indices into VIS)
    pairs = rangesearch(pred.uv(vis, :), pred.uv(vis, :), cfg.prog.gate_tangent_px);

    %-----%
    % Each pair tested once, from its lower index, all pairs at once
    % (2026-10-11; same flags as the nested loop it replaces)
    cnt = cellfun('length', pairs);
    pk  = repelem((1:numel(vis))', cnt);
    pl  = horzcat(pairs{:})';
    sel = pl > pk;
    k   = vis(pk(sel));
    l   = vis(pl(sel));
    if isempty(k)
        return;
    end
    nk = nrm(k, :);
    same_line   = abs(sum((pred.uv(l, :) - pred.uv(k, :)) .* nk, 2)) < cfg.prog.gate_normal_px;
    same_orient = abs(sum(nk .* nrm(l, :), 2)) > cfg.prog.min_normal_cos;
    same_motion = sum(nk .* pred.flow(k, :), 2) .* sum(nk .* pred.flow(l, :), 2) > 0;
    amb = same_line & same_orient & same_motion;
    ambiguous(k(amb)) = true;
    ambiguous(l(amb)) = true;
    %-----%

end
