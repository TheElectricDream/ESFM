function cols = select_free_parameters(trajectory, mean_free, knots_upto, knots_from, free_V)
% Return parameter indices that a refinement call is allowed to change.
% A local call freezes mean motion and releases only active spline knots.
% A global call releases mean motion plus the selected knots. free_V=false
% keeps the mean velocity at zero while allowing translation spline motion.
% Column indices (1-based) of the 8 mean parameters and/or the knots whose
% support lies in [knots_from, knots_upto].
if mean_free
    if free_V
        cols = 1:8;
    else
        cols = 1:5;
    end
else
    cols = [];
end
if ~isempty(knots_upto)
    if isempty(knots_from)
        knots_from = trajectory.t0;
    end
    j = traj.spline_active(trajectory, knots_from, knots_upto);
    cols = [cols, (8 + j)', reshape((8 + trajectory.K + 3 * (j - 1) + (1:3))', 1, [])];
end
cols = cols(:);
end
