function out = view(v, kind, opts, name)
%VIEW What Event Studio draws for a workspace value.
%   out = studio.view(v, 'suggest', [], name) lists the views that fit V.
%   out = studio.view(v, kind, opts, name) builds one view as a struct the
%   browser draws: frames as RGBA bytes, point clouds as float32 bytes
%   (base64), series as numbers. The kinds:
%       frame       events (struct with t, x, y, p; accept and flow once
%                   the surface step has run) accumulated over a window;
%                   opts.mode: polarity | accepted | flow | count
%       cloud3d     the same events as an (x, y, t) point cloud
%       rate        event rate over the recording (all and accepted)
%       trajectory  a trajectory struct (or a struct with .traj): spin
%                   rate, angle and translation over time
%       landmarks   an [N, 3] cloud, or a struct with X (map, final,
%                   result), coloured by observation count, with the
%                   camera path around it when there is a trajectory
%       tracks      observation rows [t id u v nx ny] or a cell of track
%                   histories, drawn over the events of the same window
%       log         the progressive loop's run_log
%       votes       the closure's votes [attempts, scales]
%       series      columns of a numeric matrix
%       image       a numeric matrix as an image
if nargin < 3 || isempty(opts)
    opts = struct();
end
if nargin < 4
    name = '';
end
if strcmp(kind, 'suggest')
    out = suggest(v, name);
    return
end
switch kind
    case 'frame'
        out = eventFrame(v, opts);
    case 'cloud3d'
        out = eventCloud(v, opts);
    case 'rate'
        out = eventRate(v);
    case 'trajectory'
        if isstruct(v) && isfield(v, 'traj') && ~isfield(v, 'omega')
            v = v.traj;
        end
        out = trajectoryView(v, opts);
    case 'landmarks'
        out = landmarks(v);
    case 'tracks'
        out = tracksView(v, opts);
    case 'log'
        out = runLog(v);
    case 'votes'
        out = votesView(v);
    case 'series'
        out = seriesView(v, name);
    case 'image'
        out = imageView(v);
    otherwise
        error('studio:view', 'Unknown view %s', kind);
end
out.kind_requested = kind;
end

% ======================================================================
function k = suggest(v, name)
k = {};
if isstruct(v) && isscalar(v)
    if all(isfield(v, {'t', 'x', 'y'})) && numel(v.t) > 1
        k = [k, {'frame', 'cloud3d', 'rate'}];
    end
    if all(isfield(v, {'omega', 'a', 'k', 'm'}))
        k{end + 1} = 'trajectory';
    end
    if isfield(v, 'X') && isnumeric(v.X) && size(v.X, 2) == 3 && size(v.X, 1) > 0
        k{end + 1} = 'landmarks';
    end
    if isfield(v, 'traj') && isstruct(v.traj) && isfield(v.traj, 'omega')
        k{end + 1} = 'trajectory';
    end
    if isfield(v, 'O') && isnumeric(v.O) && size(v.O, 2) == 6
        k{end + 1} = 'tracks';
    end
elseif iscell(v) && ~isempty(v) && all(cellfun(@(c) isnumeric(c) && size(c, 2) == 5, v(:)))
    k = {'tracks'};
elseif (isnumeric(v) || islogical(v)) && ismatrix(v) && ~isempty(v) && isreal(v)
    [r, c] = size(v);
    if strcmp(name, 'run_log') && c == 6
        k = {'log'};
    elseif strcmp(name, 'votes')
        k = {'votes', 'image'};
    elseif c == 6 && r > 10 && all(v(1:min(r, 200), 2) == round(v(1:min(r, 200), 2)))
        k = {'tracks', 'series'};
    elseif c == 3 && r >= 4
        k = {'landmarks', 'series'};
    elseif r > 3 && c >= 1 && c <= 12
        k = {'series'};
    elseif min(r, c) >= 16
        k = {'image'};
    end
end
end

% ======================================================================
% Colours (the app's palette)
function c = palette(name)
switch name
    case 'bg'
        c = [11 13 17];
    case 'on'
        c = [76 141 255];
    case 'off'
        c = [240 84 90];
end
end

function rgb = viridis(x)
lut = [68 1 84; 72 40 120; 62 74 137; 49 104 142; 38 130 142; 31 158 137; 53 183 121; 110 206 88; 181 222 43; 253 231 37];
x = min(max(x(:), 0), 1) * (size(lut, 1) - 1);
i = min(floor(x), size(lut, 1) - 2);
f = x - i;
rgb = lut(i + 1, :) .* (1 - f) + lut(i + 2, :) .* f;
end

function a = normalise(c)
nz = c(c > 0);
if isempty(nz)
    a = zeros(size(c));
    return
end
s = max(prctile(nz, 99), 1);
a = sqrt(min(c / s, 1));
end

function f = framePayload(rgb, w, h)
% rgb: [w*h, 3] with x running fastest
px = uint8(min(max(round(rgb), 0), 255));
data = [px, 255 * ones(size(px, 1), 1, 'uint8')]';
f = struct('kind', 'frame', 'w', w, 'h', h, 'rgba', matlab.net.base64encode(data(:)'));
end

function s = b64(x, type)
x = cast(x, type);
s = matlab.net.base64encode(typecast(x(:)', 'uint8'));
end

% ======================================================================
% Events
function [i, j, t0, dt] = window(ev, opts, dtDefault)
t = ev.t;
dt = getOpt(opts, 'dt', dtDefault);
t0 = getOpt(opts, 't0', t(1) + 0.5 * (t(end) - t(1)));
i = find(t >= t0, 1);
j = find(t >= t0 + dt, 1) - 1;
if isempty(i)
    i = numel(t) + 1;
end
if isempty(j)
    j = numel(t);
end
end

function [w, h] = imageSize(opts)
w = getOpt(opts, 'w', 640);
h = getOpt(opts, 'h', 480);
cam = baseVar('cam');
if isstruct(cam) && isfield(cam, 'image_size')
    w = cam.image_size(1);
    h = cam.image_size(2);
end
end

function out = eventFrame(ev, opts)
[i, j, t0, dt] = window(ev, opts, 0.05);
[w, h] = imageSize(opts);
mode = getOpt(opts, 'mode', 'polarity');
sel = (i:j)';
x = round(double(ev.x(sel)));
y = round(double(ev.y(sel)));
ok = x >= 0 & x < w & y >= 0 & y < h;
sel = sel(ok);
idx = x(ok) + y(ok) * w + 1;
n = w * h;
bg = palette('bg');
legend = '';
switch mode
    case 'polarity'
        p = ev.p(sel) > 0;
        on = accumarray(idx(p), 1, [n 1]);
        off = accumarray(idx(~p), 1, [n 1]);
        rgb = bg + normalise(on) .* (palette('on') - bg) + normalise(off) .* (palette('off') - bg);
        legend = 'blue: ON, red: OFF';
    case 'count'
        c = accumarray(idx, 1, [n 1]);
        a = log1p(c) / max(log1p(max(prctile(c(c > 0), 99.5), 1)), eps);
        rgb = viridis(a);
        rgb(c == 0, :) = repmat(bg, nnz(c == 0), 1);
        legend = 'events per pixel (log)';
    case {'accepted', 'flow'}
        assert(isfield(ev, 'accept'), 'studio:view', 'Run the Surface flow step first (no ev.accept yet)');
        acc = ev.accept(sel);
        rej = accumarray(idx(~acc), 1, [n 1]);
        if strcmp(mode, 'accepted')
            rgb = bg + normalise(rej) .* ([70 76 92] - bg);
        else
            rgb = repmat(bg, n, 1);
        end
        if isfield(ev, 'flow')
            fl = ev.flow(sel(acc), :);
            ia = idx(acc);
            cs = accumarray(ia, fl(:, 1) ./ max(vecnorm(fl, 2, 2), eps), [n 1]);
            sn = accumarray(ia, fl(:, 2) ./ max(vecnorm(fl, 2, 2), eps), [n 1]);
            cnt = accumarray(ia, 1, [n 1]);
            hue = (atan2(sn, cs) + pi) / (2 * pi);
            val = normalise(cnt);
            col = 255 * hsv2rgb([hue, 0.8 * ones(n, 1), ones(n, 1)]);
            rgb = rgb .* (1 - val) + col .* val;
            legend = 'colour: normal-flow direction; grey: rejected';
        else
            acnt = accumarray(idx(acc), 1, [n 1]);
            rgb = rgb + normalise(acnt) .* (255 - rgb);
        end
    otherwise
        error('studio:view', 'Unknown frame mode %s', mode);
end
out = framePayload(rgb, w, h);
out.count = numel(sel);
out.t0 = t0;
out.dt = dt;
out.t_range = [ev.t(1), ev.t(end)];
out.mode = mode;
out.legend = legend;
out.modes = {'polarity', 'count'};
if isfield(ev, 'accept')
    out.modes = [out.modes, {'accepted', 'flow'}];
end
end

function out = eventCloud(ev, opts)
[i, j, t0, dt] = window(ev, opts, 0.5);
nmax = getOpt(opts, 'n', 60000);
sel = (i:j)';
mode = getOpt(opts, 'mode', 'polarity');
if any(strcmp(mode, {'accepted', 'flow'})) && isfield(ev, 'accept')
    sel = sel(ev.accept(sel));
end
total = numel(sel);
if numel(sel) > nmax
    sel = sel(round(linspace(1, numel(sel), nmax)));
end
xyz = [double(ev.x(sel)), double(ev.y(sel)), (ev.t(sel) - t0) * 1000];
if strcmp(mode, 'flow') && isfield(ev, 'flow')
    fl = ev.flow(sel, :);
    hue = (atan2(fl(:, 2), fl(:, 1)) + pi) / (2 * pi);
    rgb = 255 * hsv2rgb([hue, 0.8 * ones(numel(sel), 1), ones(numel(sel), 1)]);
else
    p = ev.p(sel) > 0;
    rgb = p .* palette('on') + (~p) .* palette('off');
end
[w, h] = imageSize(opts);
out = struct('kind', 'points', 'n', numel(sel), 'total', total, 'xyz', b64(xyz', 'single'), ...
    'rgb', b64(uint8(rgb'), 'uint8'), 'extent', [w h dt * 1000], 'space', 'image', 't0', t0, 'dt', dt, ...
    't_range', [ev.t(1), ev.t(end)]);
out.axes = {'x [px]', 'y [px]', 't [ms]'};
end

function out = eventRate(ev)
t = ev.t;
span = t(end) - t(1);
bw = max(0.1, span / 1500);
edges = t(1):bw:(t(end) + bw);
all = histcounts(t, edges) / bw;
ys = {struct('name', 'all', 'data', all)};
if isfield(ev, 'accept')
    ys{end + 1} = struct('name', 'accepted', 'data', histcounts(t(ev.accept), edges) / bw);
end
if isfield(ev, 'p')
    ys{end + 1} = struct('name', 'ON', 'data', histcounts(t(ev.p > 0), edges) / bw);
end
g = struct('title', 'Event rate', 'xlabel', 't [s]', 'ylabel', 'events / s', 'x', edges(1:end - 1) + bw / 2);
g.ys = ys;
out = struct('kind', 'series', 'groups', {{g}});
end

% ======================================================================
% Motion and structure
function out = trajectoryView(tr, opts)
t0 = tr.t0;
t1 = getOpt(opts, 't_end', t0 + (tr.K - 5) * tr.h);
t = linspace(t0, t1, 1500)';
rate = traj.rate_deg_s(tr, t);
ang = rad2deg(traj.angle(tr, t));
T = traj.translation(tr, t);
corr = rad2deg(traj.spline_eval(tr, t, tr.k));
g1 = struct('title', 'Spin rate', 'xlabel', 't [s]', 'ylabel', 'deg/s', 'x', t');
g1.ys = {struct('name', 'rate', 'data', rate')};
g2 = struct('title', 'Angle correction (spline part)', 'xlabel', 't [s]', 'ylabel', 'deg', 'x', t');
g2.ys = {struct('name', 'k', 'data', corr')};
g3 = struct('title', 'Translation (camera frame)', 'xlabel', 't [s]', 'ylabel', 'model units', 'x', t');
g3.ys = {struct('name', 'x', 'data', T(:, 1)'), struct('name', 'y', 'data', T(:, 2)'), ...
         struct('name', 'z', 'data', T(:, 3)')};
out = struct('kind', 'series', 'groups', {{g1, g2, g3}});
out.meta = struct('mean_rate_deg_s', rad2deg(tr.omega), 'axis', tr.a(:)', 'turns', (ang(end) - ang(1)) / 360, ...
    'knots', tr.K, 'knot_spacing_s', tr.h, 'window', [t0 t1]);
end

function out = landmarks(v)
tr = [];
space = 'model';
color = [];
if isstruct(v)
    X = v.X;
    keep = true(size(X, 1), 1);
    if isfield(v, 'X_m')
        X = v.X_m;
        space = 'metric';
    elseif isfield(v, 'keep')
        keep = false(size(X, 1), 1);
        keep(v.keep) = true;
    elseif isfield(v, 'alive')
        keep = logical(v.alive(:));
    end
    X = X(keep, :);
    if isfield(v, 'nobs') && numel(v.nobs) == numel(keep)
        color = log1p(double(v.nobs(keep)));
    elseif isfield(v, 'nobs') && numel(v.nobs) == size(X, 1)
        color = log1p(double(v.nobs));
    end
    if isfield(v, 'traj')
        tr = v.traj;
    end
else
    X = double(v);
end
if isempty(color)
    color = X(:, 3);
end
rgb = viridis((color - min(color)) / max(max(color) - min(color), eps));
out = struct('kind', 'points', 'n', size(X, 1), 'total', size(X, 1), 'xyz', b64(X', 'single'), ...
    'rgb', b64(uint8(rgb'), 'uint8'), 'space', space);
out.axes = {'x', 'y', 'z'};
out.color_by = 'observation count (log)';
if ~isempty(tr)
    % the camera centre in the object frame: C = -R' T
    t = linspace(tr.t0, tr.t0 + (tr.K - 5) * tr.h, 600)';
    [R, T] = traj.pose(tr, t);
    C = -[R.r11 .* T(:, 1) + R.r21 .* T(:, 2) + R.r31 .* T(:, 3), ...
          R.r12 .* T(:, 1) + R.r22 .* T(:, 2) + R.r32 .* T(:, 3), ...
          R.r13 .* T(:, 1) + R.r23 .* T(:, 2) + R.r33 .* T(:, 3)];
    if strcmp(space, 'metric') && isfield(v, 'scale')
        C = C * v.scale.m_per_unit;
    end
    out.path = b64(C', 'single');
    out.path_n = size(C, 1);
end
end

function out = tracksView(v, opts)
if isstruct(v)
    rows = v.O;
elseif iscell(v)
    rows = cell2mat(cellfun(@(h, k) [h(:, 1), k * ones(size(h, 1), 1), h(:, 2:5)], v(:), ...
        num2cell((1:numel(v))'), 'UniformOutput', false));
else
    rows = double(v);
end
tmin = min(rows(:, 1));
t0 = getOpt(opts, 't0', tmin);
dt = getOpt(opts, 'dt', 3);
sel = rows(:, 1) >= t0 & rows(:, 1) < t0 + dt;
r = sortrows(rows(sel, :), [2 1]);
[ids, first] = unique(r(:, 2), 'stable');
last = [first(2:end) - 1; size(r, 1)];
maxTracks = getOpt(opts, 'max', 900);
pick = 1:numel(ids);
if numel(ids) > maxTracks
    pick = round(linspace(1, numel(ids), maxTracks));
end
lines = cell(1, numel(pick));
hue = zeros(1, numel(pick));
for k = 1:numel(pick)
    q = pick(k);
    seg = r(first(q):last(q), 3:4)';
    lines{k} = round(seg(:)', 2);
    hue(k) = mod(ids(q) * 0.61803, 1);
end
[w, h] = imageSize(opts);
out = struct('kind', 'lines', 'w', w, 'h', h, 't0', t0, 'dt', dt, 'n', numel(ids), 'shown', numel(pick), ...
    't_range', [tmin, max(rows(:, 1))]);
out.lines = lines;
out.hue = hue;
ev = baseVar('ev');
if getOpt(opts, 'background', true) && isstruct(ev) && isfield(ev, 't')
    f = eventFrame(ev, struct('t0', t0 + dt / 2 - 0.05, 'dt', 0.1, 'mode', 'polarity'));
    out.background = f.rgba;
end
end

function out = runLog(L)
L = L(all(isfinite(L(:, 1)), 2), :);
x = L(:, 1)';
g1 = struct('title', 'Spin rate during the loop', 'xlabel', 't [s]', 'ylabel', 'deg/s', 'x', x);
g1.ys = {struct('name', 'rate', 'data', L(:, 2)')};
g2 = struct('title', 'Map', 'xlabel', 't [s]', 'ylabel', 'landmarks', 'x', x);
g2.ys = {struct('name', 'alive', 'data', L(:, 3)'), struct('name', 'matched', 'data', L(:, 5)'), ...
         struct('name', 'new', 'data', L(:, 6)')};
g3 = struct('title', 'Events explained', 'xlabel', 't [s]', 'ylabel', '%', 'x', x);
g3.ys = {struct('name', 'explained', 'data', 100 * L(:, 4)')};
out = struct('kind', 'series', 'groups', {{g1, g2, g3}});
end

function out = votesView(V)
S = size(V, 2);
scales = baseVar('scales');
if ~(isnumeric(scales) && numel(scales) == S)
    cfg = baseVar('cfg');
    if isstruct(cfg) && isfield(cfg, 'closure') && numel(cfg.closure.scales) == S
        scales = cfg.closure.scales;
    else
        scales = 1 + (0:S - 1) / 1000;
    end
end
total = sum(V, 1, 'omitnan');
g = struct('title', 'Summed closure votes', 'xlabel', 'rate scale - 1 [%]', 'ylabel', 'votes', ...
    'x', 100 * (scales(:)' - 1));
g.ys = {struct('name', 'votes', 'data', total)};
[~, j] = max(total);
out = struct('kind', 'series', 'groups', {{g}});
out.meta = struct('best_scale_pct', 100 * (scales(j) - 1), 'attempts', nnz(any(isfinite(V), 2)));
out.image = imageView(V);
end

% ======================================================================
function out = seriesView(M, name)
M = double(M);
[r, c] = size(M);
step = max(1, floor(r / 4000));
rowsShown = 1:step:r;
if c >= 2 && all(diff(M(:, 1)) > 0)
    x = M(rowsShown, 1)';
    cols = 2:min(c, 13);
    xl = 'column 1';
else
    x = rowsShown;
    cols = 1:min(c, 12);
    xl = 'row';
end
g = struct('title', name, 'xlabel', xl, 'ylabel', '', 'x', x);
g.ys = arrayfun(@(k) struct('name', sprintf('col %d', k), 'data', M(rowsShown, k)'), cols, 'UniformOutput', false);
out = struct('kind', 'series', 'groups', {{g}});
end

function out = imageView(M)
M = double(M);
[r, c] = size(M);
sr = max(1, ceil(r / 1024));
sc = max(1, ceil(c / 1024));
M = M(1:sr:end, 1:sc:end);
[h, w] = size(M);
x = M;
ok = isfinite(x);
lo = min(x(ok));
hi = max(x(ok));
a = (x - lo) / max(hi - lo, eps);
a(~ok) = 0;
a = a';                                   % x running fastest
rgb = viridis(a(:));
out = framePayload(rgb, w, h);
out.range = [lo hi];
end

% ======================================================================
function v = getOpt(opts, name, default)
if isstruct(opts) && isfield(opts, name) && ~isempty(opts.(name))
    v = opts.(name);
else
    v = default;
end
end

function v = baseVar(name)
v = [];
if evalin('base', sprintf('exist(''%s'', ''var'') == 1', name))
    v = evalin('base', name);
end
end
