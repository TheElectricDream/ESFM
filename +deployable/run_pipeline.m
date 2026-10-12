function result = run_pipeline(hdf5_path, output_dir, start_s, end_s)
    %   Offline point-cloud reconstruction of a spinning rigid target from
    %   an event recording: the entry point of the deployable pipeline
    %   (deployable.build_standalone compiles it). The stages are those of
    %   main.m in the prototyping tree, as a function and without figures.
    %
    %   Inputs:
    %       HDF5_PATH -> Char, event recording with datasets /timestamp [us],
    %              /x, /y [px] and /polarity
    %       OUTPUT_DIR -> Char, folder for result.mat, the PLY clouds and the
    %              CSV tables (created if missing)
    %       START_S, END_S -> Scalars or chars (command line), time window [s];
    %              default 60 and 185
    %
    %   Outputs:
    %       RESULT -> Struct from deployable.prog.package_result

    if nargin < 3 || isempty(start_s), start_s = 60; end
    if nargin < 4 || isempty(end_s), end_s = 185; end
    if ischar(start_s) || isstring(start_s), start_s = str2double(start_s); end
    if ischar(end_s) || isstring(end_s), end_s = str2double(end_s); end
    hdf5_path  = char(hdf5_path);
    output_dir = char(output_dir);
    assert(isfile(hdf5_path), 'Recording not found: %s', hdf5_path);
    t_all = tic;

    % Set up the configuration
    cfg = deployable.config(hdf5_path, output_dir, start_s, end_s);

    % Load in event data
    tic;
    ev = deployable.io.load_events(cfg.data);
    fprintf('Data Loaded: %f [sec]\n', toc);

    %% [step] Undistort
    % Load in the calibration file
    cam = deployable.io.read_calibration(cfg.camera);

    % Undistort the pixels using the calibration file
    tic;
    xy = deployable.geom.undistort_equidistant([ev.x ev.y], cam);
    fprintf('Data Calibrated: %f [sec]\n', toc);

    % Update the event structure
    ev.x = xy(:,1);
    ev.y = xy(:,2);

    %% [step] Surface Flow
    % Calculate event surfaces (accept mask + normal flow)
    tic;
    t0 = cfg.data.start_time_s;
    t1 = cfg.data.end_time_s;

    [ev.accept, ev.flow] = deployable.surface.compute(ev, cfg.surface, [t0, t1]);

    % [evBaseline.accept, evBaseline.flow] = deployable.surface.compute_baseline( ...
    %     ev, cfg.surface, [warmStart, cfg.data.end_time_s]);
    % ev = evBaseline;

    fprintf('Surfaces Computed: %f [sec]\n', toc);

    %% [step] Seed Tracks
    %-----%
    % Seed tracks over the first seconds, in the solver's measurement-list
    % format. Every re-association pass starts its map from these.
    tic;
    seedEnd = t0 + cfg.warm.duration_s;
    a = ev.accept & ev.t >= t0 & ev.t < seedEnd;
    [tracks, slice_times] = deployable.track.track_events(ev.t(a), ev.x(a), ev.y(a), ev.flow(a, :), ...
        cfg.data.slice_s, cfg.track);
    [obs, ~] = deployable.track.build_observations(tracks, slice_times);
    [fi, ii, uv, nn] = deployable.track.flatten_observations(obs);
    seed = struct('slice_times', slice_times(:), 'fi', fi, 'ii', ii, 'uv', uv, 'nn', nn, ...
                  'ntracks', size(obs, 2));
    fprintf('Seed Tracks Built: %f [sec]\n', toc);

    %% [step] Initialisation
    % Initialisation: 2D tracks in short chunks over the initialisation
    % window, then the motion from a multi-start adjustment with blind
    % rejection rounds (see deployable.warm.init_tracks)
    tic;
    initEnd = t0 + cfg.init.window_s;
    rows = deployable.track.track_chunks(ev, t0, initEnd, cfg.init.chunk_s, cfg.data.slice_s, cfg.track);
    [trajectory, ~, ~] = deployable.warm.init_tracks(rows, cfg, cam);
    trajectory = deployable.traj.extrapolate(trajectory, initEnd);
    fprintf('Initialisation - Motion From Tracks: %f [sec] (rate %.3f deg/s)\n', toc, rad2deg(trajectory.omega));

    %% [step] Re-Association
    % Re-association rounds over the initialisation window: the map rebuilt
    % under the motion, then motion and map refined together
    tic;
    for r = 1:cfg.init.rounds
        [map, info] = deployable.prog.reassociate(ev, trajectory, seed, seedEnd, initEnd, cfg, cam);
        trajectory  = map.traj;
        fprintf('  round %d: %d landmarks, normal RMS %.3f px, rate %.3f deg/s\n', ...
            r, size(map.X, 1), info.rms, rad2deg(trajectory.omega));
    end
    fprintf('Initialisation - Re-association Rounds: %f [sec]\n', toc);
    %-----%

    %% [step] Progressive Loop
    % We can finally start our true looping now -- noting that it is the end of
    % the day and I will definitely need to circle back here
    %% TO BE REVIEWED THOROUGHLY

    %-----%
    % The map from the initialisation rounds is the starting state; the loop
    % continues from the end of the initialisation window
    dt      = cfg.data.slice_s;
    centers = (initEnd + dt / 2 : dt : t1 - dt / 2)';
    %-----%
    [acc_idx, s_first, s_last] = deployable.prog.slice_events(ev.t, ev.accept, centers, dt);

    % Columns: [time, rate_deg_s, map_count, explained_fraction, matched, new]
    run_log  = nan(numel(centers), 6);
    t_prev   = initEnd;
    tic_loop = tic;

    % The spline is free to move from the first slice after the initialisation
    map.knots_free = true;

    % Observation count at the last global adjustment -- the next one runs
    % once the map has grown by cfg.prog.global_growth. Early on, when the map
    % is small, this happens every few slices; later it becomes rare.
    n_at_global = size(map.O, 1);

    % Start the loop
    for f = 1:numel(centers)
        tc = centers(f);

        % This slice's accepted events
        s     = acc_idx(s_first(f):s_last(f));
        slice = struct('t', ev.t(s), 'x', ev.x(s), 'y', ev.y(s), 'flow', ev.flow(s, :));

        % Process the slice
        [map, info] = deployable.prog.step(map, slice, tc, cfg, cam);

        % Local adjustment: recent knots and recently seen points
        if deployable.prog.crossed(t_prev, tc, cfg.prog.local_every_s, trajectory.t0)
            [map, ~] = deployable.prog.local_adjust(map, tc, cam, cfg);
        end

        % Global adjustment: everything, whenever the map has grown enough
        if size(map.O, 1) >= cfg.prog.global_growth * n_at_global
            t_g = tic;
            [map, ginfo] = deployable.prog.global_adjust(map, tc, cam, cfg);
            n_at_global  = size(map.O, 1);
            fprintf('  global adjustment at %.1f s: %d points, %d steps, normal RMS %.3f px (%.1f s)\n', ...
                tc, nnz(map.alive), ginfo.accepted_steps, ginfo.rms, toc(t_g));
        end

        % Log and report
        rate_now = deployable.traj.rate_deg_s(map.traj, tc);
        run_log(f, :) = [tc, rate_now, nnz(map.alive), info.explained, info.matched, info.n_new];

        if deployable.prog.crossed(t_prev, tc, 10, trajectory.t0)  % progress every 10 s
            fprintf('t = %.1f s: map %d, matched %d, explained %.0f %%, rate %.3f deg/s, rows %d (%.0f s)\n', ...
                tc, nnz(map.alive), info.matched, 100 * info.explained, rate_now, ...
                size(map.O, 1), toc(tic_loop));
        end

        t_prev = tc;
    end

    %% [step] Closure
    %-----%
    % Offline closure: one rate scale for the whole recording from the summed
    % votes of the hidden landmarks, the rotation history scaled by it, the
    % map rebuilt under the corrected motion, and a verification vote. If the
    % verification is still off, the correction is applied once more.
    tic;
    [scale, votes] = deployable.prog.closure_vote(map, ev, cfg, cam);
    fprintf('Closure - Vote: scale %+.2f %% (%d attempts)\n', 100 * (scale - 1), nnz(any(isfinite(votes), 2)));
    for pass = 1:cfg.closure.max_passes
        trajectory       = map.traj;
        trajectory.omega = scale * trajectory.omega;
        trajectory.k     = scale * trajectory.k;

        [map, info] = deployable.prog.reassociate(ev, trajectory, seed, seedEnd, t1, cfg, cam);
        [scale, ~] = deployable.prog.closure_vote(map, ev, cfg, cam);
        fprintf('Closure - Pass %d: %d landmarks, normal RMS %.3f px, rate %.3f deg/s, verification %+.2f %%\n', ...
            pass, size(map.X, 1), info.rms, rad2deg(map.traj.omega), 100 * (scale - 1));
        if abs(scale - 1) <= cfg.closure.verify_tol
            break;
        end
    end
    fprintf('Closure: %f [sec]\n', toc);
    %-----%

    %% [step] Refine, Filter & Export
    % Final refinement, packaging, export
    tic;
    final  = deployable.prog.final_refinement(map, cfg.data.end_time_s, cam, cfg);

    %-----%
    % Surface filter: landmarks off the local plane of their neighbours are
    % dropped from the result, with their observations
    scale_m = deployable.prog.calibrate_scale(final.X(final.keep, :), final.keep, cfg.output);
    [flag, ~] = deployable.prog.plane_filter(scale_m.m_per_unit * final.X(final.keep, :), cfg.filter);
    final.keep = final.keep(~flag);
    in_keep    = ismember(final.O(:, 2), final.keep);
    final.O    = final.O(in_keep, :);
    final.dn   = final.dn(in_keep);
    final.revisit = final.revisit(~flag);
    fprintf('Surface Filter: %d of %d landmarks dropped\n', nnz(flag), numel(flag));

    result = deployable.prog.package_result(final, map, run_log, cam, cfg);
    %-----%
    deployable.io.export_result(result, cfg.output.dir);
    fprintf('Final Refinement and Export: %f [sec]\n', toc);

    fprintf('Final: %d of %d landmarks kept, %d observations, normal RMS %.3f px, %d revisited\n', ...
        size(result.X, 1), size(map.X, 1), size(result.O, 1), result.normal_rms_px, nnz(result.revisited));
    fprintf('Mean spin %.4f deg/s, axis [%.4f %.4f %.4f]\n', rad2deg(result.traj.omega), result.traj.a);
    fprintf('Scale %.4f m/unit (%s)\n', result.scale.m_per_unit, result.scale.method);

    %% [step] Inspect (Figure)

    fprintf('Total: %f [sec]\n', toc(t_all));
end
