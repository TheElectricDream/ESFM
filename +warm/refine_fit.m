function g = refine_fit(f0, resid, nll, wcfg)
    %   The purpose of this function is to take in a candidate fit for the
    %   relative states, and refine the rotation axis.    
    %
    %   Inputs:
    %       F0 -> Struct, one entry of the sweep output
    %       RESID -> Handle, @(a, w, q) giving raw residuals
    %       NLL -> Handle, @(a, w, q) giving the scalar robust cost
    %       WCFG -> Struct, warm-start parameters
    %
    %   Outputs:
    %       G -> Struct, refined fit with the same fields as F0

    % The first step is to set up the optimization settings
    opts = optimoptions('lsqnonlin', 'Display', 'off', ...
        'MaxFunctionEvaluations', wcfg.max_function_evals,...
        'FunctionTolerance', 1e-8, 'StepTolerance', 1e-8);
    
    % We extract the candidate axis that we get from the 'sweep_axes'
    % function
    a0 = f0.a;

    % This helper function takes in the current candidate axis (so for
    % example, a0 could be [0, 0, 1] which would mean the candidate is
    % rotating about the camera z-axis -- in that case, the 'axis_tangent'
    % function would generate two perpendicular directions to complete the
    % reference frame ([0,1,0] and [1,0,0])
    [t1, t2] = geom.axis_tangent(a0);
    
    % Then we actually construct the axis using the current parameters from
    % the optimization -- we create an anonymous function
    ax = @(p) (a0 + p(1) * t1 + p(2) * t2) / norm(a0 + p(1) * t1 + p(2) * t2);

    % Set up the bounds for the optimization
    lb = [-1, -1, -1, -wcfg.max_centre_offset, -wcfg.max_centre_offset, ...
        -wcfg.max_velocity_per_s, -wcfg.max_velocity_per_s, -wcfg.max_velocity_per_s];
    ub = -lb;

    % Zero axis adjustment means we start exactly at f0.a.
    p0 = [0, 0, f0.w, f0.q];
    
    % Calculate robust residuals for the current candidate motion.
    objective = @(p) warm.cauchy( ...
        resid(ax(p), p(3), p(4:8)), wcfg.cauchy_px);
    
    % Adjust all eight parameters together.
    p = lsqnonlin(objective, p0, lb, ub, opts);

    % Finally, we return the best result
    g = struct('a', ax(p), 'w', p(3), 'q', p(4:8), 'seed', f0.seed, ...
        'cost', nll(ax(p), p(3), p(4:8)));
    
end