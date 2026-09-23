function j = spline_active(trajectory, ta, tb)
[ia, ~] = traj.spline_basis(trajectory, ta);
[ib, ~] = traj.spline_basis(trajectory, tb);
j = (ia(1, 1) : ib(1, 4))';
end
