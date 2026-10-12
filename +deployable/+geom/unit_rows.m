function [u] = unit_rows(v)
    %   Normalize all rows for the given matrix to unit lengths while
    %   ensuring there is no division by zero.
    %
    %   Inputs:
    %       V -> [N, M], one vector per row
    %
    %   Outputs:
    %       U -> [N, M], same vector, but scaled to unit length
    
    u = v ./ max(vecnorm(v, 2, 2), 1e-12);

end