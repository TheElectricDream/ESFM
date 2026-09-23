function dn = normal_residuals(trajectory, X, observations, cam)
%   This function computes the plain normal reprojection residual of
%   every observation, in pixels: the pixel error between the observed
%   and projected position, measured across the observed edge.
%
%   Inputs:
%       TRAJECTORY -> Struct, trajectory
%       X -> [N, 3], landmarks, object frame
%       OBSERVATIONS -> [M, 6], rows [time_s, id, u, v, nx, ny]
%       CAM -> Struct, camera model
%
%   Outputs:
%       DN -> [M, 1], normal residuals [px]

[R, T] = traj.pose(trajectory, observations(:, 1));
pr = geom.project(R, T, X(observations(:, 2), :), cam);
dn = sum((observations(:, 3:4) - pr) .* observations(:, 5:6), 2);

end