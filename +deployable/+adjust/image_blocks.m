%-----%
function [Am, Cm, Bl, lm, rid, seg] = image_blocks(prob, tr, X)
    %   This function computes the Jacobian of the image and depth
    %   residuals as dense per-row blocks instead of sparse triplets.
    %   Every residual row depends on the 8 mean-motion parameters, the
    %   4 angular and 12 translation spline coefficients active at its
    %   time (24 motion entries) and the 3 coordinates of its landmark.
    %   The derivative values are exactly those of deployable.adjust.image_jacobian;
    %   only the container differs, so the Schur solver can form the
    %   normal equations with dense block products.
    %
    %   Inputs:
    %       PROB -> Struct from deployable.adjust.setup_problem
    %       TR -> Struct, trajectory at which to linearize
    %       X -> [N, 3], landmark coordinates at which to linearize
    %
    %   Outputs:
    %       AM -> [Q, 24], motion derivatives per residual row, slots
    %              1-2 axis tangents, 3 omega, 4-5 centre, 6-8 drift,
    %              9-12 angular knots, 13-24 translation knots ([x y z]
    %              per knot)
    %       CM -> [Q, 24], GLOBAL trajectory parameter index of each slot
    %       BL -> [Q, 3], landmark derivatives per residual row
    %       LM -> [Q, 1], landmark id of each row
    %       RID -> [Q, 1], row in the FULL residual vector
    %       SEG -> [Q, 1], spline segment of each row (rows of one
    %              segment share the same 24 motion columns)

    M = prob.M;
    K = prob.K;

    % Pose, camera-frame points, and the rotated (untranslated) points
    [R, T, theta] = deployable.adjust.observation_pose(prob, tr);
    Xo = X(prob.ids, :);
    Y  = deployable.geom.apply_pose(R, T, Xo);
    RX = Y - T;

    % Depth used by the projection -- frozen at the limit past it
    valid = Y(:, 3) >= prob.min_depth;
    z     = max(Y(:, 3), prob.min_depth);
    fx    = prob.cam.focal(1);
    fy    = prob.cam.focal(2);

    % Factor 1: how each residual type reacts to the point
    G_n = [prob.wn(:, 1) * fx ./ z, prob.wn(:, 2) * fy ./ z, ...
           -(prob.wn(:, 1) * fx .* Y(:, 1) + prob.wn(:, 2) * fy .* Y(:, 2)) ./ z.^2 .* valid];
    G_t = [prob.wt(:, 1) * fx ./ z, prob.wt(:, 2) * fy ./ z, ...
           -(prob.wt(:, 1) * fx .* Y(:, 1) + prob.wt(:, 2) * fy .* Y(:, 2)) ./ z.^2 .* valid];
    G_d = [zeros(M, 2), prob.depth_weight * ~valid];

    % Factor 2: how the point moves for each parameter type
    a = tr.a(:);
    dY_dtheta = [a(2) * RX(:, 3) - a(3) * RX(:, 2), ...
                 a(3) * RX(:, 1) - a(1) * RX(:, 3), ...
                 a(1) * RX(:, 2) - a(2) * RX(:, 1)];

    [t1, t2] = deployable.geom.axis_tangent(a);
    tangents = [t1(:), t2(:)];
    c  = cos(theta);
    s  = sin(theta);
    aX = Xo * a;
    dY_daxis = cell(1, 2);
    for i = 1:2
        t   = tangents(:, i);
        txX = [t(2) * Xo(:, 3) - t(3) * Xo(:, 2), ...
               t(3) * Xo(:, 1) - t(1) * Xo(:, 3), ...
               t(1) * Xo(:, 2) - t(2) * Xo(:, 1)];
        dY_daxis{i} = s .* txX + (1 - c) .* (aX * t' + (Xo * t) * a');
    end

    R_col = {[R.r11, R.r21, R.r31], [R.r12, R.r22, R.r32], [R.r13, R.r23, R.r33]};

    % Global column of every slot, shared by the three residual types
    bI   = prob.b_idx;
    cols = [repmat(1:8, M, 1), 8 + bI, zeros(M, 12)];
    for b = 1:4
        for d = 1:3
            cols(:, 12 + 3 * (b - 1) + d) = 8 + K + 3 * (bI(:, b) - 1) + d;
        end
    end

    % Residual types: normal rows (2i-1), tangent rows (2i), depth rows
    % (at the end, only where the hinge is active)
    obs        = (1:M)';
    G_all      = {G_n, G_t, G_d};
    row_all    = {2 * obs - 1, 2 * obs, prob.n_img + prob.n_prior + obs};
    select_all = {true(M, 1), true(M, 1), ~valid};

    Am  = cell(3, 1);
    Cm  = cell(3, 1);
    Bl  = cell(3, 1);
    lm  = cell(3, 1);
    rid = cell(3, 1);
    seg = cell(3, 1);

    for q = 1:3
        sel = select_all{q};
        n   = nnz(sel);
        if n == 0
            continue;
        end
        G   = G_all{q}(sel, :);
        tau = prob.tau(sel);
        B   = prob.b_val(sel, :);

        % Residual sensitivity to the rotation angle, shared by omega and k
        g_theta = -sum(G .* dY_dtheta(sel, :), 2);

        A = zeros(n, 24);
        A(:, 1)    = -sum(G .* dY_daxis{1}(sel, :), 2);
        A(:, 2)    = -sum(G .* dY_daxis{2}(sel, :), 2);
        A(:, 3)    = g_theta .* tau;
        A(:, 4:5)  = -G(:, 1:2);
        A(:, 6:8)  = -G .* tau;
        A(:, 9:12) = g_theta .* B;
        for b = 1:4
            A(:, 12 + 3 * (b - 1) + (1:3)) = -G .* B(:, b);
        end

        Bq = zeros(n, 3);
        for d = 1:3
            Bq(:, d) = -sum(G .* R_col{d}(sel, :), 2);
        end

        Am{q}  = A;
        Cm{q}  = cols(sel, :);
        Bl{q}  = Bq;
        lm{q}  = prob.ids(sel);
        rid{q} = row_all{q}(sel);
        seg{q} = prob.seg(sel);
    end

    Am  = vertcat(Am{:});
    Cm  = vertcat(Cm{:});
    Bl  = vertcat(Bl{:});
    lm  = vertcat(lm{:});
    rid = vertcat(rid{:});
    seg = vertcat(seg{:});
end
%-----%
