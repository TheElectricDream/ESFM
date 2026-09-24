function [obs, track_ids] = build_observations(tracks, slice_times)
    %   This function is used to organize the track observations into a
    %   common time frame. Any given track is not guarenteed to
    %   start at the same time, and when we reconstruct the point cloud it
    %   is desirable to query the dataset and ask 'at X [seconds], which
    %   tracks are visible and what observation on said track occurs at
    %   that time step'. Tracks that have fewer than two samples are
    %   rejected. (Hot pixels never reach this point: the surface stage
    %   rejects cells whose events do not move.)
    %
    %   Inputs:
    %       TRACKS -> {1, K} cell, track histories from track.track_events
    %       SLICE_TIMES -> [F, 1], reference times used by tracking
    %
    %   Outputs:
    %       OBS -> [F, N, 4], observations (u, v, normal_x, normal_y), NaN where
    %              track N was not observed in frame F
    %       TRACK_IDS -> [N, 1], map to indicate where each observation is in
    %              the tracks structure

    % Start by converting the time vector into a column (more of a 'just in
    % case')
    slice_times = slice_times(:);

    % Handle any preamble
    numSlices = numel(slice_times);
    numTracks = numel(tracks);

    % Count up the shared time steps and input tracks -- initially every
    % measurement is missing and so we set it to NaN
    obs     = nan(numSlices, numTracks, 4);

    % Initialize the array used to track which 'tracks' pass the filtering
    keep    = false(numTracks, 1);

    % We should define a tolerance for matching time stamps -- this is
    % critical for event cameras since the resolution is so high
    timeScale       = max(1, max(abs(slice_times)));
    timeTolerance   = 32 * eps(timeScale);
    
    % Keep only the tolerance that is small enough that adjacent slice
    % times cannot both match the same sample
    if numSlices > 1
        timeTolerance = min(timeTolerance, min(diff(slice_times)) / 4);
    end

    % Now we process the tracks
    for k = 1:numTracks
        
        h = tracks{k};  % [time, x, y, normal_x, normal_y]
        
        % Check if the history is empty
        if isempty(h)
            continue;  % skip
        end

        % Match the timestamps to the slice indices -- for each sample
        % timestamp, 'matches' tells us if the corresponding time slice
        % exists and 'frame_idx' tells us the index in 'slice_times'
        [matched, frame_idx] = ismembertol(h(:, 1), slice_times,...
            timeTolerance, 'DataScale', 1);
        
        % Assert an error if the timeing does not align between the tracker
        % and observer
        assert(all(matched), ...
            'Track %d contains timestamps that do not match slice_times.', k);
        
        % Reject tracks with single samples as this means there is no
        % motion to assess anyways
        if size(h, 1) < 2
            continue;
        end

        % Store the measurements -- all unobserved slices remain NaN
        obs(frame_idx, k, :) = reshape(h(:, 2:5), [], 1, 4);

        % Mark the track as valid if it has been observed
        keep(k) = true;

    end

    % Finally we remove rejected tracks and keep their IDs
    track_ids = find(keep);
    obs       = obs(:, keep, :);

end