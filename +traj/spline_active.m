function j = spline_active(trajectory, ta, tb)
    %   This function is called by 'select_free_parameters' and its whole
    %   purpose is, for a time 't', find the segment 'seg' and return the
    %   four coefficients which shape that segment, as define by
    %   'seg+(1:4)'.
    %
    %   Inputs:
    %       TRAJECTORY -> Struct, as created in 'traj.create_trajectory'
    %       TA -> Scalar [s], defines the start of the window
    %       TB -> Scalar [s], defines the end of the window
    %
    %   Outputs:
    %       J -> [P, 1], contains the indices of the active coefficients
    %           which are contiguous into 'trajectory.k' (and rows of
    %           'trajectory.m'

    % First we should make sure that the values we are using for the
    % windows make sense
    assert(isscalar(ta) && isscalar(tb) && ta <= tb, ...
        'Window must be two scalar times with ta <= tb.');

    % Next we call the 'spline_basis' function which is what actually finds
    % the four coefficients that shape the segment at both ends of the
    % segment 
    [ia, ~] = traj.spline_basis(trajectory, ta);
    [ib, ~] = traj.spline_basis(trajectory, tb);

    % Since the coefficients are ordered in time everything from TA to TB
    % is active in the window - one thing to note here is that if TB
    % happens to fall exactly on a segment boundary then the final index
    % has 'zero' weight at TB and is therefore only constrained by what
    % came before
    j = (ia(1, 1) : ib(1, 4))';

end