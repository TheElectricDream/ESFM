function [c] = robust_cost(prob, r)
    %   This function takes the residuals from 'adjust.residuals' and
    %   calculate the total cost that the optimizer is going to minimize.
    %
    %   Inputs:
    %       PROB -> Struct, as defined in 'adjust.setup_problem'
    %       R -> [n_res, 1], the whitened residuals in the following order
    %              2M       image rows (normal, tangent interleaved)
    %              n_prior  prior rows
    %              M        depth hinge rows
    %
    %   Outputs:
    %       C -> Scalar, total cost to be minimized
        
    % This is pretty straightforward, the cost associated with the image
    % residuals goes through a Cauchy loss function while all other
    % residulas use squares - Cauchy loss is robust to large residuals
    r_img   = r(1:prob.n_img);
    c_img   = sum(prob.cauchy_sq * log1p(r_img.^2 / prob.cauchy_sq));
    c_rest  = sum(r(prob.n_img + 1:end).^2);
    c       = c_img + c_rest;
    
end