function [r] = residuals(prob, tr, X)
    %   This function takes in the trajectory and landmarks, and creates the
    %   full residual vector for a single candidate trajectory and set of
    %   landmarks.
    %
    %   Inputs:
    %       PROB -> Struct, as defined in 'adjust.setup_problem'
    %       TR -> Struct, trajectory to be evaluated
    %       X -> [N, 3], landmark coordinates 
    %
    %   Outputs:
    %       R -> [n_res, 1], the whitened residuals in the following order
    %              2M       image rows (normal, tangent interleaved)
    %              n_prior  prior rows
    %              M        depth hinge rows


    % This function is basically calling other functions to keep things
    % organized - basically we get the image residuals and the prior
    % residuals
    [r_img, r_depth] = adjust.image_residuals(prob, tr, X);
    r_prior          = adjust.prior_residuals(prob, tr, X);

    % We finally just stack all the residuals together
    r = [r_img(:); r_prior(:); r_depth(:)];

end