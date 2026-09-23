function [xobj, R, T] = twist_structure(a, w, q, tau, fi, ii, uv, nn,...
                                        ntracks, cam, wcfg)
    %   This functions purpose is to back out where 3D points SHOULD be
    %   based on a given candidate axis, rotation rate, and translation.
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
    %       XOBJ -> [NTRACKS, 3], landmark positions in the object frame
    %       R -> Struct, per-observation rotation entries
    %       T -> [M, 3], per-observation translation
    
    % For flexibility, the option to enable or disable the average mean
    % velocity drift is included -- here we are just calculating a
    % mask based on a configuration parameter. It's either going to be all
    % '1' if enabled or all '0' if disabled
    V_mask = double(wcfg.free_mean_velocity);

    % Calculate the rotation matrix using the current guess for spin axis
    % and current angle (rate * time)
    Rall = geom.rodrigues(a, w * tau);

    % Calculate one translation vector per slice using the center offset and drift
    % that we calculate in 'initial_guess'
    Tall = [q(1) q(2) 1] + tau * (q(3:5) * V_mask);

    % Now we extract the subset of all rotations and translations when 
    % an observation has occured -- observations from the same slice 
    % get the same pose 
    R = geom.select(Rall, fi);
    T = Tall(fi, :);

    % Finally, we take all observations which belong to the same track 'ii'
    % and we triangulate one 3D point per track
    xobj = geom.triangulate(R, T, ii, uv, nn, ntracks, ...
        wcfg.tangent_weight, cam);
end