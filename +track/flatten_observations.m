function [fi, ii, uv, nn] = flatten_observations(obs)
    %   This functions only purpose is to convert the 'obs' array into a
    %   more simple set of lists which are simpler to work with for the
    %   triangulation stage. Remember that the tracker groups events into
    %   short intervals that we are calling slices, and each slice is
    %   represented by it's midpoint time stamp.
    %
    %   Inputs:
    %       OBS -> [F, N, 4], observations returned by 'build_observations'
    %
    %   Outputs:
    %       FI -> [M, 1], slice index of each observation
    %       II -> [M, 1], track index of each observation
    %       UV -> [M, 2], observed pixel location [px]
    %       NN -> [M, 2], unit edge normal at the observation

    % 
    % We start by extracting the slice index 'fi' and the track index 'ii' from
    % the original observation array
    [fi, ii] = find(isfinite(obs(:, :, 1)));
    
    % Then we extract the pixel coordinates [u, v] and the edge-normal
    % direction [nx, ny] from the original observation array
    sz = size(obs);
    uv = [obs(sub2ind(sz, fi, ii, ones(size(fi)))), ...
        obs(sub2ind(sz, fi, ii, 2*ones(size(fi))))];
    nn = geom.unit_rows([obs(sub2ind(sz, fi, ii, 3*ones(size(fi)))), ...
        obs(sub2ind(sz, fi, ii, 4*ones(size(fi))))]);
end