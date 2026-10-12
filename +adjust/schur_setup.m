%-----%
function sch = schur_setup(prob, tr, X, r, sw)
    %   This function forms the normal equations of the robust adjustment
    %   in block form for adjust.schur_solve: the dense motion block U
    %   (image rows and the motion priors), one 3x3 block V_k per free
    %   landmark, the coupling blocks W_k, the gradient, and the diagonal
    %   that Marquardt's scaling uses. The landmark-centroid prior is one
    %   dense row z over all free parameters and is kept apart; the solve
    %   applies it as a rank-one update. Nothing here depends on the
    %   damping, so one setup serves every damped attempt of an iteration.
    %
    %   Inputs:
    %       PROB -> Struct from adjust.setup_problem
    %       TR -> Struct, trajectory at which to linearize
    %       X -> [N, 3], landmark coordinates at which to linearize
    %       R -> [n_res, 1], residuals at (TR, X)
    %       SW -> [n_res, 1], Cauchy row weights (1 on prior and depth rows)
    %
    %   Outputs:
    %       SCH -> Struct with fields
    %              n_m, n_l   free motion parameters, free landmarks
    %              U          [n_m, n_m], motion block of J' W^2 J
    %              V          [3, 3, n_l], landmark blocks
    %              W          [n_m, 3, n_l], motion-landmark coupling
    %              g          [n_m + 3 n_l, 1], J' W^2 r (centroid included)
    %              z, r_z     centroid row over the free parameters and
    %                         its residual
    %              diag_h     [n_m + 3 n_l, 1], diag(J' W^2 J), z.^2 included

    n_m = prob.n_free_motion;
    n_l = prob.n_free_landmarks;
    n_f = n_m + 3 * n_l;

    % Image and depth rows as dense blocks, weighted by the Cauchy row
    % weights (W^2 enters as w on the Jacobian and w on the residual)
    [Am, Cm, Bl, lm, rid, seg] = adjust.image_blocks(prob, tr, X);
    w  = sw(rid);
    Am = Am .* w;
    Bl = Bl .* w;
    rw = r(rid) .* w;

    % Frozen motion parameters (column 0) and frozen landmarks drop out
    Cf   = reshape(prob.param_to_col(Cm), size(Cm));
    slot = prob.lm_slot(lm);
    Bl(slot == 0, :) = 0;

    U  = zeros(n_m, n_m);
    gm = zeros(n_m, 1);
    W  = zeros(n_m, 3, n_l);
    V  = zeros(3, 3, n_l);
    gl = zeros(3, n_l);

    % Rows grouped by spline segment: every row of a segment has the same
    % 24 motion columns, so the segment's contribution to U is one dense
    % product, and its coupling to the landmarks one scatter per axis
    [~, ~, gi] = unique(seg);
    [~, ord]   = sort(gi);
    cnt   = accumarray(gi, 1);
    stop  = cumsum(cnt);
    start = stop - cnt + 1;
    for j = 1:numel(cnt)
        rows = ord(start(j):stop(j));
        cj   = Cf(rows(1), :);
        keep = cj > 0;
        cj   = cj(keep);
        if isempty(cj)
            continue;
        end
        A = Am(rows, keep);
        U(cj, cj) = U(cj, cj) + A' * A;
        gm(cj)    = gm(cj) + A' * rw(rows);

        if n_l > 0
            sl  = slot(rows);
            use = sl > 0;
            if any(use)
                P = sparse(sl(use), find(use), 1, n_l, numel(rows));
                for c = 1:3
                    Tc = P * (A .* Bl(rows, c));
                    W(cj, c, :) = W(cj, c, :) + reshape(Tc', numel(cj), 1, n_l);
                end
            end
        end
    end

    % Landmark blocks and gradient, one accumulation per matrix entry
    if n_l > 0
        use = slot > 0;
        s   = slot(use);
        B   = Bl(use, :);
        rr  = rw(use);
        for a = 1:3
            gl(a, :) = accumarray(s, B(:, a) .* rr, [n_l, 1])';
            for b = a:3
                v = accumarray(s, B(:, a) .* B(:, b), [n_l, 1]);
                V(a, b, :) = reshape(v, 1, 1, n_l);
                V(b, a, :) = V(a, b, :);
            end
        end
    end

    % Prior rows: all but the centroid row touch motion parameters only
    [rp, cp, vp] = adjust.prior_jacobian(prob, tr, X);
    row_z = prob.n_img + prob.n_prior;
    isz   = rp == row_z;

    rpm = rp(~isz);
    cf  = prob.param_to_col(cp(~isz));
    vpm = vp(~isz);
    ok  = cf > 0;
    Jp  = sparse(rpm(ok) - prob.n_img, cf(ok), vpm(ok), prob.n_prior, n_m);
    r_p = r(prob.n_img + (1:prob.n_prior));
    r_p(end) = 0;
    U  = U + full(Jp' * Jp);
    gm = gm + Jp' * r_p;

    % Centroid row over the free parameters: axis tangents (global 1, 2)
    % and every free landmark coordinate
    z  = zeros(n_f, 1);
    cz = cp(isz);
    vz = vp(isz);
    is_motion = cz <= prob.n_traj;
    cfz = prob.param_to_col(cz(is_motion));
    vzm = vz(is_motion);
    okz = cfz > 0;
    z(cfz(okz)) = vzm(okz);
    lz  = cz(~is_motion) - prob.n_traj;
    vzl = vz(~is_motion);
    kz  = ceil(lz / 3);
    dz  = lz - 3 * (kz - 1);
    sz  = prob.lm_slot(kz);
    okl = sz > 0;
    z(n_m + 3 * (sz(okl) - 1) + dz(okl)) = vzl(okl);
    r_z = r(row_z);

    sch.n_m    = n_m;
    sch.n_l    = n_l;
    sch.U      = U;
    sch.V      = V;
    sch.W      = W;
    sch.g      = [gm; gl(:)] + z * r_z;
    sch.z      = z;
    sch.r_z    = r_z;
    sch.diag_h = [diag(U); reshape([V(1, 1, :); V(2, 2, :); V(3, 3, :)], [], 1)] + z.^2;
end
%-----%
