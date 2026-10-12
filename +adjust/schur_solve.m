%-----%
function d = schur_solve(sch, damping)
    %   This function solves the damped normal equations
    %       (H + damping * D + z z') d = -g
    %   with H in the block form of adjust.schur_setup, D = diag(H + z z')
    %   and z the centroid prior row. The landmarks are eliminated through
    %   the Schur complement on the motion block, and the rank-one
    %   centroid term is applied with the Sherman-Morrison formula, so the
    %   step equals the full sparse solve to rounding.
    %
    %   Inputs:
    %       SCH -> Struct from adjust.schur_setup
    %       DAMPING -> Scalar, Levenberg-Marquardt damping
    %
    %   Outputs:
    %       D -> [n_m + 3 n_l, 1], step: free motion parameters first,
    %              then [x y z] per free landmark

    n_m = sch.n_m;
    n_l = sch.n_l;
    dd  = damping * max(sch.diag_h, 1e-9);

    % Damped blocks
    U = sch.U + diag(dd(1:n_m));
    V = sch.V;
    Vinv = zeros(3, 3, 0);
    if n_l > 0
        dl = reshape(dd(n_m + 1:end), 3, 1, n_l);
        for a = 1:3
            V(a, a, :) = V(a, a, :) + dl(a, 1, :);
        end
        Vinv = pageinv(V);
    end

    % Two right-hand sides at once: -g, and z for the rank-one update
    B  = [-sch.g, sch.z];
    Y  = solve_blocks(U, Vinv, sch.W, B, n_m, n_l);
    d0 = Y(:, 1);
    y  = Y(:, 2);
    zy = sch.z' * y;
    if zy ~= 0
        d = d0 - y * ((sch.z' * d0) / (1 + zy));
    else
        d = d0;
    end
end

function Y = solve_blocks(U, Vinv, W, B, n_m, n_l)
    %   Solves [U W; W' V] Y = B for several right-hand sides by
    %   eliminating the landmark blocks (V given by its inverses).
    nb = size(B, 2);
    if n_l == 0
        Y = U \ B;
        return;
    end

    % Landmark rows of B, as pages of [3, nb] per landmark
    Blm = B(n_m + 1:end, :);
    Blp = permute(reshape(Blm, 3, n_l, nb), [1 3 2]);

    if n_m == 0
        Ylp = pagemtimes(Vinv, Blp);
        Y   = reshape(permute(Ylp, [1 3 2]), 3 * n_l, nb);
        return;
    end

    % Schur complement on the motion block
    Z  = pagemtimes(W, Vinv);
    Wm = reshape(W, n_m, 3 * n_l);
    Zm = reshape(Z, n_m, 3 * n_l);
    S  = U - Zm * Wm';
    S  = (S + S') / 2;
    Ym = S \ (B(1:n_m, :) - Zm * Blm);

    % Back-substitution into the landmark blocks
    T   = Blm - Wm' * Ym;
    Tp  = permute(reshape(T, 3, n_l, nb), [1 3 2]);
    Ylp = pagemtimes(Vinv, Tp);
    Y   = [Ym; reshape(permute(Ylp, [1 3 2]), 3 * n_l, nb)];
end
%-----%
