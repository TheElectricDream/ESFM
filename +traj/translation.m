function T = translation(trajectory, t)
    %TRANSLATION Evaluate object-origin translation in the camera frame.
    %
    %   Inputs:
    %       TRAJECTORY -> Initialized trajectory struct.
    %       T -> Vector of M timestamps [s], supplied as the argument t.
    %
    %   Output:
    %       T -> [M, 3], translation vectors [Tx, Ty, Tz] in model units.
    
    tau = t(:) - trajectory.t0;
    
    initialPosition = [trajectory.c, 1];
    
    baseline = initialPosition + tau * trajectory.V;
    
    correction = traj.spline_eval(trajectory, t, trajectory.m);
    
    T = baseline + correction;

end