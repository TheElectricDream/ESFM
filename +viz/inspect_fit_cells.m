function inspect_fit_cells(t, x, y, dbg, scfg, opts)
    %INSPECT_FIT_CELLS  Diagnostic figures for the output of fit_cells.
    %
    %   inspect_fit_cells(t, x, y, dbg, scfg)
    %   inspect_fit_cells(t, x, y, dbg, scfg, opts)
    %
    %   Inputs:
    %       t, x, y  - the same event arrays passed to fit_cells
    %       dbg      - second output of fit_cells (per-box intermediates)
    %       scfg     - the config struct passed to fit_cells (thresholds)
    %       opts     - optional struct:
    %           .max_scatter   max events drawn in 3-D scatters (default 5e4)
    %           .arrow_scale   quiver scale for velocity arrows  (default 0.05 s,
    %                          i.e. arrow length = vel * arrow_scale in px)
    %           .good_box      index of a box to show as "good" (default: first ok)
    %           .bad_box       index of a box to show as "bad"  (default: first
    %                          populated box that failed the ok test)
    %
    %   Figures produced:
    %       1  Event cloud in (x, y, t), coloured by box id
    %       2  One good box and one bad box, with fitted normal
    %       3  Event image with velocity field of accepted boxes
    %       4  Raw vs. motion-compensated (warped) event image
    %       5  Histograms of quality metrics against their thresholds
    %       6  Map of accepted / rejected boxes

    if nargin < 6, opts = struct(); end
    max_scatter = getfield_default(opts, 'max_scatter', 5e4);
    arrow_scale = getfield_default(opts, 'arrow_scale', 0.05);

    t = t(:); x = x(:); y = y(:);
    N = numel(t);
    C = numel(dbg.n);
    inv = dbg.inv;
    ok_ev = dbg.ok(inv);

    % Sensor extent, padded a little
    x0 = floor(min(x)); x1 = ceil(max(x));
    y0 = floor(min(y)); y1 = ceil(max(y));

    % Subsample for 3-D scatters (they get slow past ~1e5 points)
    sub = 1:N;
    if N > max_scatter
        sub = round(linspace(1, N, max_scatter));
    end

    %% ---- Figure 1: event cloud coloured by box ------------------------
    figure('Name', '1: Event cloud by box');
    scatter3(x(sub), y(sub), t(sub), 4, inv(sub), 'filled');
    xlabel('x [px]'); ylabel('y [px]'); zlabel('t [s]');
    title(sprintf('Events coloured by box id (%d boxes, %d events shown)', C, numel(sub)));
    colormap(gca, lines(64)); axis tight; grid on; view(-35, 25);

    %% ---- Figure 2: good vs bad box with normal ------------------------
    populated = dbg.n >= scfg.min_events_per_cell;
    good = getfield_default(opts, 'good_box', find(dbg.ok, 1));
    bad  = getfield_default(opts, 'bad_box',  find(populated & ~dbg.ok, 1));

    figure('Name', '2: Good vs bad box');
    boxes = {good, 'Accepted box'; bad, 'Rejected box'};
    for k = 1:2
        c = boxes{k, 1};
        subplot(1, 2, k);
        if isempty(c)
            title([boxes{k, 2} ' (none found)']); continue;
        end
        m = inv == c;
        scatter3(x(m), y(m), t(m), 12, t(m), 'filled'); hold on;
        % Arrow length ~ half the box's spatial extent so it's visible
        L = 0.5 * max([range(x(m)), range(y(m)), 1]);
        nv = dbg.nrm(c, :);
        % nrm(3) is in tau units; convert to seconds for plotting in t
        nv_plot = [nv(1), nv(2), nv(3) * scfg.sigma_s];
        nv_plot = nv_plot / norm(nv_plot) * L;
        quiver3(dbg.mx(c), dbg.my(c), dbg.mt(c), ...
                nv_plot(1), nv_plot(2), nv_plot(3), 0, 'r', 'LineWidth', 2);
        hold off;
        xlabel('x'); ylabel('y'); zlabel('t [s]'); grid on; view(-35, 25);
        title(sprintf('%s #%d\nn=%d  w_{min}=%.2g  w_{mid}=%.2g  plan=%.2g  n_z=%.2f', ...
              boxes{k, 2}, c, dbg.n(c), dbg.w_min(c), dbg.w_mid(c), ...
              dbg.planarity(c), dbg.nrm(c, 3)));
    end

    %% ---- Figure 3: event image + velocity field -----------------------
    img_raw = event_image(x, y, x0, y0, x1, y1);

    figure('Name', '3: Velocity field');
    imagesc([x0 x1], [y0 y1], img_raw); axis image; colormap(gca, gray);
    hold on;
    okc = dbg.ok;
    quiver(dbg.mx(okc), dbg.my(okc), ...
           dbg.vel(okc, 1) * arrow_scale, dbg.vel(okc, 2) * arrow_scale, ...
           0, 'y', 'LineWidth', 1);
    hold off;
    xlabel('x [px]'); ylabel('y [px]');
    title(sprintf('Normal-flow velocity of %d accepted boxes (arrow = vel \\times %.3g s)', ...
          nnz(okc), arrow_scale));

    %% ---- Figure 4: raw vs warped --------------------------------------
    % Compare like with like: only events from accepted boxes in both panels
    img_ok  = event_image(x(ok_ev), y(ok_ev), x0, y0, x1, y1);
    xw = dbg.xw(ok_ev); yw = dbg.yw(ok_ev);
    % Clip warped events to the sensor so the images share an extent
    keep = xw >= x0 & xw <= x1 & yw >= y0 & yw <= y1;
    img_w = event_image(xw(keep), yw(keep), x0, y0, x1, y1);

    figure('Name', '4: Motion compensation');
    cl = [0, max([img_ok(:); img_w(:)])];
    subplot(1, 2, 1);
    imagesc([x0 x1], [y0 y1], img_ok, cl); axis image; colormap(gca, hot);
    title(sprintf('Raw (accepted boxes only)\nmax %d ev/px, std %.3g', ...
          max(img_ok(:)), std(img_ok(:))));
    subplot(1, 2, 2);
    imagesc([x0 x1], [y0 y1], img_w, cl); axis image; colormap(gca, hot);
    title(sprintf('Warped to box mean time\nmax %d ev/px, std %.3g', ...
          max(img_w(:)), std(img_w(:))));
    % std of the image is the contrast in Gallego et al. 2018 -- it should go UP

    %% ---- Figure 5: quality metric histograms --------------------------
    figure('Name', '5: Quality metrics');
    p = populated;

    subplot(2, 2, 1);
    histogram(log10(max(dbg.planarity(p), 1e-12)), 50);
    xlabel('log_{10}(w_{min} / w_{mid})'); ylabel('# boxes');
    title('Planarity (lower = thinner sheet)');

    subplot(2, 2, 2);
    histogram(dbg.w_mid(p), 50); hold on;
    xline(scfg.min_in_surface_extent, 'r--', 'threshold'); hold off;
    xlabel('w_{mid}'); ylabel('# boxes');
    title('In-surface extent');

    subplot(2, 2, 3);
    histogram(abs(dbg.nrm(p, 3)), 50); hold on;
    xline(scfg.min_time_normal, 'r--', 'threshold'); hold off;
    xlabel('|n_z|'); ylabel('# boxes');
    title('Time component of normal');

    subplot(2, 2, 4);
    histogram(dbg.wcnt, 1:max(dbg.wcnt) + 1);
    xlabel('events per warped pixel'); ylabel('# warped pixels');
    title('Support (pile height)');

    %% ---- Figure 6: accepted-box map -----------------------------------
    figure('Name', '6: Accepted boxes');
    imagesc([x0 x1], [y0 y1], img_raw); axis image; colormap(gca, gray);
    hold on;
    scatter(dbg.mx(p & ~dbg.ok), dbg.my(p & ~dbg.ok), 14, 'r', 'filled');
    scatter(dbg.mx(dbg.ok),      dbg.my(dbg.ok),      14, 'g', 'filled');
    hold off;
    legend({'populated, rejected', 'accepted'}, 'Location', 'best');
    xlabel('x [px]'); ylabel('y [px]');
    title(sprintf('%d / %d populated boxes accepted (%.0f%%)', ...
          nnz(dbg.ok), nnz(p), 100 * nnz(dbg.ok) / max(nnz(p), 1)));
end

%% -------------------------------------------------------------------------
function img = event_image(x, y, x0, y0, x1, y1)
    % Count events per integer pixel over the extent [x0 x1] x [y0 y1]
    W = x1 - x0 + 1; H = y1 - y0 + 1;
    ix = round(x) - x0 + 1; iy = round(y) - y0 + 1;
    keep = ix >= 1 & ix <= W & iy >= 1 & iy <= H;
    img = accumarray([iy(keep), ix(keep)], 1, [H, W]);
end

function v = getfield_default(s, name, default)
    if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = default; end
end