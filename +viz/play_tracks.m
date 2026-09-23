function play_tracks(tracks, ev, slice_dt, opts)
%   Animates 2D feature tracking one slice at a time, so that track motion
%   can be judged frame by frame rather than as overlaid arcs. Each frame
%   shows the accepted events of that slice, the current sample of every
%   track that was updated in it, and a fading tail of that track's recent
%   history. Tracks keep a fixed colour for their whole life, so a track
%   that jumps between features or dies and is reseeded elsewhere is
%   visible as a colour appearing in the wrong place.
%
%   Inputs:
%       TRACKS -> {1, K} cell, track histories from track.track_events
%       EV -> Struct, event stream with fields t, x, y and accept
%       SLICE_DT -> Scalar, slice length [s], as used for tracking
%       OPTS -> Struct, optional fields:
%                 tail (samples of history drawn, default 15)
%                 pause_s (delay between frames, default 0.05)
%                 video (filename; writes an mp4 instead of pausing)
%                 range (time window [lo hi] to animate, default all)
%
%   Outputs:
%       none (figure, or a video file if opts.video is given)

if nargin < 4, opts = struct(); end
if ~isfield(opts, 'tail'), opts.tail = 15; end
if ~isfield(opts, 'pause_s'), opts.pause_s = 0.05; end

% flatten the track histories into columns: time, x, y, nx, ny, track id
S = [];
for i = 1:numel(tracks)
    S = [S; tracks{i}, repmat(i, size(tracks{i}, 1), 1)]; %#ok<AGROW>
end
frame_times = unique(S(:, 1));
if isfield(opts, 'range')
    frame_times = frame_times(frame_times >= opts.range(1) & frame_times <= opts.range(2));
end
colours = lines(max(7, numel(tracks)));
colours = colours(mod(0:numel(tracks)-1, size(colours, 1)) + 1, :);

fig = figure('Color', 'w', 'Position', [100 100 900 700]);
if isfield(opts, 'video')
    writer = VideoWriter(opts.video, 'MPEG-4'); writer.FrameRate = 15; open(writer);
end
for k = 1:numel(frame_times)
    tc = frame_times(k);
    in_slice = ev.accept & ev.t >= tc - slice_dt/2 & ev.t < tc + slice_dt/2;
    now_rows = S(:, 1) == tc;
    ids = S(now_rows, 6);

    clf; hold on; axis ij equal; xlim([0 640]); ylim([0 480]); box on;
    scatter(ev.x(in_slice), ev.y(in_slice), 4, [0.75 0.75 0.75], '.');
    for id = ids'
        h = S(S(:, 6) == id & S(:, 1) <= tc, :);
        h = h(max(1, end - opts.tail):end, :);
        plot(h(:, 2), h(:, 3), '-', 'Color', colours(id, :), 'LineWidth', 1.2);
        plot(h(end, 2), h(end, 3), 'o', 'Color', colours(id, :), ...
            'MarkerFaceColor', colours(id, :), 'MarkerSize', 5);
        quiver(h(end, 2), h(end, 3), 8 * h(end, 4), 8 * h(end, 5), 0, ...
            'Color', colours(id, :), 'MaxHeadSize', 2);
    end
    title(sprintf('t = %.2f s   |   %d live tracks   |   %d accepted events', ...
        tc, numel(ids), nnz(in_slice)));
    drawnow;
    if isfield(opts, 'video'), writeVideo(writer, getframe(fig));
    else, pause(opts.pause_s); end
end
if isfield(opts, 'video'), close(writer); fprintf('wrote %s\n', opts.video); end
end