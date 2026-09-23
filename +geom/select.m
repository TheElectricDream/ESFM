function [Rs] = select(R, idx)
    %   Extracts the subset of rows from the structure of arrays, which is
    %   used to get per-observation rotations from per-timestamp rotations,
    %   where several observations share one timestep.
    %
    %   Inputs:
    %       R -> Struct, fields r11 to r33 of size [M, 1] representing R
    %       IDX -> [K, 1], the row indices to keep
    %   
    %   Outputs:
    %       Rs -> Struct, same as R but reduced to only [K, 1]

    Rs = structfun(@(e) e(idx), R, 'UniformOutput', false);

end