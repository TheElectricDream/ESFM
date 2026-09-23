function r = twist_residual(a, w, q, tau, fi, ii, uv, nn, ntracks, cam, wcfg)
    %   This function takes a candidate motion, triangulate the tracks and
    %   project the resulting points back into the image plane. Then, we
    %   calculate the residuals which is used for optimization later on.
    %
    %   Inputs:
    %       A -> [3, 1], unit spin axis in the camera frame
    %       W -> Scalar, rotation rate [rad/s]
    %       Q -> [1, 5], centre offset and drift (cx, cy, Vx, Vy, Vz)
    %       TAU -> [F, 1], time of each frame relative to the window start [s]
    %       FI -> [M, 1], frame index of each observation
    %       II -> [M, 1], track index of each observation
    %       UV -> [M, 2], observed pixel location [px]
    %       NN -> [M, 2], unit edge normal at each observation
    %       NTRACKS -> Scalar, number of tracks
    %       CAM -> Struct, camera model
    %       WCFG -> Struct, warm-start parameters 
    %
    %   Outputs:
    %       R -> [M, 1], edge-normal reprojection error at each observation [px]
    
    % We take the function inputs and we call 'twist_structure', which
    % triangulates the observed tracks into 3D points for the given motion
    [xobj, R_obs, T] = warm.twist_structure(a, w, q, tau, fi, ii, uv,...
        nn, ntracks, cam, wcfg);

    % Now we use our ideal camera pinhole model and we project these 3D
    % points back into the image plane -- 'pr' represented the projected
    % image coordinates [N, 2] and 'Y' represented the point coordinates in
    % the camera frame
    [pr, Y] = geom.project(R_obs, T, xobj(ii, :), cam);

    % Calculate the signed reprojection error along the image edge normal
    r = sum((uv - pr) .* nn, 2);

    % Finally, if the candidate motion puts an observed point below a fixed
    % allowed depth value, we replace the error with a large number to
    % heavily penalize it -- this is a soft methods intended to keep the
    % optimization from accepteding an otherwise good image fit that would
    % place points BEHIND the camera
    r(Y(:, 3) < wcfg.min_depth) = 10;

    % A note for future improvements -- moving this penalty to the
    % optimizer might be a good improvement to make, as right now it is
    % just a heuristic constraint

end