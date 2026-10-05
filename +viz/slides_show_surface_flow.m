% Settings
t_lo = 100;
t_hi = 100.5;

animationSpan = 20;       % Recording time covered by the GIF [s]
fps = 10;
binPx = 2;
arrowTime = 0.5;         % Arrows show displacement over this duration [s]

windowDuration = t_hi - t_lo;
lastStart = min(t_lo + animationSpan, ev.t(end) - windowDuration);
assert(lastStart >= t_lo, 'The requested window exceeds the recording.');

nFrames = max(2, round((lastStart-t_lo)*fps) + 1);
windowStarts = linspace(t_lo, lastStart, nFrames);

% Full camera view, matching the original density figures.
xEdges = 0:binPx:cam.image_size(1);
yEdges = 0:binPx:cam.image_size(2);
xCentres = (xEdges(1:end-1) + xEdges(2:end))/2;
yCentres = (yEdges(1:end-1) + yEdges(2:end))/2;

% Extract accepted events needed for the animation.
pool = ev.accept & ev.t >= t_lo & ...
       ev.t < lastStart + windowDuration;
assert(any(pool), 'No accepted events in the requested interval.');

x = ev.x(pool);
y = ev.y(pool);
t = ev.t(pool);
flow = ev.flow(pool,:);

% Precompute densities and a common colour scale
frameIndices = cell(nFrames,1);
rawDensity = cell(nFrames,1);
warpedDensity = cell(nFrames,1);
maxCount = 1;

for k = 1:nFrames
    startTime = windowStarts(k);
    referenceTime = startTime + windowDuration/2;

    idx = find(t >= startTime & t < startTime + windowDuration);
    frameIndices{k} = idx;

    xw = x(idx) - flow(idx,1).*(t(idx)-referenceTime);
    yw = y(idx) - flow(idx,2).*(t(idx)-referenceTime);

    rawDensity{k} = histcounts2(x(idx), y(idx), xEdges, yEdges);
    warpedDensity{k} = histcounts2(xw, yw, xEdges, yEdges);

    maxCount = max([maxCount, ...
        max(rawDensity{k}(:)), max(warpedDensity{k}(:))]);
end

% Normal-flow figure
figQ = figure('Color', 'w', 'Position', [50 50 950 650]);
axQ = axes(figQ);

flowPlot = quiver(axQ, NaN, NaN, NaN, NaN, 0, ...
    'Color', [0 0.45 0.74], 'LineWidth', 1);

legend(axQ, flowPlot, ...
    sprintf('Normal flow: %.2f s displacement arrows', arrowTime), ...
    'Location', 'southoutside', ...
    'FontSize', 16, 'FontName', 'Times New Roman');

clockQ = text(axQ, 0.02, 0.98, '', ...
    'Units', 'normalized', 'VerticalAlignment', 'top', ...
    'FontSize', 16, 'FontName', 'Times New Roman', ...
    'BackgroundColor', 'w');

%% Unwarped versus compensated density figure
figD = figure('Color', 'w', 'Position', [60 60 1200 650]);
tiledlayout(figD, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

axRaw = nexttile;
rawPlot = imagesc(axRaw, xCentres, yCentres, ...
    log1p(rawDensity{1}.'));
hold(axRaw, 'on');
rawKey = plot(axRaw, NaN, NaN, 'k-');

legend(axRaw, rawKey, 'Unwarped events', ...
    'Location', 'southoutside', ...
    'FontSize', 16, 'FontName', 'Times New Roman');

clockD = text(axRaw, 0.02, 0.98, '', ...
    'Units', 'normalized', 'VerticalAlignment', 'top', ...
    'FontSize', 16, 'FontName', 'Times New Roman', ...
    'BackgroundColor', 'w');

axWarp = nexttile;
warpedPlot = imagesc(axWarp, xCentres, yCentres, ...
    log1p(warpedDensity{1}.'));
hold(axWarp, 'on');
warpedKey = plot(axWarp, NaN, NaN, 'k-');

legend(axWarp, warpedKey, 'Motion-compensated events', ...
    'Location', 'southoutside', ...
    'FontSize', 16, 'FontName', 'Times New Roman');

colormap(figD, jet(256));
clim(axRaw, [0 log1p(maxCount)]);
clim(axWarp, [0 log1p(maxCount)]);
cb = colorbar(axWarp);
cb.Layout.Tile = 'east';
countTicks = unique([0, 1, round(logspace(0, log10(maxCount), 5))]);
cb.Ticks = log1p(countTicks);
cb.TickLabels = string(countTicks);
cb.Label.String = 'Event Count [events]';
set(cb, 'FontSize', 16, 'FontName', 'Times New Roman');
set(cb.Label, 'FontSize', 16, 'FontName', 'Times New Roman');

%% Apply formatting and keep the view fixed
for ax = [axQ axRaw axWarp]
    axis(ax, 'equal');
    axis(ax, 'tight');
    xlim(ax, [xEdges(1) xEdges(end)]);
    ylim(ax, [yEdges(1) yEdges(end)]);

    grid(ax, 'on');
    box(ax, 'on');
    set(ax, 'YDir', 'reverse', 'GridAlpha', 0.15, ...
        'FontSize', 16, 'FontName', 'Times New Roman');

    xlabel(ax, 'Horizontal Position [px]');
    ylabel(ax, 'Vertical Position [px]');
    axis(ax, 'manual');
end

%% Animate and export both GIFs
quiverFile = fullfile(pwd, 'normal_flow.gif');
densityFile = fullfile(pwd, 'motion_compensation_density.gif');

for k = 1:nFrames
    idx = frameIndices{k};
    arrows = idx(1:20:end);

    set(flowPlot, ...
        'XData', x(arrows), 'YData', y(arrows), ...
        'UData', arrowTime*flow(arrows,1), ...
        'VData', arrowTime*flow(arrows,2));

    set(rawPlot, 'CData', log1p(rawDensity{k}.'));
    set(warpedPlot, 'CData', log1p(warpedDensity{k}.'));

    startTime = windowStarts(k);
    referenceTime = startTime + windowDuration/2;

    set(clockQ, 'String', sprintf('Window: %.2f–%.2f s', ...
        startTime, startTime+windowDuration));
    set(clockD, 'String', sprintf('Reference time: %.2f s', ...
        referenceTime));

    drawnow;

    delay = 1/fps;
    if k == nFrames
        delay = 1;  % Pause briefly on the final frame.
    end

    writeGifFrame(figQ, quiverFile, k == 1, delay);
    writeGifFrame(figD, densityFile, k == 1, delay);
end

%% Local helper — keep this at the bottom of the script
function writeGifFrame(fig, filename, firstFrame, delay)
    frame = getframe(fig);
    [imageData, colourMap] = rgb2ind(frame.cdata, 256);

    if firstFrame
        imwrite(imageData, colourMap, filename, 'gif', ...
            'LoopCount', Inf, 'DelayTime', delay);
    else
        imwrite(imageData, colourMap, filename, 'gif', ...
            'WriteMode', 'append', 'DelayTime', delay);
    end
end