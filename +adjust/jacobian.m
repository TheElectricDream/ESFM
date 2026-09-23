function J = jacobian(prob, tr, X)
    %   This function assembles the full sparse Jacobian of the residual
    %   vector with respect to the FREE parameters only.
    %
    %   Inputs:
    %       PROB -> Struct from adjust.setup_problem
    %       TR -> Struct, trajectory at which to linearize
    %       X -> [N, 3], landmark coordinates at which to linearize
    %
    %   Outputs:
    %       J -> [n_res, n_free], sparse Jacobian
    
    [ri, ci, vi] = adjust.image_jacobian(prob, tr, X);
    [rp, cp, vp] = adjust.prior_jacobian(prob, tr, X);
    
    rows = [ri; rp];
    cols = [ci; cp];
    vals = [vi; vp];
    
    % Drop frozen parameters and renumber the rest into solver columns
    keep = prob.param_to_col(cols) > 0;
    J = sparse(rows(keep), prob.param_to_col(cols(keep)), vals(keep), ...
        prob.n_res, prob.n_free);

end