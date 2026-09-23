function [rows, cols, vals] = image_jacobian(prob, tr, X)
    %   This function builds the Jacobian of the image and depth residuals
    %   as sparse triplets. Every entry factors into two pieces, since
    %   the residuals depend on the parameters only through the camera-
    %   frame point Y = R X + T:
    %
    %       dr/d(parameter) = -G * dY/d(parameter)
    %
    %   where G (one per residual type) says how the residual reacts to
    %   the point moving, and dY/d(parameter) (one per parameter type)
    %   says how the point moves when the parameter changes.
    %
    %   Inputs:
    %       PROB -> Struct from adjust.setup_problem
    %       TR -> Struct, trajectory at which to linearize
    %       X -> [N, 3], landmark coordinates at which to linearize
    %
    %   Outputs:
    %       ROWS -> [Q, 1], rows in the FULL residual vector
    %       COLS -> [Q, 1], GLOBAL parameter indices (before mapping to
    %              free columns with prob.param_to_col)
    %       VALS -> [Q, 1], derivative values

    M = prob.M;
    K = prob.K;

    % Pose, camera-frame points, and the rotated (untranslated) points
    [R, T, theta] = adjust.observation_pose(prob, tr);
    Xo = X(prob.ids, :);
    Y  = geom.apply_pose(R, T, Xo);
    RX = Y - T;

    % Depth used by the projection -- frozen at the limit past it, where
    % the projection no longer depends on depth
    valid = Y(:, 3) >= prob.min_depth;
    z     = max(Y(:, 3), prob.min_depth);
    fx    = prob.cam.focal(1);
    fy    = prob.cam.focal(2);

    % ----- Factor 1: how each residual type reacts to the point -----
    G_n = [prob.wn(:, 1) * fx ./ z, prob.wn(:, 2) * fy ./ z, ...
           -(prob.wn(:, 1) * fx .* Y(:, 1) + prob.wn(:, 2) * fy .* Y(:, 2)) ./ z.^2 .* valid];
    G_t = [prob.wt(:, 1) * fx ./ z, prob.wt(:, 2) * fy ./ z, ...
           -(prob.wt(:, 1) * fx .* Y(:, 1) + prob.wt(:, 2) * fy .* Y(:, 2)) ./ z.^2 .* valid];
    G_d = [zeros(M, 2), prob.depth_weight * ~valid];

    % ----- Factor 2: how the point moves for each parameter type -----
    a = tr.a(:);

    % Rotation angle: dY/dtheta = a x (R X)
    dY_dtheta = [a(2) * RX(:, 3) - a(3) * RX(:, 2), ...
                 a(3) * RX(:, 1) - a(1) * RX(:, 3), ...
                 a(1) * RX(:, 2) - a(2) * RX(:, 1)];

    % Axis tangent steps: differentiate Rodrigues' formula in the tangent
    % direction t (the axis moves by exactly t at first order)
    [t1, t2] = geom.axis_tangent(a);
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

    % Landmark coordinates: dY/dX = R, one column of R per coordinate
    R_col = {[R.r11, R.r21, R.r31], [R.r12, R.r22, R.r32], [R.r13, R.r23, R.r33]};

    % ----- Combine: -G * dY for every residual type and parameter -----
    % Residual types: normal rows (2i-1), tangent rows (2i), depth rows
    % (at the end, only where the hinge is active)
    obs        = (1:M)';
    G_all      = {G_n, G_t, G_d};
    row_all    = {2 * obs - 1, 2 * obs, prob.n_img + prob.n_prior + obs};
    select_all = {true(M, 1), true(M, 1), ~valid};

    rows = {};
    cols = {};
    vals = {};

    for q = 1:3
        sel = select_all{q};
        if ~any(sel)
            continue;
        end
        G   = G_all{q}(sel, :);
        rq  = row_all{q}(sel);
        n   = numel(rq);
        tau = prob.tau(sel);
        B   = prob.b_val(sel, :);
        bI  = prob.b_idx(sel, :);
        ids = prob.ids(sel);

        % Residual sensitivity to the rotation angle, shared by omega and k
        g_theta = -sum(G .* dY_dtheta(sel, :), 2);

        % Axis tangent parameters (global indices 1, 2)
        for i = 1:2
            rows{end+1} = rq;                                           %#ok<AGROW>
            cols{end+1} = repmat(i, n, 1);                              %#ok<AGROW>
            vals{end+1} = -sum(G .* dY_daxis{i}(sel, :), 2);            %#ok<AGROW>
        end

        % omega (global index 3)
        rows{end+1} = rq;                                               %#ok<AGROW>
        cols{end+1} = repmat(3, n, 1);                                  %#ok<AGROW>
        vals{end+1} = g_theta .* tau;                                   %#ok<AGROW>

        for d = 1:3
            % cx, cy (global indices 4, 5)
            if d < 3
                rows{end+1} = rq;                                       %#ok<AGROW>
                cols{end+1} = repmat(3 + d, n, 1);                      %#ok<AGROW>
                vals{end+1} = -G(:, d);                                 %#ok<AGROW>
            end

            % Vx, Vy, Vz (global indices 6-8)
            rows{end+1} = rq;                                           %#ok<AGROW>
            cols{end+1} = repmat(5 + d, n, 1);                          %#ok<AGROW>
            vals{end+1} = -G(:, d) .* tau;                              %#ok<AGROW>

            % This observation's landmark, coordinate d
            Rd = R_col{d}(sel, :);
            rows{end+1} = rq;                                           %#ok<AGROW>
            cols{end+1} = prob.n_traj + 3 * (ids - 1) + d;              %#ok<AGROW>
            vals{end+1} = -sum(G .* Rd, 2);                             %#ok<AGROW>
        end

        % The four spline coefficients active at each observation
        for b = 1:4
            rows{end+1} = rq;                                           %#ok<AGROW>
            cols{end+1} = 8 + bI(:, b);                                 %#ok<AGROW>
            vals{end+1} = g_theta .* B(:, b);                           %#ok<AGROW>
            for d = 1:3
                rows{end+1} = rq;                                       %#ok<AGROW>
                cols{end+1} = 8 + K + 3 * (bI(:, b) - 1) + d;           %#ok<AGROW>
                vals{end+1} = -G(:, d) .* B(:, b);                      %#ok<AGROW>
            end
        end
    end

    rows = vertcat(rows{:});
    cols = vertcat(cols{:});
    vals = vertcat(vals{:});

end