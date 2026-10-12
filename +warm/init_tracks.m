%-----%
function [trajectory, landmarks, rows] = init_tracks(rows, cfg, cam)
    %   This function initialises the motion from 2D tracks over the
    %   initialisation window. Every track is one landmark; the full
    %   adjuster solves axis, rate, centre, drift, splines and landmarks
    %   together from several starting rates (both spin directions), and
    %   the start with the lowest robust cost wins. Blind rejection rounds
    %   then drop the observations and tracks that the current solution
    %   does not explain and re-solve: tracks that have slid off their
    %   edge pull the rate low, and this recovers most of that bias.
    %
    %   Speed (2026-10-11): the tracks are thinned to every thin_every-th
    %   observation (the motion is constrained by the baseline, not by the
    %   sampling density); every start first runs prune_iterations on a
    %   further subsample and only the prune_keep cheapest starts continue
    %   on the full set; the rejection rounds stop once a round drops less
    %   than reject_stop_frac of the rows. The LM budgets are ceilings
    %   (adjust.refine stops on convergence).
    %
    %   Inputs:
    %       ROWS -> [M, 6], track observations [time, track_id, u, v, nx, ny]
    %       CFG -> Struct, full configuration (cfg.init, cfg.adjust, cfg.data)
    %       CAM -> Struct, camera model
    %
    %   Outputs:
    %       TRAJECTORY -> Struct, the initialised trajectory
    %       LANDMARKS -> [K, 3], one point per surviving track
    %       ROWS -> [M', 6], the surviving observations, track ids 1..K

    icfg  = cfg.init;
    t0    = cfg.data.start_time_s;
    t_end = t0 + icfg.window_s;

    % Tracks inside the window, long enough to constrain a point
    rows = rows(rows(:, 1) < t_end, :);
    rows = renumber(rows, icfg.min_track_length);

    % Thinning: every n-th observation of each track
    thin = 1;
    if isfield(icfg, 'thin_every')
        thin = max(1, round(icfg.thin_every));
    end
    if thin > 1
        rows = renumber(subsample_tracks(rows, thin), icfg.min_track_length);
    end
    N = max(rows(:, 2));

    % Starting centre: the mean observed direction
    m  = (rows(:, 3:4) - cam.principal) ./ cam.focal;
    c0 = mean(m, 1);

    % Multi-start over the spin rate, both directions, from a vertical axis
    seeds = [icfg.rate_seeds_deg_s, -icfg.rate_seeds_deg_s];

    % Pruning: every start for a few iterations on a subsample of the
    % observations; only the cheapest continue on the full set
    prune = isfield(icfg, 'prune_iterations') && icfg.prune_iterations > 0 && ...
            icfg.prune_keep < numel(seeds);
    if prune
        rows_p = renumber(subsample_tracks(rows, icfg.prune_subsample), 2);
        N_p    = max(rows_p(:, 2));
        costs  = inf(1, numel(seeds));
        for i = 1:numel(seeds)
            [~, ~, info] = fit_start(seeds(i), rows_p, N_p, icfg.prune_iterations, c0, t0, t_end, cfg, cam);
            costs(i) = info.cost;
        end
        [~, order] = sort(costs);
        seeds_full = seeds(order(1:icfg.prune_keep));
        fprintf('  pruning (%d rows, %d iterations): costs [%s] for rates [%s] deg/s, keeping [%s]\n', ...
            size(rows_p, 1), icfg.prune_iterations, sprintf('%.4g ', costs), ...
            sprintf('%+g ', seeds), sprintf('%+g ', seeds_full));
    else
        seeds_full = seeds;
    end

    best = [];
    for r = seeds_full
        [tr, X, info] = fit_start(r, rows, N, icfg.iterations, c0, t0, t_end, cfg, cam);
        fprintf('  start %+.1f deg/s: cost %.6g, rate %.3f deg/s, %d iterations\n', ...
            r, info.cost, rad2deg(tr.omega), info.iterations);
        if isempty(best) || info.cost < best.cost
            best = struct('traj', tr, 'X', X, 'cost', info.cost);
        end
    end

    % Express a negative-rate solution as a positive rate about the
    % opposite axis
    trajectory = best.traj;
    landmarks  = best.X;
    if trajectory.omega < 0
        trajectory.a     = -trajectory.a;
        trajectory.omega = -trajectory.omega;
        trajectory.k     = -trajectory.k;
    end

    % Blind rejection rounds under the current solution
    stop_frac = 0;
    if isfield(icfg, 'reject_stop_frac')
        stop_frac = icfg.reject_stop_frac;
    end
    for rr = 1:icfg.reject_rounds
        dn   = adjust.normal_residuals(trajectory, landmarks, rows, cam);
        n    = accumarray(rows(:, 2), 1, [size(landmarks, 1), 1]);
        trms = sqrt(accumarray(rows(:, 2), dn.^2, [size(landmarks, 1), 1]) ./ max(n, 1));
        keep = abs(dn) <= icfg.reject_obs_px & trms(rows(:, 2)) <= icfg.reject_track_rms;

        rows = renumber(rows(keep, :), icfg.min_track_length);
        N = max(rows(:, 2));

        [R, T]    = traj.pose(trajectory, rows(:, 1));
        landmarks = geom.triangulate(R, T, rows(:, 2), rows(:, 3:4), rows(:, 5:6), N, ...
            cfg.adjust.tangent_weight, cam);
        free = traj.select_free_parameters(trajectory, true, t_end, [], cfg.warm.free_mean_velocity);
        [trajectory, landmarks, info] = adjust.refine(trajectory, landmarks, rows, free, (1:N)', ...
            icfg.reject_iterations, cam, cfg.adjust);

        fprintf('  rejection round %d: %d of %d rows kept, %d tracks, rate %.3f deg/s, normal RMS %.3f px, %d iterations\n', ...
            rr, nnz(keep), numel(keep), N, rad2deg(trajectory.omega), info.rms, info.iterations);

        % Converged: this round dropped (almost) nothing
        if 1 - nnz(keep) / numel(keep) < stop_frac
            break;
        end
    end
end

function [tr, X, info] = fit_start(rate_deg_s, rows, N, iterations, c0, t0, t_end, cfg, cam)
    %   One start of the multi-start adjustment: a constant-rate guess
    %   about the axis guess, triangulation under it, then the full
    %   adjuster with everything free over the window.
    icfg     = cfg.init;
    tr       = traj.create_trajectory(t0, cfg.data.end_time_s, cfg.traj.knot_spacing_s);
    tr.a     = icfg.axis_guess(:) / norm(icfg.axis_guess);
    tr.omega = deg2rad(rate_deg_s);
    tr.c     = c0;
    tr.V     = [0 0 0];

    [R, T] = traj.pose(tr, rows(:, 1));
    X = geom.triangulate(R, T, rows(:, 2), rows(:, 3:4), rows(:, 5:6), N, ...
        cfg.adjust.tangent_weight, cam);
    free = traj.select_free_parameters(tr, true, t_end, [], cfg.warm.free_mean_velocity);
    [tr, X, info] = adjust.refine(tr, X, rows, free, (1:N)', iterations, cam, cfg.adjust);
end

function rows = renumber(rows, min_len)
    %   Compact track ids 1..K and drop the tracks shorter than MIN_LEN.
    [~, ~, rows(:, 2)] = unique(rows(:, 2));
    len  = accumarray(rows(:, 2), 1);
    rows = rows(len(rows(:, 2)) >= min_len, :);
    [~, ~, rows(:, 2)] = unique(rows(:, 2));
end

function rows = subsample_tracks(rows, every)
    %   Every EVERY-th observation of each track, counted in time order
    %   within the track (the first observation is always kept).
    if every <= 1
        return;
    end
    [~, ord] = sortrows(rows(:, [2 1]));
    rows  = rows(ord, :);
    first = [true; diff(rows(:, 2)) ~= 0];
    starts = find(first);
    track  = cumsum(first);
    pos    = (1:size(rows, 1))' - starts(track) + 1;
    rows   = rows(mod(pos - 1, every) == 0, :);
end
%-----%
