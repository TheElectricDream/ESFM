%-----%
function trajectory = extrapolate(trajectory, t_supported)
    %   This function continues the spline coefficients beyond the last
    %   time that observations support, at the slope of the last two
    %   coefficients, so that the trajectory predicts smoothly into the
    %   part of the recording that has not been processed yet.
    %
    %   Inputs:
    %       TRAJECTORY -> Struct, trajectory with coefficients fitted up
    %              to T_SUPPORTED
    %       T_SUPPORTED -> Scalar, last supported time [s]
    %
    %   Outputs:
    %       TRAJECTORY -> Struct, with the later coefficients extrapolated

    [idx, ~] = traj.spline_basis(trajectory, t_supported);
    last = idx(end);
    if last >= trajectory.K
        return;
    end

    dk = trajectory.k(last) - trajectory.k(last - 1);
    dm = trajectory.m(last, :) - trajectory.m(last - 1, :);
    n  = (1:trajectory.K - last)';
    trajectory.k(last+1:end)    = trajectory.k(last) + n * dk;
    trajectory.m(last+1:end, :) = trajectory.m(last, :) + n * dm;
end
%-----%
