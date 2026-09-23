function write_ply(path, points)
file = fopen(path, 'w');
assert(file > 0, 'Cannot open cloud output: %s', path);
cleanup = onCleanup(@() fclose(file));
fprintf(file, 'ply\nformat ascii 1.0\nelement vertex %d\n', size(points, 1));
fprintf(file, 'property double x\nproperty double y\nproperty double z\nend_header\n');
fprintf(file, '%.17g %.17g %.17g\n', points');
end
