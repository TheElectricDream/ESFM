function [cols] = select_free_parameters(trajectory, mean_free, knots_upto,...
    knots_from, free_V)
    %   This function is used to select which motion parameters the
    %   opimization is allowed to modify for any particular optimization
    %   run. The optimization treats the 'trajectory' as a single flat
    %   vector with a length of 8+4K, where 'K' is the number of spline
    %   coefficients and the order is set in the function
    %   'increment_trajectory'. 
    %
    %   Inputs:
    %       TRAJECTORY -> Struct, contains t0, h, n_seg, and K to convert
    %           time into indices
    %       MEAN_FREE -> Logical, if true it allow mean-motion, if false no
    %           mean-motion allowed
    %       KNOTS_UPTO -> Scalar [s], sets the end of the window whose
    %           spline coefficients are used
    %       KNOTS_FROM -> Scalar [s], sets the start of the window
    %       FREE_V -> Logical, if true the mean drift is added to the
    %           mean-motion block, if false V is left at the current value
    %
    %   Outputs:
    %       COLS -> [P, 1], indices into the 8 + 4K trajectory parameter
    %           vector that the optimier can modify -- mean-motion indices
    %           are (1:5) or (1:8) depending on MEAN_FREE, angular
    %           coefficients are (8+j), translation coefficients are
    %           (8+K+3(j-1)+i:3) for every coefficient j active in the
    %           window
    

    % Check if the 'mean_free' boolean is true or false, if it is 'true'
    % then we also check if free_V is true or false - Then we set the
    % indices for those parameters accordingly
    if mean_free
        if free_V
            cols = 1:8;
        else
            cols = 1:5;
        end
    else
        cols = [];
    end

    % Next we check is the 'knots_upto' parameter is empty - if it is, then
    % we set a default value equal to 't0' which is the start of the
    % reconstruction interval as defined by 'cfg.data.start_time_s'
    if ~isempty(knots_upto)
        if isempty(knots_from)
            knots_from = trajectory.t0;
        end

        % If 'knots_upto' is defined then we identify all spline
        % coefficients that influence the trajectory within the range
        % [knots_from, knots_upto] - remember that every cubic coefficient
        % for a B-spline shapes FOUR neighbouring segments, and so this
        % goes past both ends of the window and not just the knots that
        % fall within it
        j = traj.spline_active(trajectory, knots_from, knots_upto);

        % Finally, we stack up the 'cols' parameter vector to be used in
        % the optimization
        cols = [cols, (8 + j)', reshape((8 + trajectory.K + 3 * (j - 1)...
            + (1:3))', 1, [])];
    end

    cols = cols(:);

end
