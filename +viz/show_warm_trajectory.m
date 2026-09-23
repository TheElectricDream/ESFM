function show_warm_trajectory(trajectory, landmarks, t_window, n_snapshots)
    %   This function plots the motion estimated over a time window: the
    %   rotation angle, the position of the object origin, and a 3D view
    %   of the target in the camera frame at several instants, together
    %   with the spin axis. Nothing is modified.
    %
    %   Inputs:
    %       TRAJECTORY -> Struct, estimated trajectory
    %       LANDMARKS -> [N, 3], object-frame landmark coordinates
    %       T_WINDOW -> [1, 2], start and end times [s], same clock as t0
    %       N_SNAPSHOTS -> Scalar, number of instants drawn in 3D
    %              (default 6)

    if nargin < 4
        n_snapshots = 6;
    end

    % Evaluate the motion densely over the window
    t      = linspace(t_window(1), t_window(2), 400)';
    tau    = t - trajectory.t0;
    theta  = traj.angle(trajectory, t);
    [R, T] = traj.pose(trajectory, t);

    a         = trajectory.a(:);
    omega_deg = rad2deg(trajectory.omega);
    extent    = max(vecnorm(landmarks - mean(landmarks, 1), 2, 2));

    % Summary in the command window
    fprintf('Spin axis (camera frame at t0): [% .4f % .4f % .4f]\n', a);
    fprintf('Axis angle from the optical axis: %.2f deg\n', acosd(abs(a(3))));
    fprintf('Mean rate: %.4f deg/s (period %.1f s)\n', omega_deg, 360 / abs(omega_deg));
    fprintf('Angle swept over the window: %.2f deg\n', rad2deg(theta(end) - theta(1)));
    fprintf('Initial position: [% .4f % .4f 1], drift V: [% .2e % .2e % .2e] units/s\n', ...
        trajectory.c, trajectory.V);

    figure('Name', 'Warm-start trajectory', 'Color', 'w');
    tl = tiledlayout(2, 3, 'TileSpacing', 'compact', 'Padding', 'compact');

    % Rotation angle over time
    nexttile(tl, 1);
    plot(tau, rad2deg(theta), 'LineWidth', 1.5);
    grid on;
    xlabel('time since t_0 [s]');
    ylabel('\theta [deg]');
    title(sprintf('Rotation angle (\\omega = %.3f deg/s)', omega_deg));

    % Object origin position over time
    nexttile(tl, 4);
    plot(tau, T, 'LineWidth', 1.5);
    grid on;
    legend('T_x', 'T_y', 'T_z', 'Location', 'best');
    xlabel('time since t_0 [s]');
    ylabel('model units');
    title('Object origin (camera frame)');

    % 3D scene in the camera frame -- displayed as (x right, z depth,
    % -y up) so the view reads naturally
    ax = nexttile(tl, 2, [2 2]);
    hold(ax, 'on');
    grid(ax, 'on');
    axis(ax, 'equal');
    to_plot = @(P) [P(:, 1), P(:, 3), -P(:, 2)];

    % Camera centre and a small frustum
    d  = 0.3 * T(1, 3);
    cn = d * [-0.5 -0.375 1; 0.5 -0.375 1; 0.5 0.375 1; -0.5 0.375 1];
    cp = to_plot(cn);
    h_cam = plot3(ax, 0, 0, 0, 'k^', 'MarkerFaceColor', 'k', 'MarkerSize', 8);
    for i = 1:4
        plot3(ax, [0 cp(i, 1)], [0 cp(i, 2)], [0 cp(i, 3)], 'k-');
    end
    cp = [cp; cp(1, :)];
    plot3(ax, cp(:, 1), cp(:, 2), cp(:, 3), 'k-');

    % Path of the object origin
    P = to_plot(T);
    h_path = plot3(ax, P(:, 1), P(:, 2), P(:, 3), 'k-', 'LineWidth', 1.5);

    % Spin axis through the object origin at t0
    A = to_plot([T(1, :) - 1.5 * extent * a'; T(1, :) + 1.5 * extent * a']);
    h_axis = plot3(ax, A(:, 1), A(:, 2), A(:, 3), 'r--', 'LineWidth', 2);

    % The landmarks and the body x-axis at several instants, coloured by
    % time
    ks   = round(linspace(1, numel(t), n_snapshots));
    cmap = parula(n_snapshots);
    for i = 1:n_snapshots
        k  = ks(i);
        Rk = structfun(@(v) v(k), R, 'UniformOutput', false);
        Pk = to_plot(geom.apply_pose(Rk, T(k, :), landmarks));
        h_pts = scatter3(ax, Pk(:, 1), Pk(:, 2), Pk(:, 3), 14, ...
            repmat(tau(k), size(Pk, 1), 1), 'filled');

        bx = to_plot([T(k, :); T(k, :) + 0.6 * extent * [Rk.r11, Rk.r21, Rk.r31]]);
        plot3(ax, bx(:, 1), bx(:, 2), bx(:, 3), '-', 'Color', cmap(i, :), 'LineWidth', 2);
    end

    colormap(ax, parula);
    caxis(ax, [tau(1), tau(end)]);
    cb = colorbar(ax);
    cb.Label.String = 'time since t_0 [s]';

    xlabel(ax, 'x (right)');
    ylabel(ax, 'z (depth)');
    zlabel(ax, '-y (up)');
    title(ax, 'Target in the camera frame (lines: body x-axis at each snapshot)');
    legend(ax, [h_cam, h_path, h_axis, h_pts], ...
        {'camera', 'object origin path', 'spin axis', 'landmarks'}, 'Location', 'best');
    view(ax, -35, 20);

end