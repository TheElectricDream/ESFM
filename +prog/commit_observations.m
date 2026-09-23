function map = commit_observations(map, rows)
    %   This function adds this slice's claimed observations to the map
    %   and increments the observation count of every landmark that
    %   claimed.
    %
    %   Inputs:
    %       MAP -> Struct, current reconstruction state
    %       ROWS -> [C, 6], observations [t, id, u, v, nx, ny]
    %
    %   Outputs:
    %       MAP -> Struct, updated state
    
    if isempty(rows)
        return;
    end
    
    map.O = [map.O; rows];
    
    % A landmark claims at most once per slice, so this is +1 per claim
    ids = unique(rows(:, 2));
    map.nobs(ids) = map.nobs(ids) + 1;

end