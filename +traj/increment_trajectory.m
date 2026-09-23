function [trajectory] = increment_trajectory(trajectory, p)
    %   This function is used to apply a single optimizer step to the
    %   'trajectory' input. Every parameter is incremented through addition
    %   with the exception of the spin axis - this is instead perturbed in
    %   its tangent plane and renormalized such that it stays a unit
    %   vector.
    %
    %   Inputs:
    %       TRAJECTORY -> Struct, as defined in 'traj.create_trajectory'
    %       P -> [8 + 4K, 1], the full parameter vector, with '0' used to
    %           define frozen parameters - parameters are order as:
    %
    %              1:2         axis perturbation along t1, t2
    %              3           omega [rad/s]
    %              4:5         cx, cy
    %              6:8         Vx, Vy, Vz
    %              9:8+K       angular coefficients k
    %              9+K:8+4K    translation coefficients m, [mx my mz]
    %                          per coefficient (see select_free_parameters)
    %
    %   Outputs:
    %       TRAJECTORY -> Struct, contains the updated 'trajectory'
   
    % Since the parameter vector is so uniquely dimensioned it's a good
    % idea to confirm that the size is correct before proceeding
    K = trajectory.K;
    assert(iscolumn(p) && numel(p) == 8 + 4 * K, ...
        'Step must be an (8 + 4K)-by-1 column vector.')

    % Now we want to create the two tangent directions for the CURRENT
    % axis, because p(1:2) is only relevant when used relative to this
    % basis
    [t1, t2] = geom.axis_tangent(trajectory.a);

    % Next we step the axis in the tangent plane and project it back into a
    % unit sphere to ensure it is a unit vector
    a = trajectory.a(:) + p(1)*t1 + p(2)*t2;
    trajectory.a = a / norm(a);

    % Since the we are assuming the mean-motion parameters are all LINEAR,
    % we can increment them using simple addition
    trajectory.omega = trajectory.omega+p(3);
    trajectory.c     = reshape(trajectory.c, 1, 2) + p(4:5)';
    trajectory.V     = reshape(trajectory.V, 1, 3) + p(6:8)';
    
    % Finally, the spline coefficients also need to be incremented
    trajectory.k = trajectory.k(:) + p(9:8 + K);
    trajectory.m = trajectory.m + reshape(p(9 + K:end), 3, [])';
    
    % Implicit expansion would silently turn a shape mismatch above into
    % a matrix, so check the shapes before returning
    assert(isequal(size(trajectory.c), [1, 2]) && isequal(size(trajectory.V), [1, 3]) && ...
        isequal(size(trajectory.k), [K, 1]) && isequal(size(trajectory.m), [K, 3]), ...
        'Trajectory fields changed shape during the increment.');
end
