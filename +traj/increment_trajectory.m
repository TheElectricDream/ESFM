function trajectory = increment_trajectory(trajectory, p)
% Perturb the axis in its two-dimensional tangent plane, then normalize.
% Add the remaining increments in the parameter order documented above.
% This is an update of fixed-axis trajectory parameters, not a free SE(3) pose.
[t1, t2] = geom.axis_tangent(trajectory.a);
a = trajectory.a(:) + p(1) * t1 + p(2) * t2;
trajectory.a = a / norm(a);
trajectory.omega = trajectory.omega + p(3);
trajectory.c = trajectory.c + p(4:5)';
trajectory.V = trajectory.V + p(6:8)';
K = trajectory.K;
trajectory.k = trajectory.k + p(9:8 + K);
trajectory.m = trajectory.m + reshape(p(9 + K:end), 3, [])';
end
