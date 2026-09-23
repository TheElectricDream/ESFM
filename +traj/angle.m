function theta = angle(trajectory, t)
    %   ANGLE Evaluate the object's rotation angle at each requested time.
    %
    %   Inputs:
    %       TRAJECTORY -> Initialized trajectory struct.
    %       T -> Vector of M timestamps [s], in the same time coordinates
    %            as trajectory.t0.
    %
    %   Output:
    %       THETA -> [M, 1], rotation angles about trajectory.a [rad].
    
    tau = t(:) - trajectory.t0;
    
    baseline = trajectory.omega * tau;
    
    correction = traj.spline_eval(trajectory, t, trajectory.k);
    
    theta = baseline + correction;

end
