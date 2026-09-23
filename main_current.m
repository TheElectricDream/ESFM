clear;
clc;
close all;

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

% Evaluate the trajectory at the observation times.
[R_slice, T_slice] = traj.pose(trajectory, slice_times);

% Optional: inspect the rotation angle directly.
theta = traj.angle(trajectory, slice_times);

% Display the diagnostic plots.
viz.inspect_trajectory;
viz.inspect_refined_fit;
viz.inspect_tracks;
viz.inspect_build_observations;
viz.inspect_sweep_axes;
viz.inspect_rate_profile;

