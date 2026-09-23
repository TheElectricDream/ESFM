function checks = inspect_reconstruction(result)
    %   This function checks that a saved reconstruction is internally
    %   consistent and plots it. The checks re-project the final cloud
    %   through the refined trajectory and confirm that the stored
    %   residuals, the metric scaling and the pose rotations all agree.
    %   Geometry is shown at its native gauge, with no alignment or
    %   rescaling.
    %
    %   Inputs:
    %       RESULT -> Struct from prog.package_result (optional fields
    %              warm, online and run_dir are used when present)
    %
    %   Outputs:
    %       CHECKS -> Table of consistency metrics

    X   = result.X;
    O   = result.observations;   % compact IDs: rows of X, not result.O's IDs
    cam = result.camera;

    assert(~isempty(X) && size(X, 2) == 3 && size(O, 2) == 6, 'Invalid result layout.');
    assert(all(O(:, 2) >= 1 & O(:, 2) <= size(X, 1) & O(:, 2) == round(O(:, 2))), ...
        'Observation IDs do not index the filtered point cloud.');

    %% Consistency checks

    % Re-project every observation's landmark at its own time
    [R, T]  = traj.pose(result.traj, O(:, 1));
    [uv, Y] = geom.project(R, T, X(O(:, 2), :), cam);
    dn      = sum((O(:, 3:4) - uv) .* O(:, 5:6), 2);
    rms_px  = sqrt(mean(dn.^2));

    % Scaling points and translations together must not change projections
    uv_m = geom.project(R, T * result.scale.m_per_unit, result.X_m(O(:, 2), :), cam);
    metric_error = max(abs(uv_m - uv), [], 'all');

    % The stored residuals must match the recomputed ones
    residual_error = max(abs(dn - result.normal_residual_px));

    % Every sampled pose rotation must be a proper rotation
    rotation_error = 0;
    for i = 1:size(result.pose.R, 3)
        Ri = result.pose.R(:, :, i);
        rotation_error = max([rotation_error, norm(Ri' * Ri - eye(3), 'fro'), abs(det(Ri) - 1)]);
    end

    checks = table(size(X, 1), size(O, 1), rms_px, residual_error, metric_error, ...
        rotation_error, min(Y(:, 3)), ...
        'VariableNames', {'Points', 'Observations', 'NormalRMS_px', ...
        'StoredResidualError_px', 'MetricProjectionError_px', 'RotationError', ...
        'MinDepth_model'});
    disp(checks);

    assert(residual_error < 1e-7 && metric_error < 1e-7 && rotation_error < 1e-7, ...
        'A result-consistency check failed.');

    %% Figure 1: clouds, map growth, residuals

    f1 = figure('Color', 'w', 'Name', 'Reconstruction: seed, growth and final cloud', ...
                'Position', [50 50 1200 700]);
    tiledlayout(2, 3, 'TileSpacing', 'compact');

    nexttile;
    if isfield(result, 'warm') && isfield(result.warm, 'X')
        plot_cloud(result.warm.X, [], 'Seed cloud (warm start)');
    else
        plot_cloud([], [], 'Seed cloud not stored');
    end

    nexttile;
    if isfield(result, 'warm') && isfield(result.warm, 'joint_X')
        plot_cloud(result.warm.joint_X, [], 'After warm joint adjustment');
    else
        plot_cloud([], [], 'Joint warm cloud not stored');
    end

    nexttile;
    plot_cloud(X, result.nobs, sprintf('Final cloud: %d points, colour = observations', size(X, 1)));

    % Log columns: [time, rate, map count, explained, matched, new, ...]
    nexttile;
    plot(result.log(:, 1), result.log(:, 3), result.log(:, 1), result.log(:, 5));
    grid on;
    xlabel('Time [s]'); ylabel('Count');
    legend('Map points', 'Matched points', 'Location', 'best');
    title('Progressive map growth');

    nexttile;
    plot(result.log(:, 1), 100 * result.log(:, 4));
    grid on;
    xlabel('Time [s]'); ylabel('Explained accepted events [%]');
    title('Association coverage');

    nexttile;
    histogram(dn, 60);
    grid on;
    xlabel('Normal residual [px]'); ylabel('Observations');
    title(sprintf('Final normal RMS %.4f px', rms_px));

    %% Figure 2: refined trajectory, and the online estimate if stored

    has_online = isfield(result, 'online');
    p = result.pose;

    f2 = figure('Color', 'w', 'Name', 'Refined trajectory', 'Position', [70 70 950 800]);
    tiledlayout(3 + has_online, 1, 'TileSpacing', 'compact');

    nexttile;
    plot(p.time_s, p.T_m);
    grid on;
    ylabel('Object origin [m]');
    legend('Camera X', 'Camera Y', 'Camera Z', 'Location', 'best');
    title(sprintf('Refined pose (provisional metric scale = %d)', result.scale.provisional));

    nexttile;
    plot(p.time_s, rad2deg(p.angle_rad));
    grid on;
    ylabel('Fixed-axis angle [deg]');
    if has_online
        hold on;
        plot(result.online.t, rad2deg(result.online.theta), '--');
        legend('Refined (offline)', 'Online', 'Location', 'best');
    end

    nexttile;
    plot(p.time_s, p.rate_deg_s);
    grid on;
    ylabel('Angular rate [deg/s]');

    % How much the offline smoothing changed the real-time angle estimate
    % (model gauge can shift slightly between the two -- compare with care)
    if has_online
        nexttile;
        d = rad2deg(traj.angle(result.traj, result.online.t) - result.online.theta);
        plot(result.online.t, d);
        grid on;
        ylabel('Refined - online [deg]');
    end
    xlabel('Time [s]');

    %% Figure 3: reprojection spot check around the middle of the run

    % Each observation projected with the pose at its own time -- an
    % overlay of nearby observations, not an event-camera frame
    t_all = unique(O(:, 1));
    t_mid = t_all(round((numel(t_all) + 1) / 2));
    [~, idx] = sort(abs(O(:, 1) - t_mid));
    idx = idx(1:min(150, numel(idx)));

    f3 = figure('Color', 'w', 'Name', 'Reprojection spot check');
    plot(O(idx, 3), O(idx, 4), 'k.', 'DisplayName', 'Measured');
    hold on;
    plot(uv(idx, 1), uv(idx, 2), 'ro', 'MarkerSize', 4, 'DisplayName', 'Projected at its own time');
    plot([O(idx, 3), uv(idx, 1)]', [O(idx, 4), uv(idx, 2)]', '-', ...
         'Color', [0.6 0.6 0.6], 'HandleVisibility', 'off');
    set(gca, 'YDir', 'reverse');
    axis equal; grid on;
    legend('Location', 'best');
    xlabel('Undistorted u [px]'); ylabel('Undistorted v [px]');
    title(sprintf('Nearby observations, %.3f to %.3f s', min(O(idx, 1)), max(O(idx, 1))));

    %% Save the figures next to the result, if a run folder is known

    if isfield(result, 'run_dir') && exist(result.run_dir, 'dir')
        exportgraphics(f1, fullfile(result.run_dir, 'fig_reconstruction.png'), 'Resolution', 140);
        exportgraphics(f2, fullfile(result.run_dir, 'fig_pose.png'), 'Resolution', 140);
        exportgraphics(f3, fullfile(result.run_dir, 'fig_reprojection.png'), 'Resolution', 140);
    end

end

function plot_cloud(P, c, ttl)
    %   Scatter a point cloud in the current axes, optionally coloured by
    %   C, or show a placeholder message when P is empty.

    if isempty(P)
        text(0.1, 0.5, ttl);
        axis off;
        return;
    end

    if isempty(c)
        scatter3(P(:, 1), P(:, 2), P(:, 3), 12, 'filled');
    else
        scatter3(P(:, 1), P(:, 2), P(:, 3), 12, c, 'filled');
        colorbar;
    end

    axis equal; grid on; view(3);
    xlabel('X [model]'); ylabel('Y [model]'); zlabel('Z [model]');
    title(ttl);

end