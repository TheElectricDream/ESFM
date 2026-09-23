%% Visualize tracks
if isempty(tracks)
    warning('No tracks survived the tracking filters.');
    return;
end

% Remove empty histories for plotting.
tr = tracks(~cellfun(@isempty, tracks));
if isempty(tr)
    warning('All track histories are empty.');
    return;
end

numTracks = numel(tr);
colors = lines(numTracks);

t0 = min(cellfun(@(h) h(1,1), tr));
numObservations = cellfun(@(h) size(h,1), tr);

figure('Color', 'w', 'Name', 'Event track diagnostics');
tiledlayout(2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

%% 1. Image-plane trajectories
ax1 = nexttile;
hold(ax1, 'on');

for i = 1:numTracks
    h = tr{i};

    plot(ax1, h(:,2), h(:,3), '-', ...
        'Color', colors(i,:), 'LineWidth', 1);

    % Circle = start; cross = end.
    plot(ax1, h(1,2), h(1,3), 'o', ...
        'Color', colors(i,:), 'MarkerSize', 4);
    plot(ax1, h(end,2), h(end,3), 'x', ...
        'Color', colors(i,:), 'MarkerSize', 5);
end

axis(ax1, 'equal');
set(ax1, 'YDir', 'reverse');
grid(ax1, 'on');
xlabel(ax1, 'Undistorted x [pixels]');
ylabel(ax1, 'Undistorted y [pixels]');
title(ax1, sprintf('%d tracks: circle = start, cross = end', numTracks));

%% 2. Space-time trajectories
ax2 = nexttile;
hold(ax2, 'on');

for i = 1:numTracks
    h = tr{i};

    plot3(ax2, h(:,2), h(:,3), h(:,1) - t0, '-', ...
        'Color', colors(i,:), 'LineWidth', 1);
end

set(ax2, 'YDir', 'reverse');
grid(ax2, 'on');
view(ax2, 3);
xlabel(ax2, 'Undistorted x [pixels]');
ylabel(ax2, 'Undistorted y [pixels]');
zlabel(ax2, 'Time since first track sample [s]');
title(ax2, 'Track continuity through time');

%% 3. Track-length distribution
ax3 = nexttile;
histogram(ax3, numObservations, 'BinMethod', 'integers');
grid(ax3, 'on');
xlabel(ax3, 'Stored observations per track');
ylabel(ax3, 'Number of tracks');
title(ax3, sprintf('Median track length: %.1f observations', ...
    median(numObservations)));

%% 4. Estimated image edge normals
ax4 = nexttile;
hold(ax4, 'on');

arrowLength = 5;  % Display length in pixels, not flow magnitude.

for i = 1:numTracks
    h = tr{i};

    plot(ax4, h(:,2), h(:,3), '-', ...
        'Color', colors(i,:), 'LineWidth', 0.5);

    % Show at most about 10 arrows per track to limit clutter.
    stride = max(1, ceil(size(h,1) / 10));
    idx = 1:stride:size(h,1);

    quiver(ax4, h(idx,2), h(idx,3), ...
        arrowLength * h(idx,4), arrowLength * h(idx,5), ...
        0, 'Color', colors(i,:), 'LineWidth', 1);
end

axis(ax4, 'equal');
set(ax4, 'YDir', 'reverse');
grid(ax4, 'on');
xlabel(ax4, 'Undistorted x [pixels]');
ylabel(ax4, 'Undistorted y [pixels]');
title(ax4, 'Estimated edge normals: fixed display scale');

linkaxes([ax1, ax4], 'xy');