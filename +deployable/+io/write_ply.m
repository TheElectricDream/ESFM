function write_ply(path, points)
    %   This function writes a point cloud as an ASCII PLY file.
    %
    %   Inputs:
    %       PATH -> Char, output file path
    %       POINTS -> [N, 3], point coordinates
    
    fid = fopen(path, 'w');
    assert(fid > 0, 'Cannot open %s for writing.', path);
    cleanup = onCleanup(@() fclose(fid));
    
    fprintf(fid, 'ply\nformat ascii 1.0\nelement vertex %d\n', size(points, 1));
    fprintf(fid, 'property double x\nproperty double y\nproperty double z\nend_header\n');
    fprintf(fid, '%.17g %.17g %.17g\n', points');

end