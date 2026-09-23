function dn = edge_normal_residuals(trajectory, landmarks, observations, focal, principal)
[R, T] = traj.pose(trajectory, observations(:, 1));
pr = geom.project_points(R, T, landmarks(observations(:, 2), :), focal, principal);
dn = sum((observations(:, 3:4) - pr) .* observations(:, 5:6), 2);
end
