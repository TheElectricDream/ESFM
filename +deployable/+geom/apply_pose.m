function [Y] = apply_pose(R, T, xobj)
    %   Applies a rigid transform to every point, i.e. calculates Y = R*X+T
    %   on a row-by-row basis.
    %
    %   Inputs:
    %       R -> Struct, fields r11 to r33 of size [M, 1] representing R
    %       T -> [M, 3], translation of the object origin, camera frame
    %       XOBJ -> [M, 3], points in object frame
    %
    %   Ouputs:
    %       Y -> [M, 3], points in camera frame

    Y = [R.r11.*xobj(:,1) + R.r12.*xobj(:,2) + R.r13.*xobj(:,3) + T(:,1), ...
         R.r21.*xobj(:,1) + R.r22.*xobj(:,2) + R.r23.*xobj(:,3) + T(:,2), ...
         R.r31.*xobj(:,1) + R.r32.*xobj(:,2) + R.r33.*xobj(:,3) + T(:,3)];

end