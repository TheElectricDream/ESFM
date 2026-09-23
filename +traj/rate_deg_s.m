function rate = rate_deg_s(trajectory, t)
d = 0.05;
rate = rad2deg(traj.angle(trajectory, t(:) + d) - traj.angle(trajectory, t(:) - d)) / (2 * d);
end
