function claims = associate(pred, warped, direction, slice, nrm, nobs, ambiguous, cfg, searcher)
    %   This function lets each visible landmark claim the warped events
    %   that fit its predicted edge. Well-observed landmarks claim first
    %   and an event can only be claimed once. Each successful claim
    %   becomes one observation, built from the RAW event positions at
    %   their mean time.
    %
    %   Inputs:
    %       PRED -> Struct from deployable.prog.predict
    %       WARPED -> [E, 2], event positions warped to tc
    %       DIRECTION -> [E, 2], unit normal-flow direction of each event
    %       SLICE -> Struct with fields t, x, y [E, 1] and flow [E, 2]
    %       NRM -> [L, 2], latest image normal of each prediction row
    %       NOBS -> [L, 1], observation count of each prediction row
    %       AMBIGUOUS -> [L, 1], logical, from deployable.prog.find_ambiguous
    %       CFG -> Struct, full configuration
    %       SEARCHER -> Optional KDTreeSearcher over WARPED, built once
    %              per slice by the caller (default: built here)
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

    %-----%
    % Events within the tangent gate of each prediction (indices into the
    % slice), from the slice's search tree when the caller built one
    if nargin < 9 || isempty(searcher)
        neighbors = rangesearch(warped, pred.uv, cfg.prog.gate_tangent_px);
    else
        neighbors = rangesearch(searcher, pred.uv, cfg.prog.gate_tangent_px);
    end

    % All four gates for every (landmark, event) pair at once: on the
    % edge line, near along it, moving the predicted way, and with a
    % compatible edge orientation. The offsets are split across and along
    % the EVENT's own edge direction. The sequential claim below only
    % consumes these pairs (2026-10-11; same claims as the per-landmark
    % loop it replaces)
    cnt = cellfun('length', neighbors);
    ki  = repelem((1:L)', cnt);
    ei  = horzcat(neighbors{:})';
    if ~isempty(ei)
        pe = warped(ei, :) - pred.uv(ki, :);
        d  = direction(ei, :);
        normal_error  = sum(pe .* d, 2);
        tangent_error = pe(:, 1) .* d(:, 2) - pe(:, 2) .* d(:, 1);
        ok = pred.inside(ki) & ...
             abs(normal_error) < cfg.prog.gate_normal_px & ...
             abs(tangent_error) < cfg.prog.gate_tangent_px & ...
             sum(d .* pred.flow(ki, :), 2) > 0 & ...
             abs(sum(d .* nrm(ki, :), 2)) > cfg.prog.min_normal_cos;
        ki = ki(ok);
        ei = ei(ok);
    end
    cnt_ok = accumarray(ki, 1, [L, 1]);
    stop   = cumsum(cnt_ok);
    start  = stop - cnt_ok + 1;

    % Well-observed landmarks claim first (stable sort keeps ties in order)
    [~, order] = sort(nobs, 'descend');

    rows_out   = zeros(L, 6);
    k_out      = zeros(L, 1);
    mature_out = false(L, 1);
    ratio_out  = nan(L, 1);
    n_out      = 0;
    for k = order'
        if ~pred.inside(k) || cnt_ok(k) < cfg.prog.min_claim_events
            continue;
        end

        % Fitting events nobody has claimed yet
        c = ei(start(k):stop(k));
        c = c(~claims.used(c));
        if numel(c) < cfg.prog.min_claim_events
            continue;
        end

        % Claim the events
        claims.used(c) = true;

        % One observation from the RAW positions at their mean time, with
        % the mean normal-flow direction as the edge normal
        n_mean = deployable.geom.unit_rows(mean(slice.flow(c, :), 1));
        n_out  = n_out + 1;
        rows_out(n_out, :) = [mean(slice.t(c)), pred.ids(k), ...
                              mean(slice.x(c)), mean(slice.y(c)), n_mean];
        k_out(n_out)      = k;
        mature_out(n_out) = ~ambiguous(k);

        % Diagnostic: predicted speed along the edge normal over measured
        % speed (1 means the motion model matches the events)
        if mature_out(n_out)
            ratio_out(n_out) = mean(direction(c, :) * pred.flow(k, :)') / ...
                               mean(vecnorm(slice.flow(c, :), 2, 2));
        end
    end

    claims.rows   = rows_out(1:n_out, :);
    claims.k      = k_out(1:n_out);
    claims.mature = mature_out(1:n_out);
    claims.ratio  = ratio_out(mature_out(1:n_out));
    %-----%

    claims.found(claims.k) = true;

end
