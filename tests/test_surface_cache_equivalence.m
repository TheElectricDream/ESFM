function test_surface_cache_equivalence(cache_file, hdf5_path)
% Compare the streaming front end, driven through the real HDF5 reader, against
% the event-surface cache saved by the offline reference run.
%
% This exercises the whole input path (hyperslab reads, timestamp conversion,
% undistortion, cell fitting) over the full 125 s reference interval, not a
% synthetic subset.
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
if nargin < 1 || isempty(cache_file)
    cache_file = fullfile(root,'output_golden','surface_cache.mat');
end
if nargin < 2 || isempty(hdf5_path)
    hdf5_path = ['/run/media/alexandercrain/Secondary_Drive/Dataset Release 1/' ...
                 'ROT-SG/recording_20251029_131131.hdf5'];
end
C = load(cache_file);
k = C.surface_key;
T0 = k.span(1); T1 = k.span(2);
fprintf('cache: %s, span [%g %g], cell %g px / %g s\n', k.file, T0, T1, k.cell, k.cell_t);

H = run_event_spacecraft_stream('handles');
cfg = run_event_spacecraft_stream('defaults');
cfg.build.exact_reference = true;
cfg.flow.window_s = k.cell_t; cfg.flow.cell_px = k.cell;
cam = H.stream_calibration(fullfile(root,cfg.camera.calibration_xml), cfg.camera);

% reference: undistort the cached interval with the reference intrinsics
t = double(h5read(hdf5_path,'/timestamp')); t = (t - t(1))/1e6;
in = t >= T0 & t < T1;
x = double(h5read(hdf5_path,'/x')); x = x(in);
y = double(h5read(hdf5_path,'/y')); y = y(in);
t = t(in);
assert(numel(t) == numel(C.event_accept), 'Cache length %d differs from loader %d.', ...
    numel(C.event_accept), numel(t));
uv = H.stream_undistort([x y], cam, true);
a = C.event_accept;
ref = [t(a), uv(a,:), C.event_flow(a,:)];

% streaming through the reader
dc = cfg.data; dc.start_time_s = T0; dc.end_time_s = T1;
rdr = H.reader_open(hdf5_path, dc);
fc = H.flow_config(cfg,false);
st = H.surface_open(fc);
got = cell(0,1); cursor = T0;
while cursor < T1-1e-12
    until = min(cursor+cfg.build.dt_s, T1);
    [rdr,raw] = H.reader_packet(rdr, until);
    E = zeros(0,4);
    if ~isempty(raw), E = [raw(:,1), H.stream_undistort(raw(:,2:3),cam,true), raw(:,4)]; end
    cursor = until;
    st = H.surface_push(st, E, cursor, cursor >= T1-1e-12, fc);
    [obs, st] = H.surface_take(st, -inf, inf);
    if ~isempty(obs), got{end+1} = obs; end %#ok<AGROW>
end
got = vertcat(got{:});
fprintf('reference accepted %d, streaming accepted %d (difference %d)\n', ...
    size(ref,1), size(got,1), size(got,1)-size(ref,1));
assert(size(got,1) == size(ref,1), 'Accepted-event counts differ by %d.', size(got,1)-size(ref,1));
d = max(abs(ref-got),[],1);
fprintf('max |difference| over (t, x, y, flow_x, flow_y): %.3g %.3g %.3g %.3g %.3g\n', d);
% Timestamps and pixel coordinates must agree bit-for-bit. The normal-flow
% values are sums over the same events in the same order but through an
% accumarray whose internal strategy depends on the number of groups, so they
% agree to rounding (~1e-13 px/s on a ~10 px/s flow), not bit-for-bit.
assert(all(d(1:3) == 0), 'Accepted events or coordinates differ from the reference.');
assert(all(d(4:5) < 1e-9), 'Normal flow differs from the reference by more than rounding.');
fprintf('PASS: streaming front end reproduces the reference event surface over %.0f s.\n', T1-T0);
end
