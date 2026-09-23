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
    
    for pk = 1:numel(vis)
        k  = vis(pk);
        nk = nrm(k, :);
    
        % Each pair is tested once, from its lower index
        for l = vis(pairs{pk}(pairs{pk} > pk))'
            same_line   = abs((pred.uv(l, :) - pred.uv(k, :)) * nk') < cfg.prog.gate_normal_px;
            same_orient = abs(nk * nrm(l, :)') > cfg.prog.min_normal_cos;
            same_motion = (nk * pred.flow(k, :)') * (nk * pred.flow(l, :)') > 0;
    
            if same_line && same_orient && same_motion
                ambiguous(k) = true;
                ambiguous(l) = true;
            end
        end
    end

end