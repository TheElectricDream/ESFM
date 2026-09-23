function out = spline_eval(trajectory, t, coef)
    %SPLINE_EVAL Evaluate spline corrections at the requested times.
    %
    %   Inputs:
    %       TRAJECTORY -> Struct containing spline timing and indexing.
    %       T -> Vector of M requested timestamps [s], using the same
    %            time origin as trajectory.t0.
    %       COEF -> [K, D], spline control coefficients:
    %               trajectory.k for angular corrections, D = 1;
    %               trajectory.m for translation corrections, D = 3.
    %
    %   Output:
    %       OUT -> [M, D], evaluated corrections.
    %              Units match COEF: radians for angular corrections,
    %              model units for translation corrections.

    [idx, val] = traj.spline_basis(trajectory, t);
    
    out = zeros(numel(t), size(coef, 2));
    
    for q = 1:4
        out = out + val(:, q) .* coef(idx(:, q), :);
    end

end