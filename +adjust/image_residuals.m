function [r_img, r_depth, Y, bad] = image_residuals(prob, tr, X)
    %   This function is used to calculate the whitened image residuals for
    %   every observation. Basically, this code calculates the error in
    %   pixels between where a landmark was seen and where the current
    %   motion model and structure PREDICT it should be - note that it is
    %   also split into components across the edge (normal) and along the
    %   edge (tangent) so that we can weight the tangent properly. Both
    %   components are divided by pixel noise. If an observation is closer
    %   than the minimum depth, a cheirality penalty is applied. The
    %   projection uses the depth frozen at a limit we set, and then a
    %   seperate residual grows with the vollation. This makes the cost
    %   continuous at the limit.
    %
    %   Inputs:
    %       PROB -> Struct, as defined in 'adjust.setup_problem'
    %       TR -> Struct, the trajectory we are evaluating
    %       X -> [N, 3], the landmark coordinates we are evaluating
    %
    %   Outputs:
    %       R_IMG -> [3M, 1], contains the whitened residuals in the format
    %           [normal_1; tangent_1; normal_2; tangent_2; ...]
    %       R_DEPTH -> [M, 1], whitened depth violations, which are zero
    %           for valid observations
    %       Y -> [M, 3], the landmarks seen from the camera frame
    %       BAD -> [M, 1], logical vector, tracks any observations that are
    %           BELOW the minimum depth

    % First we calculate the pose for all of the observations and then move
    % the observations landmarks into the camera frame
    [R, T, theta] = adjust.observation_pose(prob, tr);
    Y      = geom.apply_pose(R, T, X(prob.ids, :));

    % Next we flag observations that are past the depth limit
    bad    = Y(:, 3) < prob.min_depth;

    % Now we clamp the depth values to the limit for the projection, so
    % that above the limit nothing changes but below the limit the image
    % residuals remain continuous and bounded - thus they have an exactly
    % zero derivative with respect to depth
    z = max(Y(:,3), prob.min_depth);

    % We apply the ideal pinhole projection
    pr = prob.cam.focal .* Y(:, 1:2) ./ z+prob.cam.principal;

    % Compute the residuals (pixel error), making sure we keep the normals
    % and tangents split
    dd = prob.uv - pr;
    rn = sum(prob.wn .* dd, 2);
    rt = sum(prob.wt .* dd, 2);

    % Whiten image residuals and apply the depth-violation penalty
    r_img = reshape([rn rt]', [], 1);
    
    % Finally we apply the cheirality penalty, so that we have zero when
    % valid, and then linear growth with violations (Parameshwara et al.,
    % DiffPoseNet, CVPR 2022)
    r_depth = prob.depth_weight * max(0, prob.min_depth - Y(:,3));

end