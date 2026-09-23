clear;
clc;
close all;

%% HAS BEEN REVIEWED

% Random definitions I need because I am stupid and these are fundamentals
% in the field.
%
%   LANDMARKS -> Estimated 3D points, fixed to the body of the spacecraft.
%
%   OBSERVATIONS -> A single 3D measurement of ONE landmark at ONE time. In
%   other words, a row of observations [time, landmark_id, u, v, nx, ny]
%   says 'at "time", this landmark's edge appeared at pixel (u,v) with an
%   image normal (nx, ny)'
%
%   TRACK -> A sequence of observations of the same feature over time, in
%   the image only. A track is NOT a landmark, it only becomes one when
%   triangulation converts its 2D hisotry into a single 3D point.
%
%   WHITEN -> Scaling an error by its assumed measurement uncertainty
%
%   PRIOR -> Information about a parameter which does NOT come from a
%   measurement. These are parameters that indicate what I think should
%   happen even before I see data - usually these show up in a least quares
%   problem as extra residuals that don't depend on observations.

% Set up the configuration file
cfg = config();

% Load in event data
tic;
ev = io.load_events(cfg.data);
fprintf('Data Loaded: %f [sec]\n', toc);

% Load in the calibration file
cam = io.read_calibration(cfg.camera);

% Undistort the pixels using the calibration file
tic;
xy = geom.undistort_equidistant([ev.x ev.y], cam);
fprintf('Data Calibrated: %f [sec]\n', toc);

% Update the event structure
ev.x = xy(:,1);
ev.y = xy(:,2);

% Calculate event surfaces (accept mask + normal flow)
tic;
warmStart   = cfg.data.start_time_s;
warmEnd     = warmStart + cfg.warm.duration_s;

[ev.accept, ev.flow] = surface.compute(ev, cfg.surface, [warmStart, warmEnd]);
fprintf('Surfaces Computed: %f [sec]\n', toc);

% Track accepted events into 2D features over the warm-start window
tic;
a = ev.accept & ev.t >= warmStart & ev.t < warmEnd; 
[tracks, slice_times] = track.track_events(ev.t(a), ev.x(a), ev.y(a), ev.flow(a, :), ...
    cfg.data.slice_s, cfg.track);
fprintf('Warm Start - Tracks Generated: %f [sec]\n', toc);

% Tracks can start and end at different times, so we need to organize them
% into a common time axis
tic;
[obs, track_ids] = track.build_observations(tracks, slice_times, ...
    cfg.warm.min_track_motion_px);
fprintf('Warm Start - Observations Built: %f [sec]\n', toc);

wcfg = cfg.warm;

% Times relative to the chosen motion-model origin
tau = slice_times(:) - cfg.data.start_time_s;

% Convert observations into the solver's measurement-list format
tic;
[fi, ii, uv, nn] = track.flatten_observations(obs);
ntracks = size(obs, 2);
fprintf('Warm Start - Flatten Observations: %f [sec]\n', toc);

% Starting centre offset and drift
tic;
[c0, V0] = warm.initial_guess(obs, tau, cam);
fprintf('Warm Start - Initial Guess Generated: %f [sec]\n', toc);

% Wrap the residual function so only the candidate motion remains variable
tic;
resid = @(a, w, q) warm.twist_residual( ...
    a, w, q, tau, fi, ii, uv, nn, ntracks, cam, cfg.warm);

% Scalar score consistent with the objective minimized by sweep_axes
nll = @(a, w, q) sum( ...
    warm.cauchy(resid(a, w, q), cfg.warm.cauchy_px).^2);

% Search the candidate axes and starting rates.
fits = warm.sweep_axes(resid, nll, c0, V0, cfg.warm);
fprintf('Warm Start - Axes Swept: %f [sec]\n', toc);

% Refine the fit
tic;
valid = find(isfinite([fits.cost]));
assert(~isempty(valid), 'No finite sweep candidates.');

[~, j] = min([fits(valid).cost]);
bestCoarse = fits(valid(j));

bestRefined = warm.refine_fit(bestCoarse, resid, nll, wcfg);
fprintf('Warm Start - Fit Refined: %f [sec]\n', toc);

% Rate the profile
tic;
[prof, interval] = warm.rate_profile(bestRefined, resid, nll, wcfg);
fprintf('Warm Start - Rate Profiled: %f [sec]\n', toc);

% Initialize the trajectory structure
trajectory = traj.create_trajectory(cfg.data.start_time_s, cfg.data.end_time_s, ...
                                    cfg.traj.knot_spacing_s);

% Update the trajectory structure with the warm-start values
trajectory.a        = bestRefined.a(:);
trajectory.omega    = bestRefined.w;
trajectory.c        = bestRefined.q(1:2);
trajectory.V        = bestRefined.q(3:5) * double(wcfg.free_mean_velocity);

% Evaluate the trajectory at the observation times
[R_slice, T_slice] = traj.pose(trajectory, slice_times);

% Now we triangulate one object-frame point per warm track at the refine
% motion
tic;
landmarks = geom.triangulate(geom.select(R_slice, fi), T_slice(fi,:), ...
    ii, uv, nn, ntracks, cfg.warm.tangent_weight, cam);

% We 'pack' the observations as M-by-6 rows [time_s, track_id, u, v, nx,
% ny]
observations = [slice_times(fi), ii, uv, nn];
fprintf('Warm Start - Seed Map Triangulated: %f [sec]\n', toc);

% So far we have beein minimizing the "wrong" error so that we have a
% starting point for the real optimization - 'geom.triangulate' minimizes
% the algebraic error, not the pixel reprojection error - now we want to
% solve for motion AND structure together
tic;
free = traj.select_free_parameters(trajectory, true, [], [],...
    cfg.warm.free_mean_velocity);
[trajectory, landmarks, adjust_info] = adjust.refine(trajectory, landmarks, ...
    observations, free, (1:ntracks)', cfg.warm.adjust_iterations, cam, cfg.adjust);
fprintf('Refinement - Problem Setup Complete: %f [sec]\n', toc);

% We can finally start our true looping now -- noting that it is the end of
% the day and I will definitely need to circle back here
%% TO BE REVIEWED THOROUGHLY

% First we need to create the map
map = prog.create_map(trajectory, landmarks, observations);

% Then slice centres tile the recording from the end of the warm start -
% this is just to "simulate" the streaming of events
dt      = cfg.data.slice_s;
centers = (warmEnd + dt / 2 : dt : cfg.data.end_time_s - dt / 2)';
[acc_idx, s_first, s_last] = prog.slice_events(ev.t, ev.accept, centers, dt);

% Columns: [time, rate_deg_s, map_count, explained_fraction, matched, new]
run_log  = nan(numel(centers), 6);
t_prev   = warmEnd;
tic_loop = tic;

% The pose as estimated online, at each slice centre, from past data only
online = struct('t', centers, 'theta', nan(numel(centers), 1), ...
    'T', nan(numel(centers), 3), 'a', nan(numel(centers), 3), ...
    'omega', nan(numel(centers), 1));

% Start the loop
for f = 1:numel(centers)
    tc = centers(f);

    % The spline may move once the warm start is over
    map.knots_free = tc >= warmEnd + cfg.prog.knots_free_after_s;

    % This slice's accepted events
    s     = acc_idx(s_first(f):s_last(f));
    slice = struct('t', ev.t(s), 'x', ev.x(s), 'y', ev.y(s), 'flow', ev.flow(s, :));

    % Process the slice
    [map, info] = prog.step(map, slice, tc, cfg, cam);

    % Local adjustment: recent knots and recently seen points
    if map.knots_free && prog.crossed(t_prev, tc, cfg.prog.local_every_s, trajectory.t0)
        [map, linfo] = prog.local_adjust(map, tc, cam, cfg);
    end

    % Global adjustment: everything well observed so far
    early = any(t_prev - warmEnd < cfg.prog.early_global_s & ...
                tc - warmEnd >= cfg.prog.early_global_s);
    if early || prog.crossed(t_prev, tc, cfg.prog.global_every_s, trajectory.t0)
        t_g = tic;
        [map, ginfo] = prog.global_adjust(map, tc, cam, cfg);
        fprintf('  global adjustment at %.1f s: %d points, %d steps, normal RMS %.3f px (%.1f s)\n', ...
            tc, nnz(map.nobs >= cfg.prog.global_min_nobs), ginfo.accepted_steps, ...
            ginfo.rms, toc(t_g));
    end

    % Online pose at tc, after everything this slice did
    online.theta(f)    = traj.angle(map.traj, tc);
    online.T(f, :)     = traj.translation(map.traj, tc);
    online.a(f, :)     = map.traj.a(:)';
    online.omega(f)    = map.traj.omega;

    % Log and report
    rate_now = traj.rate_deg_s(map.traj, tc);
    run_log(f, :) = [tc, rate_now, nnz(map.alive), info.explained, info.matched, info.n_new];

    if prog.crossed(t_prev, tc, cfg.prog.print_every_s, trajectory.t0)
        fprintf('t = %.1f s: map %d, matched %d, explained %.0f %%, rate %.3f deg/s, rows %d (%.0f s)\n', ...
            tc, nnz(map.alive), info.matched, 100 * info.explained, rate_now, ...
            size(map.O, 1), toc(tic_loop));
    end

    t_prev = tc;
end

% Final refinement, packaging, export
tic;
final  = prog.final_refinement(map, cfg.data.end_time_s, cam, cfg);
result = prog.package_result(final, map, run_log, online, cam, cfg);
io.export_result(result, cfg.output.dir);
fprintf('Final Refinement and Export: %f [sec]\n', toc);

fprintf('Final: %d of %d landmarks kept, %d observations, normal RMS %.3f px, %d revisited\n', ...
    size(result.X, 1), size(map.X, 1), size(result.O, 1), result.normal_rms_px, nnz(result.revisited));
fprintf('Mean spin %.4f deg/s, axis [%.4f %.4f %.4f]\n', rad2deg(result.traj.omega), result.traj.a);
fprintf('Scale %.4f m/unit (%s)\n', result.scale.m_per_unit, result.scale.method);

viz.inspect_reconstruction(result);