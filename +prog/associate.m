function claims = associate(pred, warped, direction, slice, nrm, nobs, ambiguous, cfg)
    %   This function lets each visible landmark claim the warped events
    %   that fit its predicted edge. Well-observed landmarks claim first
    %   and an event can only be claimed once. Each successful claim
    %   becomes one observation, built from the RAW event positions at
    %   their mean time.
    %
    %   Inputs:
    %       PRED -> Struct from prog.predict
    %       WARPED -> [E, 2], event positions warped to tc
    %       DIRECTION -> [E, 2], unit normal-flow direction of each event
    %       SLICE -> Struct with fields t, x, y [E, 1] and flow [E, 2]
    %       NRM -> [L, 2], latest image normal of each prediction row
    %       NOBS -> [L, 1], observation count of each prediction row
    %       AMBIGUOUS -> [L, 1], logical, from prog.find_ambiguous
    %       CFG -> Struct, full configuration
    %
    %   Outputs:
    %       CLAIMS -> Struct with fields:
    %              rows    [C, 6], new observations [t, id, u, v, nx, ny]
    %              k       [C, 1], prediction row of each claim
    %              mature  [C, 1], logical, claim by an unambiguous landmark
    %              ratio   [P, 1], predicted/measured image speed of each
    %                      mature claim (diagnostic)
    %              used    [E, 1], logical, events claimed by any landmark
    %              found   [L, 1], logical, prediction rows that claimed

    L = numel(pred.ids);
    E = size(warped, 1);

    claims.rows   = zeros(0, 6);
    claims.k      = zeros(0, 1);
    claims.mature = false(0, 1);
    claims.ratio  = zeros(0, 1);
    claims.used   = false(E, 1);
    claims.found  = false(L, 1);

    if E == 0
        return;
    end

    % Events within the tangent gate of each prediction (indices into the
    % slice)
    neighbors = rangesearch(warped, pred.uv, cfg.prog.gate_tangent_px);

    % Well-observed landmarks claim first (stable sort keeps ties in order)
    [~, order] = sort(nobs, 'descend');

    for k = order'
        if ~pred.inside(k)
            continue;
        end

        % Nearby events nobody has claimed yet
        cand = neighbors{k};
        cand = cand(~claims.used(cand));
        if numel(cand) < cfg.prog.min_claim_events
            continue;
        end

        % Offset of each event from the prediction, split across and along
        % the EVENT's own edge direction
        pe = warped(cand, :) - pred.uv(k, :);
        d  = direction(cand, :);
        normal_error  = sum(pe .* d, 2);
        tangent_error = pe(:, 1) .* d(:, 2) - pe(:, 2) .* d(:, 1);

        % All four gates: on the edge line, near along it, moving the
        % predicted way, and with a compatible edge orientation
        ok = abs(normal_error) < cfg.prog.gate_normal_px & ...
             abs(tangent_error) < cfg.prog.gate_tangent_px & ...
             d * pred.flow(k, :)' > 0 & ...
             abs(d * nrm(k, :)') > cfg.prog.min_normal_cos;

        if nnz(ok) < cfg.prog.min_claim_events
            continue;
        end

        % Claim the events
        c = cand(ok);
        claims.used(c) = true;

        % One observation from the RAW positions at their mean time, with
        % the mean normal-flow direction as the edge normal
        n_mean = geom.unit_rows(mean(slice.flow(c, :), 1));
        claims.rows(end+1, :) = [mean(slice.t(c)), pred.ids(k), ...
                                 mean(slice.x(c)), mean(slice.y(c)), n_mean];
        claims.k(end+1, 1)      = k;
        claims.mature(end+1, 1) = ~ambiguous(k);

        % Diagnostic: predicted speed along the edge normal over measured
        % speed (1 means the motion model matches the events)
        if claims.mature(end)
            claims.ratio(end+1, 1) = mean(d(ok, :) * pred.flow(k, :)') / ...
                                     mean(vecnorm(slice.flow(c, :), 2, 2));
        end
    end

    claims.found(claims.k) = true;

end