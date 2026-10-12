function [R] = rodrigues(axis_unit, theta)
    %   Contructs the rotation matrix about a fixed axis through the given
    %   angle theta using Rodrigues'. The nine matrices are returned as
    %   standalone arrays instead of a stack of [3,3] matrices to allow for
    %   element-wise column arithmetic downstream. This rotation matrix maps
    %   the object-frame coordinates to the camera-frame corrdinates and the
    %   axis is the targets spin axis expressed in the camera frame at T0.
    %
    %   Inputs:
    %       AXIS_UNIT -> [1, 3], unit-length spint axis in the camera axis
    %       THETA -> [M, rotation angle at each time in radians
    %
    %   Outputs:
    %       R -> Struct, fields r11 to r33 of size [M, 1] representing R

    R.r11 = cos(theta) + axis_unit(1)^2 * (1 - cos(theta));
    R.r12 = axis_unit(1) * axis_unit(2) * (1 - cos(theta)) - axis_unit(3) * sin(theta);
    R.r13 = axis_unit(1) * axis_unit(3) * (1 - cos(theta)) + axis_unit(2) * sin(theta);
    R.r21 = axis_unit(2) * axis_unit(1) * (1 - cos(theta)) + axis_unit(3) * sin(theta);
    R.r22 = cos(theta) + axis_unit(2)^2 * (1 - cos(theta));
    R.r23 = axis_unit(2) * axis_unit(3) * (1 - cos(theta)) - axis_unit(1) * sin(theta);
    R.r31 = axis_unit(3) * axis_unit(1) * (1 - cos(theta)) - axis_unit(2) * sin(theta);
    R.r32 = axis_unit(3) * axis_unit(2) * (1 - cos(theta)) + axis_unit(1) * sin(theta);
    R.r33 = cos(theta) + axis_unit(3)^2 * (1 - cos(theta));

end