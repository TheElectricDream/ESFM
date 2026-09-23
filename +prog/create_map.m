function map = create_map(trajectory, landmarks, observations)
    %   This function creates the reconstruction state that is carried
    %   from one slice to the next, starting from the refined seed map.
    %
    %   Inputs:
    %       TRAJECTORY -> Struct, refined warm-start trajectory
    %       LANDMARKS -> [N, 3], refined seed landmarks, object frame
    %       OBSERVATIONS -> [M, 6], rows [time_s, landmark_id, u, v, nx, ny]
    %
    %   Outputs:
    %       MAP -> Struct with fields:
    %              traj       current trajectory estimate
    %              X          [N, 3], landmarks, object frame
    %              O          [M, 6], all observations; IDs index rows of X
    %              nobs       [N, 1], observations per landmark (sets the
    %                         claim order and the global/final selection)
    %              nrm        [N, 2], latest image normal per landmark
    %                         (gates claims by edge orientation)
    %              cand       struct array of 2D candidate tracks
    %              knots_free logical, spline coefficients may move
    %              created_s  [N, 1], promotion time [s], NaN for seeds
    %              alive      [N, 1], logical, hook for future culling
    %              ratio      per-slice median predicted/measured image
    %                         speed (diagnostic)
    
    N = size(landmarks, 1);
    assert(N > 0 && ~isempty(observations), 'Cannot create an empty map.');
    
    map.traj = trajectory;
    map.X    = landmarks;
    map.O    = observations;
    
    % Observation count per landmark -- every seed must have been seen
    map.nobs = accumarray(observations(:, 2), 1, [N, 1]);
    assert(all(map.nobs > 0), 'A seed landmark has no observations.');
    
    % Latest image normal per landmark: take the row with the LATEST time,
    % rather than relying on the rows being in time order
    map.nrm = zeros(N, 2);
    for i = 1:N
        rows_i = find(observations(:, 2) == i);
        [~, j] = max(observations(rows_i, 1));
        map.nrm(i, :) = observations(rows_i(j), 5:6);
    end
    
    % No 2D candidates yet; times stored in seconds, not slice indices
    map.cand = struct('x', {}, 'y', {}, 'vx', {}, 'vy', {}, ...
        't', {}, 'hist', {}, 'miss', {});
    
    map.knots_free = false;
    map.created_s  = nan(N, 1);
    map.alive      = true(N, 1);
    map.ratio      = [];

end