function [r] = prior_residuals(prob, tr, X)
    %   This function is used to calculate the prior residuals that are
    %   used to regularize the trajectory and fix the gauge freedoms of the
    %   reconstruction, which follow the image residuals in the full
    %   residual vector.
    %
    %   Inputs:
    %       PROB -> Struct, as described in deployable.adjust.setup_problem
    %       TR -> Struct, trajectory to evaluate
    %       X -> [N, 3], landmark coordinates 
    %
    %   Outputs:
    %       R -> [n_prior, 1], whitened prior residuals, in order:
    %              K-2     angular curvature
    %              3(K-2)  translation curvature, [x y z] per knot
    %              K       angular pull toward zero
    %              3K      total velocity control coefficients, [x y z]
    %              1       angular correction at t0 (gauge)
    %              3       translation correction at t0 (gauge)
    %              3       translation correction derivative at t0 (gauge)
    %              1       landmark centroid along the axis (gauge)

    % First we extract some parameters
    k = tr.k;
    m = tr.m;
    h = prob.h;
    
    % Then we extract the weights and include the unit conversions
    w_rot = prob.lambda_rotation * (180 /pi);
    w_trans = prob.lambda_translation * 1000;
    
    % Curvature: the second difference of the coefficients divided by h^2
    % is exactly the spline's second derivative at each knot time, so
    % these rows penalize angular and translational acceleration
    r_curv_rot   = w_rot * diff(k, 2, 1) / h^2;
    cm = diff(m, 2, 1);
    % Future frozen zeros are allocation, not observed endpoint conditions.
    cm(prob.support_end-1:end, :) = 0;
    r_curv_trans = w_trans * reshape(cm', [], 1) / h^2;

    % Keep angular pull. Translation uses total velocity rather than
    % correction amplitude, so an unpenalized V cannot bypass the prior.
    r_pull_rot   = prob.pull_fraction * w_rot * k;
    velocity = prob.D_velocity*m + tr.V;
    velocity(prob.support_end:end,:) = 0;
    r_velocity = prob.velocity_weight * reshape(velocity', [], 1);

    % Gauge: the spline correction at t0 must be zero, so that R(t0) = I
    % and T(t0) = [cx, cy, 1] -- this fixes the frame orientation about
    % the axis and, through the depth, the scale
    r_gauge_rot   = prob.gauge_weight * (prob.b0_val * k(prob.b0_idx'));
    r_gauge_trans = prob.gauge_weight * (prob.b0_val * m(prob.b0_idx', :))';
    
    % Resolve V += dv, m_j -= knot_time_j*dv, which leaves T(t) unchanged.
    % This makes V the initial velocity while permitting curved motion.
    r_velocity_gauge = prob.gauge_weight * (prob.b0_derivative * m(prob.b0_idx', :))';
    % Axial-origin gauge: pin the landmark centroid along the spin axis.
    r_centroid = prob.centroid_weight * (tr.a(:)' * mean(X, 1)');

    r = [r_curv_rot; r_curv_trans; r_pull_rot; r_velocity; ...
        r_gauge_rot; r_gauge_trans; r_velocity_gauge; r_centroid];
end
