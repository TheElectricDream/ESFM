function J = jacobian(prob, tr, X, sw)
    %   This function assembles the full sparse Jacobian of the residual
    %   vector with respect to the FREE parameters only.
    %
    %   Inputs:
    %       PROB -> Struct from adjust.setup_problem
    %       TR -> Struct, trajectory at which to linearize
    %       X -> [N, 3], landmark coordinates at which to linearize
    %       SW -> [n_res, 1], optional row weights applied to the values
    %              before assembly (the Cauchy weights; default none)
    %
    %   Outputs:
    %       J -> [n_res, n_free], sparse Jacobian
    
    [ri, ci, vi] = adjust.image_jacobian(prob, tr, X);
    [rp, cp, vp] = adjust.prior_jacobian(prob, tr, X);
    
    rows = [ri; rp];
    cols = [ci; cp];
    vals = [vi; vp];

    %-----%
    % Row weights on the values: cheaper than a diagonal sparse product
    if nargin >= 4 && ~isempty(sw)
        vals = vals .* sw(rows);
    end
    %-----%
    
    % Drop frozen parameters and renumber the rest into solver columns
    keep = prob.param_to_col(cols) > 0;
    J = sparse(rows(keep), prob.param_to_col(cols(keep)), vals(keep), ...
        prob.n_res, prob.n_free);

end