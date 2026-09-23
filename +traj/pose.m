function [R, T] = pose(trajectory, t)
    %   POSE Evaluate the object-to-camera pose at each requested time.
    %
    %   Inputs:
    %       TRAJECTORY -> Initialized trajectory struct.
    %       T -> Vector of M timestamps [s], supplied as the argument t.
    %
    %   Outputs:
    %       R -> Struct of rotation entries returned by geom.rodrigues,
    %            with one rotation per requested time.
    %       T -> [M, 3], translations in model units.
    %
    %   Pose convention:
    %       X_camera = R * X_object + T
    %   for each individual time and column-vector point.
    
    theta = traj.angle(trajectory, t);
    
    R = geom.rodrigues(trajectory.a, theta);
    
    T = traj.translation(trajectory, t);

end
