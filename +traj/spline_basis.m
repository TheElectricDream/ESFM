function [idx, val] = spline_basis(trajectory, t)

    %   Inputs:
    %       TRAJECTORY -> Struct from traj.create_trajectory.
    %       T -> Vector of requested times [s], using the same time origin
    %            as trajectory.t0.
    %
    %   Outputs:
    %       IDX -> [M, 4], indices of the four contributing coefficients
    %              at each requested time.
    %       VAL -> [M, 4], corresponding spline weights.
    
    % We start by converting 'time' into spline-spacing units -- so for
    % example if the initial time is '60', the intervals are '1', and the
    % current time is '62.3', this would result in 'u = 2.3', meaning that
    % the current time stamp 't' is 2.3 'spline intervals' after the
    % reference time 't0'
    u = (t(:) - trajectory.t0) / trajectory.h;
    
    % Then we use that time in spline units to find the segment of data
    % containing the requested time.
    j = min(max(floor(u), 0), trajectory.n_seg - 1);
    
    % Then we calculate the position within the segment
    s = min(max(u - j, -0.5), 1.5);
    
    % Finally we calculate the four weights for a uniform cubin B-spline
    % basis function -- each column of the 'val' variation contains a
    % single weight and each row is one requested time
    val = [(1 - s).^3, ...
        3*s.^3 - 6*s.^2 + 4, ...
        -3*s.^3 + 3*s.^2 + 3*s + 1, ...
        s.^3] / 6;
    
    % This last step converts the zero-based segment index into four MATLAB
    % coefficient indices
    idx = j + (1:4);
    
end