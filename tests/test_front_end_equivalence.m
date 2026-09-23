function test_front_end_equivalence(hdf5_path, t0, t1)
% Prove that the fixed-latency streaming event-surface front end produces
% EXACTLY the offline reference result for the same interval.
%
%   test_front_end_equivalence(path, 60, 70)
%
% Offline reference: one event_surface call over all events of [t0, t1).
% Streaming: the same events delivered in build.dt_s packets through
% surface_open/surface_push/surface_take.
if nargin < 1
    hdf5_path = ['/run/media/alexandercrain/Secondary_Drive/Dataset Release 1/' ...
                 'ROT-SG/recording_20251029_131131.hdf5'];
end
if nargin < 2, t0 = 60; end
if nargin < 3, t1 = 70; end
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
H = run_event_spacecraft_stream('handles');
cfg = run_event_spacecraft_stream('defaults');
cam = H.stream_calibration(fullfile(root, cfg.camera.calibration_xml), cfg.camera);

% ---- load the interval exactly as the offline reference does ----
t = double(h5read(hdf5_path, '/timestamp'));
t = (t - t(1)) / 1e6;
in = t >= t0 & t < t1;
x = double(h5read(hdf5_path, '/x'));  x = x(in);
y = double(h5read(hdf5_path, '/y'));  y = y(in);
p = double(h5read(hdf5_path, '/polarity')); p = p(in);
t = t(in); p(p <= 0) = -1;
uv = H.stream_undistort([x y], cam);
E = [t, uv, p];
good = all(isfinite(E), 2);
E = E(good, :);
fprintf('%d events in [%.1f, %.1f) s\n', size(E,1), t0, t1);

% ---- offline reference ----
fc = H.flow_config(cfg, false);
tic
[ok_ref, flow_ref] = H.event_surface(E(:,1), E(:,2), E(:,3), E(:,4), ...
    fc.cell_px, fc.window_s, fc.time_scale_s, fc.min_events, fc.min_support, ...
    fc.max_planarity, fc.max_speed, fc.min_nt, fc.min_extent, ...
    fc.split_polarities, fc.two_grids);
t_ref = toc;
ref = [E(ok_ref,1:3), flow_ref(ok_ref,:)];
fprintf('offline : %d accepted (%.1f %%) in %.1f s\n', size(ref,1), 100*mean(ok_ref), t_ref);

% ---- streaming ----
st = H.surface_open(fc);
got = zeros(0,5);
cursor = t0; dt = cfg.build.dt_s;
tic
while cursor < t1 - 1e-12
    until = min(cursor + dt, t1);
    pk = E(E(:,1) >= cursor & E(:,1) < until, :);
    cursor = until;
    drain = cursor >= t1 - 1e-12;
    st = H.surface_push(st, pk, cursor, drain, fc);
    [obs, st] = H.surface_take(st, -inf, inf);
    got = [got; obs]; %#ok<AGROW>
end
t_str = toc;
fprintf('stream  : %d accepted in %.1f s (fixed latency %.2f s)\n', ...
    size(got,1), t_str, st.latency_s);

% ---- compare ----
assert(size(got,1) == size(ref,1), ...
    'Accepted-event counts differ: streaming %d, offline %d.', size(got,1), size(ref,1));
[~, o1] = sortrows(ref(:,1:3)); [~, o2] = sortrows(got(:,1:3));
d = max(abs(ref(o1,:) - got(o2,:)), [], 1);
fprintf('max |difference| over (t, x, y, flow_x, flow_y): %.3g %.3g %.3g %.3g %.3g\n', d);
assert(all(d == 0), 'Streaming front end is NOT bit-identical to the offline fit.');
fprintf('PASS: streaming front end is bit-identical to the offline event surface.\n');
end
