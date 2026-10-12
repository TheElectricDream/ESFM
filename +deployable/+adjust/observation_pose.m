function [R, T, theta] = observation_pose(prob, tr)
    %   This function is effectively the same as 'deployable.traj.pose', and is used
    %   to calculate the object-to-camera pose for every 'observation' time
    %   - the main difference is that this version reuses the spline
    %   indices and weights that get pre-computed in 'deployable.adjust.setup_problem'
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
    % MATLAB preserves the source vector's orientation when both source
    % and indices are vectors (notably a single observation's 1-by-4
    % indices). Restore M-by-4 explicitly before multiplying weights.
    angular = reshape(tr.k(prob.b_idx), size(prob.b_idx));
    theta = tr.omega * prob.tau + sum(prob.b_val .* angular, 2);

    % Next we apply the translation correct going one axis at a time
    correction = zeros(prob.M, 3);
    for d = 1:3
        md = tr.m(:, d);
        active = reshape(md(prob.b_idx), size(prob.b_idx));
        correction(:, d) = sum(prob.b_val .* active, 2);
    end

    % Combine the baseline translation with the spline correction
    T = [tr.c 1] + prob.tau * tr.V + correction;

    % Construct the planar rotation matrix from the evaluated angle
    R = deployable.geom.rodrigues(tr.a, theta);

end
