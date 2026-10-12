%-----%
function [scale, votes, scales, attempts] = closure_vote(map, ev, cfg, cam)
    %   This function closes the rotation over the whole recording at
    %   once. At every attempt time the landmarks hidden for a while are
    %   projected under the trajectory with its rotation history scaled by
    %   each candidate scale, and the number of them that claim events is
    %   the vote for that scale. A landmark's phase error grows with its
    %   age, so the vote is over a rate scale, not a phase offset. The
    %   votes are summed over all attempts: the true scale collects votes
    %   at every attempt, while a landmark that lands one solar-cell pitch
    %   off corresponds to a different scale at every age and attempt and
    %   smears out. Nothing is accepted or committed here.
    %
    %   Speed (2026-10-11): one search tree per attempt serves every scale
    %   and shift, and the claim gates are tested for all (landmark,
    %   scale, shift, event) pairs at once. The votes are those of the
    %   per-combination loop it replaces.
    %
    %   Inputs:
    %       MAP -> Struct, reconstruction state after the loop
    %       EV -> Struct, events with fields t, x, y, flow, accept
    %       CFG -> Struct, full configuration (cfg.closure, cfg.prog)
    %       CAM -> Struct, camera model
    %
    %   Outputs:
    %       SCALE -> Scalar, the rate scale with the most votes
    %       VOTES -> [A, S], votes per attempt and scale (NaN where no
    %              attempt was possible)
    %       SCALES -> [1, S], the candidate scales
    %       ATTEMPTS -> [A, 1], attempt times [s]

    ccfg   = cfg.closure;
    scales = ccfg.scales(:)';
    n_sc   = numel(scales);
    t_from = cfg.data.start_time_s + cfg.init.window_s;
    attempts = (t_from : ccfg.every_s : cfg.data.end_time_s)';

    tr = map.traj;
    N  = size(map.X, 1);
    first_seen = accumarray(map.O(:, 2), map.O(:, 1), [N, 1], @min, inf);
    last_seen  = accumarray(map.O(:, 2), map.O(:, 1), [N, 1], @max, -inf);
    alive      = find(map.alive & map.nobs >= ccfg.min_obs);

    dt   = cfg.data.slice_s;
    h    = cfg.prog.flow_half_step_s;
    sz   = cam.image_size;
    mg   = cfg.prog.image_margin_px;
    Sh   = ccfg.shifts_px;
    n_sh = size(Sh, 1);
    min_claim = cfg.prog.min_claim_events;

    votes = nan(numel(attempts), n_sc);
    for a = 1:numel(attempts)
        tc = attempts(a);

        % Hidden landmarks: unseen for t_hidden, with a history
        hidden = alive(last_seen(alive) < tc - ccfg.t_hidden_s & isfinite(last_seen(alive)));
        L = numel(hidden);
        if L < ccfg.min_hidden
            continue;
        end

        % This slice's events, warped to tc, indexed once for every
        % scale and shift
        s = find(ev.accept & ev.t >= tc - dt / 2 & ev.t < tc + dt / 2);
        if numel(s) < ccfg.min_hidden
            continue;
        end
        slice = struct('t', ev.t(s), 'x', ev.x(s), 'y', ev.y(s), 'flow', ev.flow(s, :));
        [warped, direction] = prog.warp_events(slice, tc);
        searcher = KDTreeSearcher(warped);

        X   = map.X(hidden, :);
        nrm = map.nrm(hidden, :);
        age = tc - first_seen(hidden);

        theta0 = traj.angle(tr, tc);
        thp    = traj.angle(tr, tc + h);
        thm    = traj.angle(tr, tc - h);
        Tt     = traj.translation(tr, tc);
        Tp     = traj.translation(tr, tc + h);
        Tm     = traj.translation(tr, tc - h);

        % Every (landmark, scale) at once; row q = l + L (s - 1)
        dq   = reshape((scales - 1) .* (tr.omega * age), [], 1);
        LS   = L * n_sc;
        Xq   = repmat(X, n_sc, 1);
        nq_l = repmat(nrm, n_sc, 1);
        [uv, Y] = geom.project(geom.rodrigues(tr.a, theta0 + dq), repmat(Tt, LS, 1), Xq, cam);
        fl = (geom.project(geom.rodrigues(tr.a, thp + dq), repmat(Tp, LS, 1), Xq, cam) - ...
              geom.project(geom.rodrigues(tr.a, thm + dq), repmat(Tm, LS, 1), Xq, cam)) / (2 * h);
        inside = Y(:, 3) > cfg.adjust.min_depth & uv(:, 1) > -mg & uv(:, 1) < sz(1) + mg & ...
                 uv(:, 2) > -mg & uv(:, 2) < sz(2) + mg;
        vis = find(inside);
        nv  = numel(vis);
        if nv == 0
            votes(a, :) = 0;
            continue;
        end

        % Queries: every visible (landmark, scale) under every shift; query
        % index qi = v + nv (shift - 1)
        nq = nv * n_sh;
        Q  = repmat(uv(vis, :), n_sh, 1) + repelem(Sh, nv, 1);
        nb = rangesearch(searcher, Q, ccfg.gate_tangent_px);
        cnt = cellfun('length', nb);
        qi  = repelem((1:nq)', cnt);
        ei  = horzcat(nb{:})';
        if isempty(ei)
            votes(a, :) = 0;
            continue;
        end

        % Claim gates for every (query, event) pair: on the edge line,
        % near along it, moving the predicted way, compatible orientation
        vq = vis(mod(qi - 1, nv) + 1);
        pe = warped(ei, :) - Q(qi, :);
        dd = direction(ei, :);
        ne = sum(pe .* dd, 2);
        te = pe(:, 1) .* dd(:, 2) - pe(:, 2) .* dd(:, 1);
        ok = abs(ne) < ccfg.gate_normal_px & abs(te) < ccfg.gate_tangent_px & ...
             sum(dd .* fl(vq, :), 2) > 0 & abs(sum(dd .* nq_l(vq, :), 2)) > cfg.prog.min_normal_cos;
        n_ok    = accumarray(qi(ok), 1, [nq, 1]);
        claimed = n_ok >= min_claim;

        % Landmarks claiming per (scale, shift); the vote of a scale is
        % its best shift
        q_all  = (1:nq)';
        v_all  = mod(q_all - 1, nv) + 1;
        sh_all = floor((q_all - 1) / nv) + 1;
        sc_all = floor((vis(v_all) - 1) / L) + 1;
        counts = accumarray([sc_all(claimed), sh_all(claimed)], 1, [n_sc, n_sh]);
        votes(a, :) = max(counts, [], 2)';
    end

    total = sum(votes, 1, 'omitnan');
    [~, j] = max(total);
    scale  = scales(j);
end
%-----%
