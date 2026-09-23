function [R, T, theta] = observation_pose(prob, tr)
    %   This function is effectively the same as 'traj.pose', and is used
    %   to calculate the object-to-camera pose for every 'observation' time
    %   - the main difference is that this version reuses the spline
    %   indices and weights that get pre-computed in 'adjust.setup_problem'
    %   instead of recomputing them at each call.
    %
    %   Inputs:
    %       PROB -> Struct, contains the pre-compute problem values
    %       TR -> Struct, contains the trajectory to evaluate
    %
    %   Outputs:
    %       R -> Struct, contains the rotation matrix stored ar r11 through
    %           r33, each of which have a size [M, 1]
    %       T -> [M, 3], translation of the object origin in the camera
    %           frame
    %       THETA -> [M, 1], rotation angle at each observation [rad]

    % First we calculate the rotation angle, which is the constant-rate
    % baseline angle plus the spline correction
    theta = tr.omega * prob.tau + sum(prob.b_val .* tr.k(prob.b_idx), 2);

    % Next we apply the translation correct going one axis at a time
    correction = zeros(prob.M, 3);
    for d = 1:3
        md = tr.m(:, d);
        correction(:, d) = sum(prob.b_val .* md(prob.b_idx), 2);
    end

    % Combine the baseline translation with the spline correction
    T = [tr.c 1] + prob.tau * tr.V + correction;

    % Construct the planar rotation matrix from the evaluated angle
    R = geom.rodrigues(tr.a, theta);

end