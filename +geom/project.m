function [pixel, Y] = project(R, T, xobj, cam)
    %   Takes the object-frame points and projects them into an image using
    %   a rigid transform and the ideal pinhole model. Note that the pixels
    %   here are in the undistorted frame!
    %
    %   Inputs:
    %       R -> Struct, fields r11 to r33 of size [M, 1] representing R
    %       T -> [M, 3], translation of the object origin, camera frame
    %       XOBJ -> [M, 3], points in object frame
    %       CAM -> Struct, camera model with focal and principal lengths
    %
    %   Ouputs:
    %       PIXEL -> [M, 2], projected locations of points [px]
    %       Y -> [M, 3], points in camera frame

    % Calculate the rigid transform to move points in object frame to the
    % camera frame
    Y = geom.apply_pose(R, T, xobj);

    % Make sure we don't break the optimization downstream
    z = max(Y(:, 3), 1e-6);

    % Project the object-frame points to ideal pixels assuming an ideal
    % pinhole model
    pixel = cam.focal .* Y(:, 1:2) ./ z + cam.principal;

end