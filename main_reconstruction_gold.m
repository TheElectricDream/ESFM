function result = main_reconstruction_gold(options)
% MAIN_RECONSTRUCTION_GOLD  Standalone, offline event-camera reconstruction.
%
% Run from MATLAB (all algorithm helpers are in THIS file):
%   result = main_reconstruction_gold();
%   options = main_reconstruction_gold('defaults');
%   options.make_figures = false;
%   result = main_reconstruction_gold(options);
%
% This is a readable reference implementation of main_gold.m. It estimates
% structure AND a trajectory over one selected recording interval, then
% globally refines both. There is no frozen-map live pose-tracking phase.
% Image tracks inside reconstruction are still needed to triangulate points.
%
% READ IN THIS ORDER
%   0. Configuration and data conventions
%   1. Load and undistort events
%   2. Fit spatiotemporal event surfaces -> image normal flow
%   3. Initialize motion and triangulate a seed map
%   4. Associate observations, grow the map, refine structure and motion
%   5. Refine globally, filter points, refine again
%   6. Apply a provisional physical scale; save poses, cloud and figures
% Local functions follow these stages and have their own mathematical notes.
%
% GEOMETRY AND UNITS
%   Column-vector equation: X_camera(t) = R(t)*X_object + T(t).
%   Arrays store points as rows; apply_pose implements this same equation.
%   Camera coordinates: x right, y down, z forward; pixels use zero origin.
%   Event times are seconds since the FIRST timestamp in the recording.
%   R(t) rotates about ONE fixed unit axis. Angular speed may vary through a
%   scalar cubic spline. Translation has a mean and a 3-component spline.
%   Model lengths are arbitrary until scale is applied AFTER optimization.
%   The object origin is a reconstruction gauge, not an identified CoM.
%
% DATA LAYOUTS USED THROUGHOUT
%   landmarks        N-by-3: object-frame point coordinates in model units.
%   observations     M-by-6: [time_s, original_id, u, v, normal_u, normal_v].
%   flow             E-by-2: image NORMAL flow, in pixels/second.
%   rotation entries one vector per matrix entry, for batched projection.
%   trajectory       see create_trajectory for its fields and parameter order.
%
% IMPORTANT SCOPE
%   Event surfaces use the whole selected interval: this is offline processing.
%   No ground-truth pose or CAD data is used to estimate the result.
%   Numerical choices from main_gold are preserved and explicitly marked where
%   they are approximations. Reproduction is not a proof of physical accuracy.
%   Requirements: MATLAB, Optimization Toolbox (lsqnonlin), Statistics and
%   Machine Learning Toolbox (rangesearch). No project packages are required.
%
% OUTPUTS (a fresh directory for every run)
%   result.mat, cloud_model_units.ply, cloud_m.ply, landmarks.csv,
%   reconstruction_poses.csv, observation_residuals.csv, provenance.mat,
%   initialization.mat, pre_final_refinement.mat, and optional PNG figures.
%   result.X / result.traj / result.O retain the original result conventions.
%   result.observations remaps IDs to rows of result.X for safe direct indexing.

%% 0. Configuration: recording, output, then algorithm constants
if nargin == 0
    options = struct();
end
if (ischar(options) || (isstring(options) && isscalar(options))) && strcmp(options, 'defaults')
    result = default_options();
    return
end
options = resolve_options(options);
START_TIME_S = options.start_time_s;
END_TIME_S = options.end_time_s;
SLICE_DURATION_S = 0.1;
IMAGE_SIZE_PX = [640 480];
JACOBIAN_FD_CHECK = false; % diagnostic of inherited Jacobian approximations

% The following constants are the verified original settings. Edit them here
% when studying an algorithm change, and compare against the saved reference.
% ---- event surfaces (fitted over the whole selected interval)
CELL_SIZE_PX               = 8; % cell_xy
CELL_DURATION_S            = 0.8; % cell_t
TIME_SCALE_S               = 0.03; % sigma: seconds that count as one pixel
MIN_EVENTS_PER_CELL        = 15; % min_n
MIN_WARPED_PIXEL_SUPPORT   = 3; % support
MAX_PLANARITY_RATIO        = 0.45; % planarity_max
MAX_NORMAL_SPEED_PX_S      = 60; % speed_max
MIN_TIME_NORMAL_COMPONENT  = 0.05; % |n_tau| > this (rejects static flicker)
MIN_IN_SURFACE_EXTENT      = 1.0; % lambda_mid > this (kills hot pixels)
SPLIT_POLARITIES           = true; % one grid per polarity
USE_TWO_OFFSET_GRIDS       = true; % second grid shifted by half a cell

% ---- warm-start image tracks and motion initialization ---------
WARM_START_DURATION_S      = 6.0; % WARM_L
WARM_TRACK_GATE_PX         = 3.0; % tracker gate in the warm start
WARM_TRACK_MAX_MISS        = 15; % slices unobserved before retirement
TRACK_MIN_LENGTH           = 20; % samples (min_len)
TRACK_MIN_EVENTS           = 3; % per claim / per seed
TRACK_SEED_CELL_PX         = 6;
TRACK_POSITION_GAIN        = 0.6; % Kx
TRACK_VELOCITY_GAIN        = 0.25; % Kv
MIN_OBS_PER_WARM_TRACK     = 15; % slices with a sample
MIN_TRACK_MOTION_PX        = 0.5; % pixel std; kills hot-pixel tracks
HEMISPHERE_DIRECTIONS      = 13; % axis sweep (Fibonacci spiral), both signs
CANDIDATE_BASE_AXIS        = [0 -1 0];
WARM_RATE_SEEDS_DEG_S      = [2 4 6 8 10]; % replaces the light-curve harmonics
WARM_CAUCHY_PX             = 2.0; % f_scale of the warm-start fits
WARM_MAX_FUNCTION_EVALS    = 600;
WARM_MAX_VELOCITY_PER_S    = 0.2; % |V| bound in the warm-start fits [range/s] (initialisation only)
WARM_MAX_CENTRE_OFFSET     = 1.0; % |c_xy| bound in the warm-start fits [range]
RATE_PROFILE_DEG_S         = 1:0.2:12; % the valley figure
FREE_MEAN_VELOCITY         = false; % pin mean drift; translation spline corrections remain free

% ---- trajectory and joint refinement --------------------------------
KNOT_SPACING_S             = 1.0; % DK
PIXEL_NOISE_STD_PX         = 0.5; % SIG
TANGENT_RESIDUAL_WEIGHT    = 0.15; % EPS
CAUCHY_SCALE_PX            = 4.0; % CAUCHY (adjust)
ROTATION_ACCEL_WEIGHT      = 500; % lambda_theta [per deg/s^2]
TRANSLATION_ACCEL_WEIGHT   = 200; % lambda_T     [per permil/s^2]
KNOT_VALUE_PULL_FRACTION   = 0.1; % 04: 0.1*lambda pulls the knot values to zero (0 = off)
GAUGE_WEIGHT               = 1e4; % theta(t0) = 0, T(t0) = c
AXIS_CENTROID_WEIGHT       = 1e2; % weak centroid residual along the axis only
MIN_LANDMARK_DEPTH         = 0.2; % residual clamped to 10 below this depth
LM_INITIAL_DAMPING         = 1e-3;
WARM_ADJUST_ITERATIONS     = 20; % joint (mean + structure) after the warm start
KNOT_CORRECTION_ITERATIONS = 3; % inside step(), active knots on the last LOCAL_WINDOW_S
LOCAL_ADJUST_ITERATIONS    = 8;
GLOBAL_ADJUST_ITERATIONS   = 10;
FINAL_ADJUST_ITERATIONS    = [20 10];

% ---- progressive reconstruction ------------------------------
GATE_NORMAL_PX             = 3.0; % GATE_N
GATE_TANGENT_PX            = 8.0; % GATE_T
COVARIANCE_GATE            = 0.03; % sigma_X of a new point [units of range]
LOCAL_ADJUST_EVERY         = 10; % batches (1 s)
LOCAL_WINDOW_S             = 3.0;
GLOBAL_ADJUST_EVERY        = 100; % batches (10 s)
EARLY_GLOBAL_BATCHES       = [10 30 60];
KNOTS_FREE_AFTER_S         = 0.0; % after the warm start
MIN_MATURE_CLAIMS          = 6; % for the in-slice knot correction
MIN_NOBS_FOR_GLOBAL        = 10;
CANDIDATE_GATE_PX          = 3.0;
CANDIDATE_MAX_MISS         = 5;
CANDIDATE_MIN_SAMPLES      = 12;
CANDIDATE_MIN_TURN_DEG     = 8.0;
CANDIDATE_MIN_DEPTH        = 0.3;
CANDIDATE_MAX_RMS_PX       = 2.0;
FINAL_MIN_OBS              = 20;
FINAL_MAX_POINT_RMS_PX     = 2.0;
PROGRESS_PRINT_EVERY       = 100; % batches


assert(END_TIME_S - START_TIME_S > WARM_START_DURATION_S, ...
    'Select an interval longer than the warm-start window.');
assert(exist('lsqnonlin', 'file') == 2, 'Optimization Toolbox is required.');
assert(exist('rangesearch', 'file') == 2, 'Statistics and Machine Learning Toolbox is required.');
tic_total = tic;
OUTPUT_DIRECTORY = tempname(options.output_root);
mkdir(OUTPUT_DIRECTORY);
copyfile([mfilename('fullpath') '.m'], fullfile(OUTPUT_DIRECTORY, 'source_snapshot.m'));
fprintf('Reconstruction output: %s\n', OUTPUT_DIRECTORY);
calibration_path = options.calibration_xml;
[FOCAL_LENGTH_PX, PRINCIPAL_POINT_PX, DISTORTION_K1, DISTORTION_K2] = ...
    read_fisheye_calibration_xml(calibration_path);
fprintf('Calibration: f=[%.6f %.6f], principal=[%.6f %.6f], k=[%.8f %.8f]\n', ...
    FOCAL_LENGTH_PX, PRINCIPAL_POINT_PX, DISTORTION_K1, DISTORTION_K2);
start_time_s = START_TIME_S;
end_time_s = END_TIME_S;
slice_duration_s = SLICE_DURATION_S;
adjustment_settings = struct('focal', FOCAL_LENGTH_PX, 'principal', PRINCIPAL_POINT_PX, ...
    'sigma', PIXEL_NOISE_STD_PX, 'eps', TANGENT_RESIDUAL_WEIGHT, 'cauchy', CAUCHY_SCALE_PX, ...
    'lam_th', ROTATION_ACCEL_WEIGHT, 'lam_T', TRANSLATION_ACCEL_WEIGHT, ...
    'pull', KNOT_VALUE_PULL_FRACTION, 'gauge', GAUGE_WEIGHT, 'centroid', AXIS_CENTROID_WEIGHT, ...
    'min_depth', MIN_LANDMARK_DEPTH, 'damping0', LM_INITIAL_DAMPING, 'free_V', FREE_MEAN_VELOCITY, ...
    'fd_check', JACOBIAN_FD_CHECK);

%% 1. Load events and convert distorted pixels to ideal pinhole pixels
% Preserve the original arithmetic: subtract epoch timestamps in double,
% then DIVIDE by 1e6. Multiplication by 1e-6 can round differently at cells.
[event_t, event_x, event_y, event_p, data_identity] = ...
    load_event_interval(options.dataset_path, start_time_s, end_time_s, IMAGE_SIZE_PX);
xy_undistorted = undistort_equidistant([event_x event_y], ...
    FOCAL_LENGTH_PX, PRINCIPAL_POINT_PX, DISTORTION_K1, DISTORTION_K2);
event_x = xy_undistorted(:, 1);
event_y = xy_undistorted(:, 2);
assert(all(isfinite(xy_undistorted), 'all'), 'Calibration produced non-finite coordinates.');
clear xy_undistorted

%% 2. Fit event surfaces using every selected event
% Each local plane in (x,y,t/time_scale) supplies an image-normal direction
% and normal speed. Polarity groups and both offset grids are fitted separately.
% No cache is loaded, so another recording/calibration cannot be reused silently.
[event_accept, event_flow] = estimate_normal_flow(event_t, event_x, event_y, event_p, ...
    CELL_SIZE_PX, CELL_DURATION_S, TIME_SCALE_S, MIN_EVENTS_PER_CELL, ...
    MIN_WARPED_PIXEL_SUPPORT, MAX_PLANARITY_RATIO, MAX_NORMAL_SPEED_PX_S, ...
    MIN_TIME_NORMAL_COMPONENT, MIN_IN_SURFACE_EXTENT, SPLIT_POLARITIES, USE_TWO_OFFSET_GRIDS);
fprintf('%d events; %d accepted (%.1f%%); %.1f s elapsed\n', ...
    numel(event_t), nnz(event_accept), 100*mean(event_accept), toc(tic_total));
if options.save_surface_checkpoint
    save(fullfile(OUTPUT_DIRECTORY, 'surface_checkpoint.mat'), ...
        'event_t', 'event_x', 'event_y', 'event_p', 'event_accept', 'event_flow', '-v7.3');
end
%% 3. Build image tracks, initialize the motion, triangulate the seed map
[trajectory, landmarks, observations, initialization] = initialize_reconstruction(event_t, event_x, event_y, event_flow, event_accept, ...
    start_time_s, end_time_s, slice_duration_s, WARM_START_DURATION_S, KNOT_SPACING_S, ...
    WARM_TRACK_GATE_PX, WARM_TRACK_MAX_MISS, TRACK_MIN_LENGTH, TRACK_MIN_EVENTS, ...
    TRACK_SEED_CELL_PX, TRACK_POSITION_GAIN, TRACK_VELOCITY_GAIN, MIN_OBS_PER_WARM_TRACK, ...
    MIN_TRACK_MOTION_PX, HEMISPHERE_DIRECTIONS, CANDIDATE_BASE_AXIS, WARM_RATE_SEEDS_DEG_S, ...
    WARM_CAUCHY_PX, WARM_MAX_FUNCTION_EVALS, WARM_MAX_VELOCITY_PER_S, WARM_MAX_CENTRE_OFFSET, ...
    RATE_PROFILE_DEG_S, FREE_MEAN_VELOCITY, ...
    FOCAL_LENGTH_PX, PRINCIPAL_POINT_PX, TANGENT_RESIDUAL_WEIGHT, MIN_LANDMARK_DEPTH);
save(fullfile(OUTPUT_DIRECTORY, 'initialization.mat'), ...
    'trajectory', 'landmarks', 'observations', 'initialization');

% Jointly refine the seed structure and the free mean-motion parameters.
% With FREE_MEAN_VELOCITY=false, only 5 of the 8 mean parameters are free.
[trajectory, landmarks] = refine_motion_and_structure(trajectory, landmarks, observations, select_free_parameters(trajectory, true, [], [], FREE_MEAN_VELOCITY), ...
    (1:size(landmarks, 1))', WARM_ADJUST_ITERATIONS, adjustment_settings);
adjustment_settings.fd_check = false;
fprintf('after joint warm-start adjust: omega %.3f deg/s, axis [%.3f %.3f %.3f], V [%.3f %.3f %.3f] permille/s  (%.0f s)\n', ...
    rad2deg(trajectory.omega), trajectory.a, 1000 * trajectory.V, toc(tic_total));

%% 4. Grow the map and refine motion over successive reconstruction slices
N0 = size(landmarks, 1);
% Map fields retain the original schema for cross-checking old artifacts:
% traj=trajectory, X=all landmarks, O=original-ID observations,
% nobs=observation counts, nrm=latest image normals, cand=2D candidates.
map = struct();
map.traj = trajectory;
map.X = landmarks;
map.O = observations;
map.nobs = accumarray(observations(:, 2), 1, [N0 1]);
map.created = zeros(N0, 1);
map.alive = true(N0, 1);
map.cand = struct('x', {}, 'y', {}, 'vx', {}, 'vy', {}, 'f', {}, 'hist', {}, 'miss', {});
map.ratio = [];
map.nrm = zeros(N0, 2);
for i = 1:N0
    rows_i = find(observations(:, 2) == i);
    map.nrm(i, :) = observations(rows_i(end), 5:6);
end
map.knots_free = false;

association_settings = struct('gate_n', GATE_NORMAL_PX, 'gate_t', GATE_TANGENT_PX, 'cov_gate', COVARIANCE_GATE, ...
    'local_win', LOCAL_WINDOW_S, 'min_mature', MIN_MATURE_CLAIMS, 'knot_iters', KNOT_CORRECTION_ITERATIONS, ...
    'cand_gate', CANDIDATE_GATE_PX, 'cand_max_miss', CANDIDATE_MAX_MISS, 'cand_min_samples', CANDIDATE_MIN_SAMPLES, ...
    'cand_min_turn', deg2rad(CANDIDATE_MIN_TURN_DEG), 'cand_min_depth', CANDIDATE_MIN_DEPTH, ...
    'cand_max_rms', CANDIDATE_MAX_RMS_PX, 'seed_cell', TRACK_SEED_CELL_PX, 'min_events', TRACK_MIN_EVENTS, ...
    'dt', slice_duration_s, 'focal', FOCAL_LENGTH_PX, 'principal', PRINCIPAL_POINT_PX, 'eps', TANGENT_RESIDUAL_WEIGHT, ...
    'image_size', IMAGE_SIZE_PX, 'free_V', FREE_MEAN_VELOCITY);

edges = start_time_s : slice_duration_s : end_time_s + 1e-9;
first_progressive_slice = numel(initialization.edges); % first batch after the warm-start window
accepted_index = find(event_accept);
accepted_t = event_t(accepted_index);
% Columns: [time, rate_deg_s, map_count, explained_fraction, matched_count, new_count].
run_log = zeros(numel(edges) - first_progressive_slice, 6);
tic_loop = tic;
for f = first_progressive_slice : numel(edges) - 1                       % f is the historical zero-based batch label; edges uses f+1
    tc = edges(f + 1);
    map.knots_free = tc >= start_time_s + WARM_START_DURATION_S + KNOTS_FREE_AFTER_S;
    % Centred half-open slice [tc-dt/2, tc+dt/2). The final slice only
    % contains events before end_time_s, because loading already clipped them.
    lo = find(accepted_t >= tc - slice_duration_s/2, 1);
    hi = find(accepted_t < tc + slice_duration_s/2, 1, 'last');
    if isempty(lo) || isempty(hi) || hi < lo
        s = zeros(0, 1);
    else
        s = accepted_index(lo:hi);
    end
    [map, info] = process_reconstruction_slice(f, tc, event_t(s), event_x(s), event_y(s), event_flow(s, :), map, edges, association_settings, adjustment_settings);
    if mod(f, LOCAL_ADJUST_EVERY) == 0 && map.knots_free       % every 1 s: knots of the last 3 s + the points seen in them
        in_win = map.O(:, 1) > tc - LOCAL_WINDOW_S;
        pts = unique(map.O(in_win, 2));
        % Use ALL observations of points selected by the recent window;
        % older observations anchor their structure while active knots adjust.
        rows = in_win | ismember(map.O(:, 2), pts);
        [map.traj, map.X] = refine_motion_and_structure(map.traj, map.X, map.O(rows, :), ...
            select_free_parameters(map.traj, false, tc, tc - LOCAL_WINDOW_S, FREE_MEAN_VELOCITY), pts, LOCAL_ADJUST_ITERATIONS, adjustment_settings);
    end
    if mod(f, GLOBAL_ADJUST_EVERY) == 0 || any(f - first_progressive_slice == EARLY_GLOBAL_BATCHES)    % every 10 s (and early on): everything
        pts = find(map.alive & map.nobs >= MIN_NOBS_FOR_GLOBAL);
        rows = ismember(map.O(:, 2), pts);
        if map.knots_free
            knots_upto = tc;
        else
            knots_upto = [];
        end
        [map.traj, map.X] = refine_motion_and_structure(map.traj, map.X, map.O(rows, :), ...
            select_free_parameters(map.traj, true, knots_upto, [], FREE_MEAN_VELOCITY), pts, GLOBAL_ADJUST_ITERATIONS, adjustment_settings);
    end
    rate_now = trajectory_rate_deg_s(map.traj, tc);
    run_log(f - first_progressive_slice + 1, :) = [tc, rate_now, nnz(map.alive), mean(info.used), nnz(info.found), info.n_new];
    if mod(f, PROGRESS_PRINT_EVERY) == 0
        recent = map.ratio(max(1, end - 99):end);
        fprintf('t = %.1f s: map %d, found %d, explained %.0f %%, rate %.2f deg/s (omega %.3f), rows %d, model/event velocity %.2f  (%.0f s)\n', ...
            tc, nnz(map.alive), nnz(info.found), 100 * mean(info.used), rate_now, rad2deg(map.traj.omega), ...
            size(map.O, 1), median(recent), toc(tic_loop));
    end
end
save(fullfile(OUTPUT_DIRECTORY, 'pre_final_refinement.mat'), 'map', 'run_log', '-v7.3');

%% 5. Global refinement, point filtering, then a second refinement
% Release the configured motion parameters and well-observed points.
% Filter using normal reprojection RMS, then rerun the same objective on survivors.
trajectory = map.traj;
final_observations = map.O;
keep = find(map.nobs >= FINAL_MIN_OBS);
final_observations = final_observations(ismember(final_observations(:, 2), keep), :);
cols = select_free_parameters(trajectory, true, end_time_s, [], FREE_MEAN_VELOCITY);
[trajectory, landmarks] = refine_motion_and_structure(trajectory, map.X, final_observations, cols, keep, FINAL_ADJUST_ITERATIONS(1), adjustment_settings);
dn = edge_normal_residuals(trajectory, landmarks, final_observations, FOCAL_LENGTH_PX, PRINCIPAL_POINT_PX);
point_rms = sqrt(accumarray(final_observations(:, 2), dn.^2, [size(landmarks, 1) 1]) ./ max(accumarray(final_observations(:, 2), 1, [size(landmarks, 1) 1]), 1));
keep = keep(point_rms(keep) < FINAL_MAX_POINT_RMS_PX);
final_observations = final_observations(ismember(final_observations(:, 2), keep), :);
[trajectory, landmarks] = refine_motion_and_structure(trajectory, landmarks, final_observations, cols, keep, FINAL_ADJUST_ITERATIONS(2), adjustment_settings);
dn = edge_normal_residuals(trajectory, landmarks, final_observations, FOCAL_LENGTH_PX, PRINCIPAL_POINT_PX);
assert(~isempty(keep), 'Final filtering removed all landmarks.');
first_seen = accumarray(final_observations(:, 2), final_observations(:, 1), [size(landmarks, 1) 1], @min, inf);
last_seen  = accumarray(final_observations(:, 2), final_observations(:, 1), [size(landmarks, 1) 1], @max, -inf);
revisit = (last_seen(keep) - first_seen(keep)) > 0.8 * 2*pi / abs(trajectory.omega);
filtered_landmarks = landmarks(keep, :);

%% 6. Package the refined model, apply scale, and export the trajectory
% Geometry optimization above uses model units. Multiplying BOTH landmarks
% and translations by the same scale leaves their image projections unchanged.
% Original landmark IDs can have gaps after filtering. Keep the old IDs for
% comparison, and also create observation rows that index the filtered cloud.
result = struct();
result.traj = trajectory;
result.X = filtered_landmarks;
result.O = final_observations; % original map IDs in column 2
result.ids = keep;
result.edges = edges;
result.log = run_log;
result.warm = initialization;
result.nobs = map.nobs(keep);
result.observations = final_observations;
[found, compact_ids] = ismember(final_observations(:, 2), keep);
assert(all(found), 'An observation refers to a filtered-out landmark.');
result.observations(:, 2) = compact_ids; % safe indices into result.X
result.normal_residual_px = dn;
result.normal_rms_px = sqrt(mean(dn.^2));
result.revisited = revisit;
result.options = options;
result.run_dir = OUTPUT_DIRECTORY;
result.parameters = struct('adjustment', adjustment_settings, ...
    'association', association_settings, 'slice_duration_s', slice_duration_s, ...
    'warm_duration_s', WARM_START_DURATION_S, 'knot_spacing_s', KNOT_SPACING_S, ...
    'final_iterations', FINAL_ADJUST_ITERATIONS);
result.camera = struct('focal', FOCAL_LENGTH_PX, 'principal', PRINCIPAL_POINT_PX, ...
    'distortion', [DISTORTION_K1 DISTORTION_K2], 'image_size', IMAGE_SIZE_PX, ...
    'pixel_origin', 0, 'model', 'equidistant fisheye -> ideal pinhole');
result.scale = calibrate_model_scale(result.X, result.ids, options);
result.X_m = result.scale.m_per_unit * result.X;
result.pose = sample_refined_trajectory(trajectory, edges(:), result.scale.m_per_unit);
result.final_pose = struct('time_s', edges(end), 'R', result.pose.R(:, :, end), ...
    'T_model', result.pose.T_model(end, :)', 'T_m', result.pose.T_m(end, :)');
result.elapsed_s = toc(tic_total);

provenance = struct('options', options, 'parameters', result.parameters, ...
    'camera', result.camera, 'matlab_version', version, 'toolboxes', ver, ...
    'source_sha256', hash_file(fullfile(OUTPUT_DIRECTORY, 'source_snapshot.m')), ...
    'calibration_sha256', hash_file(calibration_path), 'data_identity', data_identity, ...
    'selected_event_count', numel(event_t), 'accepted_event_count', nnz(event_accept));
save(fullfile(OUTPUT_DIRECTORY, 'provenance.mat'), 'provenance');
save(fullfile(OUTPUT_DIRECTORY, 'result.mat'), 'result', '-v7.3');
export_reconstruction(result);
if options.make_figures
    plot_reconstruction(result);
end
fprintf('Final reconstruction: %d landmarks, %d observations, normal RMS %.6f px.\n', ...
    size(result.X, 1), size(result.O, 1), result.normal_rms_px);
fprintf('Mean spin %.6f deg/s; axis [%.6f %.6f %.6f].\n', ...
    rad2deg(trajectory.omega), trajectory.a);
fprintf('Scale %.6f m/model-unit (%s).\n', result.scale.m_per_unit, result.scale.method);
fprintf('Saved: %s\n', OUTPUT_DIRECTORY);
end

%% Local functions: calibration, event surfaces, image tracks, geometry,
%  trajectory, initialization, and joint/progressive reconstruction.

function [focal, principal, k1, k2] = read_fisheye_calibration_xml(path)
% Read the OpenCV XML matrix in its row-major serialized order. The verified
% model uses k1 and k2 only; reject nonzero higher coefficients explicitly.
% Missing calibration must fail, rather than silently use placeholder values.
text = fileread(path);
camera_token = regexp(text, '<camera_matrix.*?<data>(.*?)</data>', 'tokens', 'once');
distortion_token = regexp(text, '<distortion_coefficients.*?<data>(.*?)</data>', 'tokens', 'once');
assert(~isempty(camera_token) && ~isempty(distortion_token), ...
    'Expected OpenCV camera_matrix and distortion_coefficients nodes.');
camera_matrix = sscanf(camera_token{1}, '%f');
distortion    = sscanf(distortion_token{1}, '%f');
assert(numel(camera_matrix) == 9 && numel(distortion) >= 1 && ...
    all(isfinite([camera_matrix; distortion])), 'Invalid calibration values.');
assert(camera_matrix(1) > 0 && camera_matrix(5) > 0, 'Focal lengths must be positive.');
assert(numel(distortion) <= 2 || all(distortion(3:end) == 0), ...
    'This reference model uses two fisheye coefficients; higher coefficients must be zero.');
focal     = [camera_matrix(1) camera_matrix(5)];
principal = [camera_matrix(3) camera_matrix(6)];
k1 = distortion(1);
if numel(distortion) >= 2
    k2 = distortion(2);
else
    k2 = 0;
end
end

% ------------------------------------------------------------------------
function undistorted = undistort_equidistant(pixels, focal, principal, k1, k2)
% Let r_d be the normalized distorted radius. Solve
%   r_d = theta * (1 + k1*theta^2 + k2*theta^4),
% then use r = tan(theta) for the ideal pinhole radius. Eight Newton steps
% and the central-pixel threshold match the original implementation.
% Equidistant fisheye -> ideal pinhole pixels, using Newton iterations.
xd = (pixels(:,1) - principal(1)) / focal(1);
yd = (pixels(:,2) - principal(2)) / focal(2);
theta_d = hypot(xd, yd);
theta = theta_d;
for iter = 1:8
    t2 = theta.^2;
    f_val = theta .* (1 + k1*t2 + k2*t2.^2) - theta_d;
    f_der = 1 + 3*k1*t2 + 5*k2*t2.^2;
    theta = theta - f_val ./ f_der;
end
scale = ones(size(theta_d));
nz = theta_d > 1e-9;
scale(nz) = tan(theta(nz)) ./ theta_d(nz);
undistorted = [focal(1) * xd .* scale + principal(1), ...
               focal(2) * yd .* scale + principal(2)];
end

% ------------------------------------------------------------------------
function u = unit_rows(v)
u = v ./ max(vecnorm(v, 2, 2), 1e-12);
end

% ------------------------------------------------------------------------
function [accept, flow] = estimate_normal_flow(event_time, event_x, event_y, polarity, cell_size_px, cell_duration_s, time_scale_s, min_events, ...
    min_support, planarity_max, speed_max, min_nt, min_extent, split_polarities, two_grids)
% Both grids have an absolute recording-time origin. Grid B is shifted by
% half a cell in x, y and time. Each event selects the valid plane with lower
% smallest/middle eigenvalue ratio, then passes density/speed/support gates.
% A normal-flow vector describes only the motion perpendicular to an image
% edge. It is not full optical flow or a 3D surface-normal measurement.
% Per event: accept mask and normal-flow vector [px/s]. One eigen-problem
% per spatiotemporal cell; two half-cell-shifted grids, the better
% (more planar) fit wins per event; polarities fitted separately.
event_count = numel(event_time);
assert(event_count > 0, 'No events available for surface fitting.');
accept = false(event_count, 1);
flow = zeros(event_count, 2);
if split_polarities
    groups = {polarity > 0, polarity <= 0};
else
    groups = {true(event_count, 1)};
end
if two_grids
    offsets = [0 0 0; cell_size_px/2 cell_size_px/2 cell_duration_s/2];
else
    offsets = [0 0 0];
end
for polarity_index = 1:numel(groups)
    event_indices = find(groups{polarity_index});
    if isempty(event_indices)
        continue;
    end
    best = [];
    for grid_index = 1:size(offsets, 1)
        cell_fit = fit_flow_cells(event_time(event_indices), event_x(event_indices), event_y(event_indices), cell_size_px, cell_duration_s, time_scale_s, min_events, offsets(grid_index, :), min_nt, min_extent);
        if isempty(best)
            best = cell_fit;
            continue;
        end
        better = (cell_fit.planarity < best.planarity & cell_fit.ok) | ~best.ok;
        best.ok(better) = cell_fit.ok(better);
        best.vel(better, :) = cell_fit.vel(better, :);
        best.planarity(better) = cell_fit.planarity(better);
        best.support(better) = cell_fit.support(better);
    end
    speed = hypot(best.vel(:, 1), best.vel(:, 2));
    accept(event_indices) = best.ok & best.planarity < planarity_max & best.support >= min_support & speed < speed_max;
    flow(event_indices, :) = best.vel;
end
end

function fit = fit_flow_cells(event_time, event_x, event_y, cell_size_px, cell_duration_s, time_scale_s, min_events, offset, min_nt, min_extent)
% Fit a plane n_x*x + n_y*y + n_tau*(t/time_scale) = constant by PCA.
% Its smallest-eigenvalue eigenvector is the plane normal. For n_tau != 0:
%   grad(t) = -time_scale * [n_x,n_y] / n_tau      [seconds/pixel]
%   v_normal = grad(t) / ||grad(t)||^2           [pixels/second].
% The middle eigenvalue rejects near-point/near-line event clusters. The
% smallest/middle ratio measures departure from a plane.
% The original integer cell-key packing is retained; it assumes this sensor's
% bounded pixel coordinates. Support counts events landing on the SAME rounded
% pixel after warping, not the number of distinct occupied pixels.
cell_x = floor((event_x + offset(1)) / cell_size_px);
cell_y = floor((event_y + offset(2)) / cell_size_px);
cell_time = floor((event_time + offset(3)) / cell_duration_s);
key = (cell_time - min(cell_time)) * 1e8 + (cell_y + 10) * 1e4 + cell_x + 10;
[~, ~, cell_id] = unique(key);
cell_count = max(cell_id);
scaled_time = event_time / time_scale_s;
events_per_cell = accumarray(cell_id, 1, [cell_count 1]);
sum_per_cell = @(w) accumarray(cell_id, w, [cell_count 1]);
safe_count = max(events_per_cell, 1);
mx = sum_per_cell(event_x) ./ safe_count;
my = sum_per_cell(event_y) ./ safe_count;
mt = sum_per_cell(scaled_time) ./ safe_count;
dx = event_x - mx(cell_id);
dy = event_y - my(cell_id);
dtt = scaled_time - mt(cell_id);
cxx = sum_per_cell(dx.*dx) ./ safe_count;
cyy = sum_per_cell(dy.*dy) ./ safe_count;
ctt = sum_per_cell(dtt.*dtt) ./ safe_count;
cxy = sum_per_cell(dx.*dy) ./ safe_count;
cxt = sum_per_cell(dx.*dtt) ./ safe_count;
cyt = sum_per_cell(dy.*dtt) ./ safe_count;
plane_normal = repmat([0 0 1], cell_count, 1);
middle_eigenvalue = zeros(cell_count, 1);
smallest_eigenvalue = ones(cell_count, 1);
for c = find(events_per_cell >= min_events)'
    % For this symmetric real covariance, MATLAB returns ascending eigenvalues.
    covariance = [cxx(c) cxy(c) cxt(c); cxy(c) cyy(c) cyt(c); cxt(c) cyt(c) ctt(c)];
    [V, D] = eig((covariance + covariance') / 2); % ascending eigenvalues
    d = diag(D);
    plane_normal(c, :) = V(:, 1)';
    smallest_eigenvalue(c) = d(1);
    middle_eigenvalue(c) = d(2);
end
planarity = smallest_eigenvalue ./ max(middle_eigenvalue, 1e-12);
ok = (events_per_cell >= min_events) & (abs(plane_normal(:, 3)) > min_nt) & (middle_eigenvalue > min_extent);
temporal_normal = plane_normal(:, 3);
temporal_normal(abs(temporal_normal) <= 1e-9) = 1e-9;
time_gradient = -plane_normal(:, 1:2) * time_scale_s ./ temporal_normal; % s/px
gradient_norm_squared = sum(time_gradient.^2, 2);
cell_velocity = time_gradient ./ max(gradient_norm_squared, 1e-12); % pixels/second
event_velocity = cell_velocity(cell_id, :);
cell_mean_time = mt(cell_id) * time_scale_s;
warped_x = round(event_x - event_velocity(:, 1) .* (event_time - cell_mean_time));
warped_y = round(event_y - event_velocity(:, 2) .* (event_time - cell_mean_time));
support_key = cell_id * 1e7 + (warped_y + 1000) * 3000 + (warped_x + 1000);
[~, ~, support_id] = unique(support_key);
support_count = accumarray(support_id, 1);
fit.ok = ok(cell_id);
fit.vel = event_velocity;
fit.planarity = planarity(cell_id);
fit.support = support_count(support_id);
end

% ========================================================================
%                     IMAGE TRACKS USED TO INITIALIZE STRUCTURE
% ========================================================================
function tracks = build_image_tracks(event_time, event_x, event_y, flow, slice_dt, gate, seed_cell, position_gain, velocity_gain, max_miss, min_len, min_events)
% These are temporary 2D image tracks for initialization, not the removed
% frozen-map pose tracker. Warp each event to its slice reference time using
% its normal flow, predict track positions, then greedily claim nearby events.
% Position and velocity receive constant-gain innovations. Unclaimed events
% seed tracks; long enough histories become triangulation observations.
% The first track grid starts at the first accepted event, as in main_gold.
% RETAINED CHOICE: on an entirely empty slice, expired tracks are discarded
% directly rather than transferred to retired_tracks.
% Per-slice gated nearest-neighbour assignment with a constant-gain state
% update; each sample records the mean normal-flow direction (edge normal).
% Returns a cell array of (n x 5) histories (t, x, y, nx, ny), n >= min_len.
[event_time, order] = sort(event_time);
event_x = event_x(order);
event_y = event_y(order);
flow = flow(order, :);
edges = event_time(1) : slice_dt : event_time(end) + slice_dt;
bounds = [find_sorted(event_time, edges), numel(event_time) + 1];
active_tracks = struct('x', {}, 'y', {}, 'vx', {}, 'vy', {}, 't', {}, 'hist', {}, 'miss', {});
retired_tracks = active_tracks;
for k = 1:numel(edges) - 1
    lo = bounds(k);
    hi = bounds(k + 1) - 1;
    reference_time = edges(k) + slice_dt / 2;
    if hi < lo
        for i = 1:numel(active_tracks)
            active_tracks(i).miss = active_tracks(i).miss + 1;
        end
        active_tracks = active_tracks([active_tracks.miss] <= max_miss);
        continue
    end
    slice_x = event_x(lo:hi);
    slice_y = event_y(lo:hi);
    slice_flow = flow(lo:hi, :);
    slice_time = event_time(lo:hi);
    warped_x = slice_x - slice_flow(:, 1) .* (slice_time - reference_time);
    warped_y = slice_y - slice_flow(:, 2) .* (slice_time - reference_time);
    claimed = false(numel(slice_x), 1);
    if ~isempty(active_tracks)
        prediction_interval = reference_time - [active_tracks.t]';
        predicted_x = [active_tracks.x]' + [active_tracks.vx]' .* prediction_interval;
        predicted_y = [active_tracks.y]' + [active_tracks.vy]' .* prediction_interval;
        neighbors = rangesearch([warped_x warped_y], [predicted_x predicted_y], gate);
        for i = 1:numel(active_tracks)
            nearby_events = neighbors{i};
            nearby_events = nearby_events(~claimed(nearby_events));
            if numel(nearby_events) >= min_events
                claimed(nearby_events) = true;
                measured_x = mean(warped_x(nearby_events));
                measured_y = mean(warped_y(nearby_events));
                active_tracks(i).vx = active_tracks(i).vx + velocity_gain * (measured_x - predicted_x(i)) / prediction_interval(i);
                active_tracks(i).vy = active_tracks(i).vy + velocity_gain * (measured_y - predicted_y(i)) / prediction_interval(i);
                active_tracks(i).x = predicted_x(i) + position_gain * (measured_x - predicted_x(i));
                active_tracks(i).y = predicted_y(i) + position_gain * (measured_y - predicted_y(i));
                active_tracks(i).t = reference_time;
                mean_normal = mean(slice_flow(nearby_events, :), 1);
                mean_normal = mean_normal / max(norm(mean_normal), 1e-9);
                active_tracks(i).hist(end + 1, :) = [reference_time, active_tracks(i).x, active_tracks(i).y, mean_normal];
                active_tracks(i).miss = 0;
            else
                active_tracks(i).miss = active_tracks(i).miss + 1;
            end
        end
        retire = [active_tracks.miss] > max_miss;
        retired_tracks = [retired_tracks, active_tracks(retire)];
        active_tracks = active_tracks(~retire); %#ok<AGROW>
    end
    unclaimed = find(~claimed);
    if ~isempty(unclaimed)
        key = floor(warped_y(unclaimed) / seed_cell) * 10000 + floor(warped_x(unclaimed) / seed_cell);
        [~, ~, seed_id] = unique(key);
        seed_count = accumarray(seed_id, 1);
        for c = find(seed_count >= min_events)'
            m = unclaimed(seed_id == c);
            mean_normal = mean(slice_flow(m, :), 1);
            mean_normal = mean_normal / max(norm(mean_normal), 1e-9);
            active_tracks(end + 1) = struct('x', mean(warped_x(m)), 'y', mean(warped_y(m)), 'vx', mean(slice_flow(m, 1)), 'vy', mean(slice_flow(m, 2)), ...
                't', reference_time, 'hist', [reference_time, mean(warped_x(m)), mean(warped_y(m)), mean_normal], 'miss', 0); %#ok<AGROW>
        end
    end
end
retired_tracks = [retired_tracks, active_tracks];
lengths = arrayfun(@(tr) size(tr.hist, 1), retired_tracks);
tracks = {retired_tracks(lengths >= min_len).hist};
end

function idx = find_sorted(t, edges)
% first index with t >= edge, for every edge (t sorted) -- np.searchsorted
idx = zeros(1, numel(edges));
for k = 1:numel(edges)
    i = find(t >= edges(k), 1);
    if isempty(i)
        idx(k) = numel(t) + 1;
    else
        idx(k) = i;
    end
end
end

function [edges, obs] = assemble_track_observations(tracks, t_start, t_end, slice_dt, min_cover, min_motion)
% Turn variable-length histories into obs(frame,track,component), whose four
% components are [u,v,n_u,n_v]. Missing observations are NaN. Track samples are
% rounded to the fixed frame grid; this timestamp assignment is inherited.
% Reject short coverage and negligible pixel motion before triangulation.
% Tracks -> obs(F, N, 4) with (u, v, nx, ny) or NaN, on the slice edges.
edges = t_start : slice_dt : t_end + 1e-9;
F = numel(edges);
cols = {};
for k = 1:numel(tracks)
    tr = tracks{k};
    m = tr(:, 1) >= t_start - 1e-6 & tr(:, 1) <= t_end + 1e-6;
    if nnz(m) < min_cover * F
        continue;
    end
    if max(std(tr(m, 2:3), 0, 1)) < min_motion
        continue;
    end
    f = round((tr(m, 1) - t_start) / slice_dt) + 1;
    col = nan(F, 4);
    col(f, :) = tr(m, 2:5);
    cols{end + 1} = col; %#ok<AGROW>
end
if isempty(cols)
    obs = zeros(F, 0, 4);
    return;
end
obs = permute(cat(3, cols{:}), [1 3 2]);
end

% ========================================================================
%                          GEOMETRY AND TRIANGULATION
% ========================================================================
function R = rodrigues_entries(axis_unit, theta)
% Rodrigues' formula: R(theta) = cos(theta) I + sin(theta)[a]_x
%                                + (1-cos(theta)) a*a'.
% Store each entry as a vector to project all observation poses together;
% this avoids a loop that constructs thousands of individual 3-by-3 matrices.
% Entries of R = cos I + sin [a]_x + (1 - cos) a a', one array per entry.
a1 = axis_unit(1);
a2 = axis_unit(2);
a3 = axis_unit(3);
c = cos(theta);
s = sin(theta);
v = 1 - c;
R.r11 = c + v*a1*a1;
R.r12 = v*a1*a2 - s*a3;
R.r13 = v*a1*a3 + s*a2;
R.r21 = v*a2*a1 + s*a3;
R.r22 = c + v*a2*a2;
R.r23 = v*a2*a3 - s*a1;
R.r31 = v*a3*a1 - s*a2;
R.r32 = v*a3*a2 + s*a1;
R.r33 = c + v*a3*a3;
end

function Rs = select_entries(R, idx)
Rs = structfun(@(e) e(idx), R, 'UniformOutput', false);
end

function Y = apply_pose(R, T, landmarks)
% Y = R X + T per row (R entry arrays of length M, T (M x 3), X (M x 3))
Y = [R.r11.*landmarks(:,1) + R.r12.*landmarks(:,2) + R.r13.*landmarks(:,3) + T(:,1), ...
     R.r21.*landmarks(:,1) + R.r22.*landmarks(:,2) + R.r23.*landmarks(:,3) + T(:,2), ...
     R.r31.*landmarks(:,1) + R.r32.*landmarks(:,2) + R.r33.*landmarks(:,3) + T(:,3)];
end

function [pixel, Y] = project_points(R, T, landmarks, focal, principal)
% Perspective projection: u=fx*Xc/Zc+cx, v=fy*Yc/Zc+cy.
% The denominator floor avoids division by zero. Positive-depth acceptance
% is handled separately in initialization, promotion and residual evaluation.
Y = apply_pose(R, T, landmarks);
z = max(Y(:, 3), 1e-6);
pixel = focal .* Y(:, 1:2) ./ z + principal;
end

function [landmarks, covariance_proxy] = triangulate_points(R, T, landmark_id, observed_pixels, image_normal, point_count, tangent_weight, focal, principal)
% For normalized pixel m=(u-c)/f, rearrange perspective projection into
%   (m_x*r3-r1) X = T_x-m_x*T_z,
%   (m_y*r3-r2) X = T_y-m_y*T_z.
% Combine these two equations along the image normal and its perpendicular.
% The tangential ROW is multiplied by 0.15, so its squared information weight
% is 0.0225. Accumulate one 3-by-3 least-squares system per landmark.
% RETAINED APPROXIMATION: image normals are applied directly to normalized
% coordinate rows without an fx/fy correction. The original focal lengths
% are close, but this is not exact for an arbitrarily anisotropic camera.
% The ridge 1e-9 prevents a singular solve. The covariance output is a
% residual-scaled inverse normal matrix: a promotion heuristic, not calibrated
% uncertainty in metres. No new independent speed residual is introduced.
normalized_pixels = (observed_pixels - principal) ./ focal;
A1 = [normalized_pixels(:,1).*R.r31 - R.r11, normalized_pixels(:,1).*R.r32 - R.r12, normalized_pixels(:,1).*R.r33 - R.r13];
A2 = [normalized_pixels(:,2).*R.r31 - R.r21, normalized_pixels(:,2).*R.r32 - R.r22, normalized_pixels(:,2).*R.r33 - R.r23];
b1 = T(:,1) - normalized_pixels(:,1).*T(:,3);
b2 = T(:,2) - normalized_pixels(:,2).*T(:,3);
normal_matrices = zeros(point_count, 3, 3);
normal_rhs = zeros(point_count, 3);
rows = cell(2, 1);
rhs = cell(2, 1);
directions = {image_normal, [-image_normal(:,2) image_normal(:,1)]};
weights = [1 tangent_weight];
for pass = 1:2
    d = directions{pass};
    w = weights(pass);
    r = w * (d(:,1) .* A1 + d(:,2) .* A2);
    s = w * (d(:,1) .* b1 + d(:,2) .* b2);
    rows{pass} = r;
    rhs{pass} = s;
    for a = 1:3
        normal_rhs(:, a) = normal_rhs(:, a) + accumarray(landmark_id, r(:, a) .* s, [point_count 1]);
        for b = 1:3
            normal_matrices(:, a, b) = normal_matrices(:, a, b) + accumarray(landmark_id, r(:, a) .* r(:, b), [point_count 1]);
        end
    end
end
landmarks = zeros(point_count, 3);
for i = 1:point_count
    landmarks(i, :) = ((squeeze(normal_matrices(i, :, :)) + 1e-9 * eye(3)) \ normal_rhs(i, :)')';
end
if nargout > 1
    residual = [sum(rows{1} .* landmarks(landmark_id, :), 2) - rhs{1}; sum(rows{2} .* landmarks(landmark_id, :), 2) - rhs{2}];
    residual_variance = (residual' * residual) / max(numel(residual) - 3 * point_count, 1);
    covariance_proxy = zeros(point_count, 3, 3);
    for i = 1:point_count
        covariance_proxy(i, :, :) = residual_variance * inv(squeeze(normal_matrices(i, :, :)) + 1e-9 * eye(3));
    end
end
end

% ========================================================================
%                    FIXED-AXIS MOTION WITH CUBIC SPLINE CORRECTIONS
% ========================================================================
function trajectory = create_trajectory(t0, t1, h)
% The object-to-camera model is
%   theta(t) = omega*(t-t0) + sum_j B_j(t)*k_j,
%   T(t) = [c_x,c_y,1] + (t-t0)*V + sum_j B_j(t)*m_j.
% a: 3x1 fixed unit rotation axis; omega: mean angular rate [rad/s].
% c: 1x2 initial lateral position; V: 1x3 mean velocity [model units/s].
% k: Kx1 angular correction knots [rad]; m: Kx3 translation correction knots.
% t0: recording-relative reference time; h: knot spacing [s]; K: knot count.
% Initial depth 1 fixes monocular scale. Axis-centroid regularization chooses
% part of the origin gauge; it does not identify the physical centre of mass.
% Parameter order: [axis_tangent_1, axis_tangent_2, omega, cx, cy, Vx,Vy,Vz,
%                   k_1...k_K, mx_1,my_1,mz_1,...,mx_K,my_K,mz_K].
trajectory.t0 = t0;
trajectory.h = h;
trajectory.n_seg = ceil((t1 - t0) / h) + 2;
trajectory.K = trajectory.n_seg + 3;
trajectory.knot_t = t0 + h * ((0:trajectory.K - 1)' - 1);
trajectory.a = [0; -1; 0];
trajectory.omega = 0.1;
trajectory.c = [0 0];
trajectory.V = [0 0 0];
trajectory.k = zeros(trajectory.K, 1);
trajectory.m = zeros(trajectory.K, 3);
end

function [idx, val] = spline_basis(trajectory, t)
% Uniform cubic B-splines have only four nonzero weights per observation.
% For fractional segment coordinate s, those weights are
% [(1-s)^3, 3s^3-6s^2+4, -3s^3+3s^2+3s+1, s^3] / 6.
% idx stores the four supporting knot indices. The padded ends and limited
% extrapolation reproduce the reference boundary convention.
% idx (M x 4) control indices (1-based) and val (M x 4) weights; the last
% segment is extrapolated beyond the ends.
u = (t(:) - trajectory.t0) / trajectory.h;
j = min(max(floor(u), 0), trajectory.n_seg - 1);
s = min(max(u - j, -0.5), 1.5);
val = [(1 - s).^3, 3*s.^3 - 6*s.^2 + 4, -3*s.^3 + 3*s.^2 + 3*s + 1, s.^3] / 6;
idx = j + (1:4);
end

function out = spline_eval(trajectory, t, coef)
[idx, val] = spline_basis(trajectory, t);
out = zeros(numel(t), size(coef, 2));
for q = 1:4
    out = out + val(:, q) .* coef(idx(:, q), :);
end
end

function j = spline_active(trajectory, ta, tb)
[ia, ~] = spline_basis(trajectory, ta);
[ib, ~] = spline_basis(trajectory, tb);
j = (ia(1, 1) : ib(1, 4))';
end

function theta = trajectory_angle(trajectory, t)
theta = trajectory.omega * (t(:) - trajectory.t0) + spline_eval(trajectory, t, trajectory.k);
end

function T = trajectory_translation(trajectory, t)
T = [trajectory.c 1] + (t(:) - trajectory.t0) * trajectory.V + spline_eval(trajectory, t, trajectory.m);
end

function [R, T] = trajectory_pose(trajectory, t)
R = rodrigues_entries(trajectory.a, trajectory_angle(trajectory, t));
T = trajectory_translation(trajectory, t);
end

function rate = trajectory_rate_deg_s(trajectory, t)
d = 0.05;
rate = rad2deg(trajectory_angle(trajectory, t(:) + d) - trajectory_angle(trajectory, t(:) - d)) / (2 * d);
end

function [t1, t2] = axis_tangent(a)
if abs(a(1)) < 0.9
    t1 = cross(a(:), [1; 0; 0]);
else
    t1 = cross(a(:), [0; 1; 0]);
end
t1 = t1 / norm(t1);
t2 = cross(a(:), t1);
end

function trajectory = increment_trajectory(trajectory, p)
% Perturb the axis in its two-dimensional tangent plane, then normalize.
% Add the remaining increments in the parameter order documented above.
% This is an update of fixed-axis trajectory parameters, not a free SE(3) pose.
[t1, t2] = axis_tangent(trajectory.a);
a = trajectory.a(:) + p(1) * t1 + p(2) * t2;
trajectory.a = a / norm(a);
trajectory.omega = trajectory.omega + p(3);
trajectory.c = trajectory.c + p(4:5)';
trajectory.V = trajectory.V + p(6:8)';
K = trajectory.K;
trajectory.k = trajectory.k + p(9:8 + K);
trajectory.m = trajectory.m + reshape(p(9 + K:end), 3, [])';
end

function cols = select_free_parameters(trajectory, mean_free, knots_upto, knots_from, free_V)
% Return parameter indices that a refinement call is allowed to change.
% A local call freezes mean motion and releases only active spline knots.
% A global call releases mean motion plus the selected knots. free_V=false
% keeps the mean velocity at zero while allowing translation spline motion.
% Column indices (1-based) of the 8 mean parameters and/or the knots whose
% support lies in [knots_from, knots_upto].
if mean_free
    if free_V
        cols = 1:8;
    else
        cols = 1:5;
    end
else
    cols = [];
end
if ~isempty(knots_upto)
    if isempty(knots_from)
        knots_from = trajectory.t0;
    end
    j = spline_active(trajectory, knots_from, knots_upto);
    cols = [cols, (8 + j)', reshape((8 + trajectory.K + 3 * (j - 1) + (1:3))', 1, [])];
end
cols = cols(:);
end

% ========================================================================
%              JOINT MOTION AND STRUCTURE REFINEMENT
% ========================================================================
function [trajectory, landmarks, info] = refine_motion_and_structure(trajectory, landmarks, observations, free_parameters, free_landmarks, max_iterations, settings)
% Optimize selected motion parameters and selected landmark coordinates.
% All other parameters/points still contribute residuals but remain fixed.
% For observation error d = observed_pixel - projected_pixel:
%   r_n = n' d / sigma; r_t = epsilon * n_perpendicular' d / sigma.
% Each scalar data residual uses Cauchy cost c^2*log(1+r^2/c^2).
% Priors stay quadratic: angular/translation second differences, weak knot
% pull toward zero, initial-pose gauges, and axial landmark centroid.
% These are soft numerical regularizers, not an exact rigid-body dynamics law.
%
% The LM step solves (J' W J + damping*D) delta = -J' W r. A step is accepted
% only when the full robust objective decreases; otherwise increase damping.
% Sparse triplets below assemble only requested parameter columns. Rotation
% axis columns use finite differences; other columns are analytic.
%
% REFERENCE APPROXIMATIONS, deliberately retained for reproducibility:
% 1. Invalid-depth image residuals are clamped to 10, but analytic image
%    Jacobian rows are not zeroed there. Avoid interpreting that Jacobian as
%    exact in the invalid-depth region.
% 2. Axial-centroid landmark coefficients are built at the axis on entry to
%    this refinement call and remain fixed during its iterations. The axis
%    derivative itself is included through the finite-difference columns.
% The full real-data parity test checks the resulting estimator, including
% these choices. They are explicit review points for a future mathematical fix.
info = struct('cost', nan, 'rms', nan);
free_landmarks = free_landmarks(:);
observation_times = observations(:, 1);
landmark_ids = observations(:, 2);
measured_pixels = observations(:, 3:4);
image_normals = unit_rows(observations(:, 5:6));
observation_count = size(observations, 1);
knot_count = trajectory.K;
knot_spacing_s = trajectory.h;
trajectory_parameter_count = 8 + 4 * knot_count;
landmark_count = size(landmarks, 1);
free_motion_count = numel(free_parameters);
free_parameter_count = free_motion_count + 3 * numel(free_landmarks);
if free_parameter_count == 0 || observation_count == 0
    return;
end
weighted_normals = image_normals / settings.sigma; % [n' ; eps e'] / sigma
weighted_tangents = settings.eps * [-image_normals(:, 2), image_normals(:, 1)] / settings.sigma;
radians_to_degrees = 180 / pi;
model_to_permille = 1000;
parameter_to_column = zeros(trajectory_parameter_count + 3 * landmark_count, 1);
parameter_to_column(free_parameters) = 1:free_motion_count;
for d = 1:3
    parameter_to_column(trajectory_parameter_count + 3 * (free_landmarks - 1) + d) = free_motion_count + 3 * (0:numel(free_landmarks) - 1)' + d;
end
[initial_basis_indices, initial_basis_values] = spline_basis(trajectory, trajectory.t0);
[basis_indices, basis_values] = spline_basis(trajectory, observation_times);
tau = observation_times - trajectory.t0;
fx = settings.focal(1);
fy = settings.focal(2);
image_residual_count = 2 * observation_count;
residual_count = image_residual_count + (knot_count - 2) + 3 * (knot_count - 2) + knot_count + 3 * knot_count + 1 + 3 + 1;
% Build prior rows in the same order as evaluate_residual; capture the entry axis.
reference_axis = trajectory.a;
[J_prior_rows, J_prior_cols, J_prior_vals] = assemble_prior_jacobian();

cauchy_scale_squared = (settings.cauchy / settings.sigma)^2;
r = evaluate_residual(trajectory, landmarks);
cost = robust_cost(r);
damping = settings.damping0;
if settings.fd_check
    check_jacobian(trajectory, landmarks, r);
end
for iteration = 1:max_iterations
    J = assemble_jacobian(trajectory, landmarks, r);
    sqrt_weights = ones(residual_count, 1);
    sqrt_weights(1:image_residual_count) = 1 ./ sqrt(1 + r(1:image_residual_count).^2 / cauchy_scale_squared);
    weighted_jacobian = spdiags(sqrt_weights, 0, residual_count, residual_count) * J;
    normal_matrix = weighted_jacobian' * weighted_jacobian;
    gradient = weighted_jacobian' * (r .* sqrt_weights);
    damping_diagonal = spdiags(max(diag(normal_matrix), 1e-9), 0, free_parameter_count, free_parameter_count);
    accepted = false;
    for attempt = 1:6
        d = -(normal_matrix + damping * damping_diagonal) \ gradient;
        [trial_trajectory, trial_landmarks] = apply_parameter_step(trajectory, landmarks, d);
        trial_residual = evaluate_residual(trial_trajectory, trial_landmarks);
        trial_cost = robust_cost(trial_residual);
        if trial_cost < cost
            trajectory = trial_trajectory;
            landmarks = trial_landmarks;
            r = trial_residual;
            cost = trial_cost;
            damping = damping / 3;
            accepted = true;
            break
        end
        damping = damping * 4;
    end
    if ~accepted
        break;
    end
    if norm(d) < 1e-8
        break;
    end
end
info.cost = cost;
info.rms = sqrt(mean((r(1:2:image_residual_count) * settings.sigma).^2));

    function r = evaluate_residual(tr, Xp)
        th = tr.omega * tau + sum(basis_values .* tr.k(basis_indices), 2);
        T = [tr.c 1] + tau * tr.V + [sum(basis_values .* reshape(tr.m(basis_indices, 1), observation_count, 4), 2), ...
                                     sum(basis_values .* reshape(tr.m(basis_indices, 2), observation_count, 4), 2), ...
                                     sum(basis_values .* reshape(tr.m(basis_indices, 3), observation_count, 4), 2)];
        R = rodrigues_entries(tr.a, th);
        [pr, Y] = project_points(R, T, Xp(landmark_ids, :), settings.focal, settings.principal);
        dd = measured_pixels - pr;
        rn = sum(weighted_normals .* dd, 2);
        rt = sum(weighted_tangents .* dd, 2);
        bad = Y(:, 3) < settings.min_depth;
        rn(bad) = 10;
        rt(bad) = 10;
        r_img = reshape([rn rt]', [], 1);
        k = tr.k;
        m = tr.m;
        % Residual blocks, in order: image observations; angular curvature;
        % translation curvature; angular knot pull; translation knot pull;
        % zero initial angular correction; zero initial translation correction;
        % landmark centroid projected onto the rotation axis.
        r = [r_img;
             settings.lam_th * radians_to_degrees * (k(3:end) - 2 * k(2:end-1) + k(1:end-2)) / knot_spacing_s^2;
             settings.lam_T * model_to_permille * reshape((m(3:end, :) - 2 * m(2:end-1, :) + m(1:end-2, :))', [], 1) / knot_spacing_s^2;
             settings.pull * settings.lam_th * radians_to_degrees * k;
             settings.pull * settings.lam_T * model_to_permille * reshape(m', [], 1);
             settings.gauge * (initial_basis_values * k(initial_basis_indices'));
             settings.gauge * (initial_basis_values * m(initial_basis_indices', :))';
             settings.centroid * (tr.a(:)' * mean(Xp, 1)')];
    end

    function c = robust_cost(rr)
        c = sum(cauchy_scale_squared * log1p(rr(1:image_residual_count).^2 / cauchy_scale_squared)) + sum(rr(image_residual_count+1:end).^2);
    end

    function [tr, Xp] = apply_parameter_step(tr, Xp, d)
        dp = zeros(trajectory_parameter_count, 1);
        dp(free_parameters) = d(1:free_motion_count);
        tr = increment_trajectory(tr, dp);
        Xp(free_landmarks, :) = Xp(free_landmarks, :) + reshape(d(free_motion_count+1:end), 3, [])';
    end

    function [rows, cols, vals] = assemble_prior_jacobian()
        rows = {};
        cols = {};
        vals = {};
        row = image_residual_count;
        j = (1:knot_count-2)';
        stencil = [1 -2 1];
        for stencil_index = 1:3
            rows{end+1} = row + j;
            cols{end+1} = 8 + j + stencil_index - 1;
            vals{end+1} = repmat(stencil(stencil_index) * settings.lam_th * radians_to_degrees / knot_spacing_s^2, knot_count-2, 1); %#ok<AGROW>
            for coordinate = 1:3
                rows{end+1} = row + (knot_count-2) + 3*(j-1) + coordinate;
                cols{end+1} = 8 + knot_count + 3*(j + stencil_index - 2) + coordinate; %#ok<AGROW>
                vals{end+1} = repmat(stencil(stencil_index) * settings.lam_T * model_to_permille / knot_spacing_s^2, knot_count-2, 1); %#ok<AGROW>
            end
        end
        row = row + 4 * (knot_count - 2);
        j = (1:knot_count)';
        rows{end+1} = row + j;
        cols{end+1} = 8 + j;
        vals{end+1} = repmat(settings.pull * settings.lam_th * radians_to_degrees, knot_count, 1);
        for coordinate = 1:3
            rows{end+1} = row + knot_count + 3*(j-1) + coordinate;
            cols{end+1} = 8 + knot_count + 3*(j-1) + coordinate;
            vals{end+1} = repmat(settings.pull * settings.lam_T * model_to_permille, knot_count, 1); %#ok<AGROW>
        end
        row = row + 4 * knot_count;
        rows{end+1} = repmat(row + 1, 4, 1);
        cols{end+1} = 8 + initial_basis_indices';
        vals{end+1} = settings.gauge * initial_basis_values';
        for coordinate = 1:3
            rows{end+1} = repmat(row + 1 + coordinate, 4, 1);
            cols{end+1} = 8 + knot_count + 3*(initial_basis_indices' - 1) + coordinate;
            vals{end+1} = settings.gauge * initial_basis_values'; %#ok<AGROW>
        end
        row = row + 4;
        for coordinate = 1:3
            rows{end+1} = repmat(row + 1, landmark_count, 1);
            cols{end+1} = trajectory_parameter_count + 3*(0:landmark_count-1)' + coordinate; %#ok<AGROW>
            vals{end+1} = repmat(settings.centroid * reference_axis(coordinate) / landmark_count, landmark_count, 1); %#ok<AGROW>
        end
        rows = vertcat(rows{:});
        cols = vertcat(cols{:});
        vals = vertcat(vals{:});
    end

    function J = assemble_jacobian(tr, Xp, r0)
        th = tr.omega * tau + sum(basis_values .* tr.k(basis_indices), 2);
        T = [tr.c 1] + tau * tr.V + [sum(basis_values .* reshape(tr.m(basis_indices, 1), observation_count, 4), 2), ...
                                     sum(basis_values .* reshape(tr.m(basis_indices, 2), observation_count, 4), 2), ...
                                     sum(basis_values .* reshape(tr.m(basis_indices, 3), observation_count, 4), 2)];
        R = rodrigues_entries(tr.a, th);
        Y = apply_pose(R, T, Xp(landmark_ids, :));
        z = max(Y(:, 3), 1e-6);
        % BA = B * dproj (2 x 3 per observation), already / sigma and eps
        BA1 = [weighted_normals(:,1)*fx./z, weighted_normals(:,2)*fy./z, -(weighted_normals(:,1)*fx.*Y(:,1) + weighted_normals(:,2)*fy.*Y(:,2))./z.^2];
        BA2 = [weighted_tangents(:,1)*fx./z, weighted_tangents(:,2)*fy./z, -(weighted_tangents(:,1)*fx.*Y(:,1) + weighted_tangents(:,2)*fy.*Y(:,2))./z.^2];
        Pp = Y - T; % R X
        a = tr.a(:);
        Pxa = [Pp(:,2)*a(3) - Pp(:,3)*a(2), Pp(:,3)*a(1) - Pp(:,1)*a(3), Pp(:,1)*a(2) - Pp(:,2)*a(1)];
        Ja1 = sum(BA1 .* Pxa, 2);
        Ja2 = sum(BA2 .* Pxa, 2); % d r / d theta (left perturbation a dtheta)
        JX1 = -[BA1(:,1).*R.r11 + BA1(:,2).*R.r21 + BA1(:,3).*R.r31, ...
                BA1(:,1).*R.r12 + BA1(:,2).*R.r22 + BA1(:,3).*R.r32, ...
                BA1(:,1).*R.r13 + BA1(:,2).*R.r23 + BA1(:,3).*R.r33];
        JX2 = -[BA2(:,1).*R.r11 + BA2(:,2).*R.r21 + BA2(:,3).*R.r31, ...
                BA2(:,1).*R.r12 + BA2(:,2).*R.r22 + BA2(:,3).*R.r32, ...
                BA2(:,1).*R.r13 + BA2(:,2).*R.r23 + BA2(:,3).*R.r33];
        rid = (1:observation_count)';
        row_blocks = {};
        column_blocks = {};
        value_blocks = {};
        for q = 1:2
            if q == 1
                rows_q = 2*rid - 1;
                Ja = Ja1;
                JT = -BA1;
                JX = JX1;
            else
                rows_q = 2*rid;
                Ja = Ja2;
                JT = -BA2;
                JX = JX2;
            end
            row_blocks{end+1} = rows_q;
            column_blocks{end+1} = repmat(3, observation_count, 1);
            value_blocks{end+1} = Ja .* tau; % omega
            for d = 1:3
                row_blocks{end+1} = rows_q;
                column_blocks{end+1} = repmat(5 + d, observation_count, 1);
                value_blocks{end+1} = JT(:, d) .* tau; % V
                row_blocks{end+1} = rows_q;
                column_blocks{end+1} = trajectory_parameter_count + 3*(landmark_ids - 1) + d;
                value_blocks{end+1} = JX(:, d); % X_i
                if d < 3
                    row_blocks{end+1} = rows_q;
                    column_blocks{end+1} = repmat(3 + d, observation_count, 1);
                    value_blocks{end+1} = JT(:, d);
                end    % cx, cy
            end
            for b = 1:4
                row_blocks{end+1} = rows_q;
                column_blocks{end+1} = 8 + basis_indices(:, b);
                value_blocks{end+1} = Ja .* basis_values(:, b); % k_j
                for d = 1:3
                    row_blocks{end+1} = rows_q;
                    column_blocks{end+1} = 8 + knot_count + 3*(basis_indices(:, b) - 1) + d;
                    value_blocks{end+1} = JT(:, d) .* basis_values(:, b); % m_j
                end
            end
        end
        for cidx = 1:2                                   % axis: two finite-difference columns
            dp = zeros(trajectory_parameter_count, 1);
            dp(cidx) = 1e-6;
            col = (evaluate_residual(increment_trajectory(tr, dp), Xp) - r0) / 1e-6;
            nz = find(col);
            row_blocks{end+1} = nz;
            column_blocks{end+1} = repmat(cidx, numel(nz), 1);
            value_blocks{end+1} = col(nz);
        end
        rows = [vertcat(row_blocks{:}); J_prior_rows];
        cols = [vertcat(column_blocks{:}); J_prior_cols];
        vals = [vertcat(value_blocks{:}); J_prior_vals];
        keep = parameter_to_column(cols) > 0;
        J = sparse(rows(keep), parameter_to_column(cols(keep)), vals(keep), residual_count, free_parameter_count);
    end

    function check_jacobian(tr, Xp, r0)
        J_an = full(assemble_jacobian(tr, Xp, r0));
        max_cols = min(free_parameter_count, free_motion_count + 30);
        hh = 1e-6;
        J_num = zeros(residual_count, max_cols);
        for q = 1:max_cols
            d = zeros(free_parameter_count, 1);
            d(q) = hh;
            [trp, Xpp] = apply_parameter_step(tr, Xp, d);
            [trm, Xpm] = apply_parameter_step(tr, Xp, -d);
            J_num(:, q) = (evaluate_residual(trp, Xpp) - evaluate_residual(trm, Xpm)) / (2 * hh);
        end
        fprintf('Jacobian finite-difference check (h = %.0e, %d of %d columns):\n', hh, max_cols, free_parameter_count);
        labels = {'axis (FD)', 'omega', 'c', 'V', 'k knots', 'm knots', 'points'};
        ranges = {1:2, 3, 4:5, 6:8, 8 + (1:knot_count), 8 + knot_count + (1:3*knot_count), trajectory_parameter_count + (1:3*landmark_count)};
        for b = 1:numel(labels)
            sel = find(ismember([free_parameters; trajectory_parameter_count + reshape((3*(free_landmarks-1) + (1:3))', [], 1)], ranges{b}));
            sel = sel(sel <= max_cols);
            if isempty(sel)
                continue;
            end
            err = max(abs(J_an(:, sel) - J_num(:, sel)), [], 'all');
            scale = max(abs(J_num(:, sel)), [], 'all');
            fprintf('  %-10s max |dJ| %.3e relative to max |J| %.3e -> %.3e\n', labels{b}, err, scale, err / max(scale, 1e-300));
        end
    end
end

function dn = edge_normal_residuals(trajectory, landmarks, observations, focal, principal)
[R, T] = trajectory_pose(trajectory, observations(:, 1));
pr = project_points(R, T, landmarks(observations(:, 2), :), focal, principal);
dn = sum((observations(:, 3:4) - pr) .* observations(:, 5:6), 2);
end

% ========================================================================
%                       MOTION INITIALIZATION BY AXIS AND RATE SEARCH
% ========================================================================
function dirs = hemisphere_directions(n, pole)
i = (0:n-1)' + 0.5;
z = 1 - i / n;
phi = pi * (1 + sqrt(5)) * i;
d = [sqrt(1 - z.^2) .* cos(phi), sqrt(1 - z.^2) .* sin(phi), z];
pole = pole(:) / norm(pole);
t1 = cross(pole, [1; 0; 0]);
t1 = t1 / norm(t1);
t2 = cross(pole, t1);
dirs = d(:, 1) * t1' + d(:, 2) * t2' + d(:, 3) * pole';
end

function [trajectory, landmarks, observations, initialization] = initialize_reconstruction(t, x, y, flow, acc, start_time_s, end_time_s, slice_duration_s, L, DK, ...
    gate, max_miss, min_len, min_events, seed_cell, Kx, Kv, min_obs, min_motion, ...
    n_dirs, base_axis, rate_seeds_deg, cauchy_px, max_evals, max_V, max_c, rates_profile, free_V, ...
    focal, principal, eps_w, min_depth)
% Initialization eliminates structure from the motion search: triangulate a
% fresh map at EVERY candidate motion, then score normal reprojection errors.
% Search 13 hemisphere directions and their negatives, starting each at five
% angular rates. Refine the best axis in its local tangent plane.
% The opposite-axis fit and rate profile are conditioning diagnostics only.
% (a,omega) and (-a,-omega) represent the same physical rotation: the basin
% margin is not a probability or a unique physical mirror disambiguation.
% Knots start at zero. Global/local refinements release them later.
% Constant angular rate and linear translation (all knots zero), eliminating structure over
% the first L seconds: axis by an n_dirs-direction sweep (both axis signs),
% rate from a seed grid, c from the track centroid at depth 1, V from its drift.
m = t < start_time_s + L + 0.05;
ia = find(m & acc);
tracks = build_image_tracks(t(ia), x(ia), y(ia), flow(ia, :), slice_duration_s, gate, seed_cell, Kx, Kv, max_miss, min_len, min_events);
[edges, obs] = assemble_track_observations(tracks, start_time_s, start_time_s + L, slice_duration_s, 0.0, min_motion);
obs = obs(:, sum(isfinite(obs(:, :, 1)), 1) >= min_obs, :);
N = size(obs, 2);
F = numel(edges);
assert(N >= 6, 'Too few warm-start tracks for reconstruction.');
[fi, ii] = find(isfinite(obs(:, :, 1)));
uv = [obs(sub2ind(size(obs), fi, ii, ones(size(fi)))), obs(sub2ind(size(obs), fi, ii, 2*ones(size(fi))))];
nn = unit_rows([obs(sub2ind(size(obs), fi, ii, 3*ones(size(fi)))), obs(sub2ind(size(obs), fi, ii, 4*ones(size(fi))))]);
tau = (edges - start_time_s)';
V_mask = double(free_V);

    function r = resid_data(a, w, q)                      % q = (cx, cy, Vx, Vy, Vz)
        R = rodrigues_entries(a, w * tau);
        T = [q(1) q(2) 1] + tau * (q(3:5) * V_mask);
        Rf = select_entries(R, fi);
        Tf = T(fi, :);
        Xq = triangulate_points(Rf, Tf, ii, uv, nn, N, eps_w, focal, principal);
        [pr, Y] = project_points(Rf, Tf, Xq(ii, :), focal, principal);
        r = sum((uv - pr) .* nn, 2);
        r(Y(:, 3) < min_depth) = 10;
    end
    function rr = cauchy_transform(r)                     % sum rr^2 = sum c^2 log(1 + r^2/c^2)
        rr = sign(r) .* cauchy_px .* sqrt(log1p((r / cauchy_px).^2));
    end
nll = @(a, w, q) sum(log1p((resid_data(a, w, q) / cauchy_px).^2));
opts = optimoptions('lsqnonlin', 'Display', 'off', 'MaxFunctionEvaluations', max_evals, ...
                    'FunctionTolerance', 1e-8, 'StepTolerance', 1e-8);

% centroid at depth 1 and its drift
cen = nan(F, 2);
for f = 1:F
    vis = isfinite(obs(f, :, 1));
    if any(vis)
        cen(f, :) = [mean(obs(f, vis, 1)), mean(obs(f, vis, 2))];
    end
end
cen = (cen - principal) ./ focal;
okc = isfinite(cen(:, 1));
c0 = cen(find(okc, 1), :);
px = polyfit(tau(okc), cen(okc, 1), 1);
py = polyfit(tau(okc), cen(okc, 2), 1);
V0 = [px(1) py(1) 0];

dirs = hemisphere_directions(n_dirs, base_axis);
dirs = [dirs; -dirs];
fits = struct('a', {}, 'w', {}, 'q', {}, 'seed', {}, 'cost', {});
for s = 1:numel(rate_seeds_deg)
    wh = deg2rad(rate_seeds_deg(s));
    for k = 1:size(dirs, 1)
        a = dirs(k, :)';
        p = lsqnonlin(@(p) cauchy_transform(resid_data(a, p(1), p(2:6))), [wh, c0, V0], ...
                      [-1, -max_c, -max_c, -max_V, -max_V, -max_V], [1, max_c, max_c, max_V, max_V, max_V], opts);
        fits(end+1) = struct('a', a, 'w', p(1), 'q', p(2:6), 'seed', wh, 'cost', nll(a, p(1), p(2:6))); %#ok<AGROW>
    end
end
    function g = refine(f0)                               % release the axis in its tangent plane
        a0 = f0.a;
        [t1, t2] = axis_tangent(a0);
        ax = @(p) (a0 + p(1) * t1 + p(2) * t2) / norm(a0 + p(1) * t1 + p(2) * t2);
        p = lsqnonlin(@(p) cauchy_transform(resid_data(ax(p), p(3), p(4:8))), [0 0 f0.w f0.q], ...
                      [-1, -1, -1, -max_c, -max_c, -max_V, -max_V, -max_V], [1, 1, 1, max_c, max_c, max_V, max_V, max_V], opts);
        g = struct('a', ax(p), 'w', p(3), 'q', p(4:8), 'seed', f0.seed, 'cost', nll(ax(p), p(3), p(4:8)));
    end
[~, ibest] = min([fits.cost]);
best = refine(fits(ibest));
opposite = fits(arrayfun(@(f) f.a' * best.a < 0, fits));
[~, imir] = min([opposite.cost]);
mirror = refine(opposite(imir));
margin = mirror.cost / best.cost - 1;
% rate profile along omega at the best axis (c, V refitted, structure re-triangulated): the valley
prof = nan(size(rates_profile));
for k = 1:numel(rates_profile)
    w = deg2rad(rates_profile(k));
    q = lsqnonlin(@(q) cauchy_transform(resid_data(best.a, w, q)), best.q, ...
                  [-max_c, -max_c, -max_V, -max_V, -max_V], [max_c, max_c, max_V, max_V, max_V], opts);
    prof(k) = nll(best.a, w, q);
end
inside = rates_profile(prof <= min(prof) + 2);
interval = (max(inside) - min(inside)) / 2 / abs(rad2deg(best.w));
fprintf('warm-start X = %.0f s: %d tracks, omega %.2f deg/s about [%.3f %.3f %.3f], V [%.4f %.4f %.4f], opposite-axis basin margin %.0f %%, rate interval (dNLL <= 2) +-%.0f %%\n', ...
    L, N, rad2deg(best.w), best.a, best.q(3:5) * V_mask, 100 * margin, 100 * interval);
trajectory = create_trajectory(start_time_s, end_time_s, DK);
trajectory.a = best.a(:);
trajectory.omega = best.w;
trajectory.c = best.q(1:2);
trajectory.V = best.q(3:5) * V_mask;
[R, T] = trajectory_pose(trajectory, edges);
landmarks = triangulate_points(select_entries(R, fi), T(fi, :), ii, uv, nn, N, eps_w, focal, principal);
observations = [edges(fi)', ii, uv, nn];
initialization = struct('fits', fits, 'best', best, 'mirror', mirror, 'rates', rates_profile, 'prof', prof, ...
           'edges', edges, 'margin', margin, 'interval', interval, 'n_tracks', N);
end

% ========================================================================
%                ONE RECONSTRUCTION SLICE AGAINST THE GROWING MAP
% ========================================================================
function [map, info] = process_reconstruction_slice(slice_index, reference_time, event_time, event_x, event_y, normal_flow, map, edges, settings, adjustment_settings)
% This step still changes geometry AND motion during reconstruction.
% 1. Project current landmarks and estimate their predicted image velocities.
% 2. Warp events to the slice centre; claim them by normal/tangent distance,
%    compatible image-normal orientation, and signed motion direction.
% 3. Use enough unambiguous claims to trigger a correction of active knots.
% 4. Add observations, extend unmatched-event candidates, and triangulate
%    candidates that have enough samples and angular baseline.
% 5. Keep new points only if depth, reprojection and covariance-proxy gates pass.
% map.nrm stores 2D image normals, not object-frame 3D normals.
% RETAINED CHOICES: ambiguity gates the correction count, but ALL current
% claims enter that correction; a mature candidate is retired after its
% triangulation attempt even if it fails promotion.
% Predict from the trajectory, explain events by the map (position + orientation +
% direction of motion), correct the active knots (twice), track the unexplained
% events in 2-D and triangulate them once the trajectory has turned enough.
trajectory = map.traj;
landmarks = map.X;
active_ids = find(map.alive);
warped_pixels = [event_x - normal_flow(:, 1) .* (event_time - reference_time), event_y - normal_flow(:, 2) .* (event_time - reference_time)];
flow_direction = unit_rows(normal_flow);
event_count = size(warped_pixels, 1);
    function [projected_pixels, Y, predicted_flow] = predict(tr)
        [Rf, Tf] = trajectory_pose(tr, reference_time);
        Rf = select_entries(Rf, ones(numel(active_ids), 1));
        [projected_pixels, Y] = project_points(Rf, repmat(Tf, numel(active_ids), 1), landmarks(active_ids, :), settings.focal, settings.principal);
        [Rp, Tp] = trajectory_pose(tr, reference_time + 0.05);
        [Rm, Tm] = trajectory_pose(tr, reference_time - 0.05);
        up = project_points(select_entries(Rp, ones(numel(active_ids), 1)), repmat(Tp, numel(active_ids), 1), landmarks(active_ids, :), settings.focal, settings.principal);
        um = project_points(select_entries(Rm, ones(numel(active_ids), 1)), repmat(Tm, numel(active_ids), 1), landmarks(active_ids, :), settings.focal, settings.principal);
        predicted_flow = (up - um) / 0.1;
    end
rows = zeros(0, 6);
used = false(event_count, 1);
projected_pixels = zeros(numel(active_ids), 2);
found = false(numel(active_ids), 1);
for it = 1:2
    [projected_pixels, ~, predicted_flow] = predict(trajectory);
    used = false(event_count, 1);
    rows = zeros(0, 6);
    mature = [];
    ratio = [];
    inside = projected_pixels(:, 1) > -20 & projected_pixels(:, 1) < settings.image_size(1) + 20 & projected_pixels(:, 2) > -20 & projected_pixels(:, 2) < settings.image_size(2) + 20;
    previous_normals = map.nrm(active_ids, :);
    ambiguous = false(numel(active_ids), 1);
    visible_ids = find(inside);
    if numel(visible_ids) > 1                                   % ambiguity: coinciding predicted edge lines
        pairs = rangesearch(projected_pixels(visible_ids, :), projected_pixels(visible_ids, :), settings.gate_t);
        for pk = 1:numel(visible_ids)
            k = visible_ids(pk);
            for l = visible_ids(pairs{pk}(pairs{pk} > pk))'
                dlt = projected_pixels(l, :) - projected_pixels(k, :);
                if abs(dlt * previous_normals(k, :)') < settings.gate_n && abs(previous_normals(k, :) * previous_normals(l, :)') > 0.5 && ...
                   (previous_normals(k, :) * predicted_flow(k, :)') * (previous_normals(k, :) * predicted_flow(l, :)') > 0
                    ambiguous(k) = true;
                    ambiguous(l) = true;
                end
            end
        end
    end
    if event_count > 0
        neighbors = rangesearch(warped_pixels, projected_pixels, settings.gate_t);
    else
        neighbors = repmat({zeros(1, 0)}, numel(active_ids), 1);
    end
    [~, order] = sort(map.nobs(active_ids), 'descend'); % well-observed points claim first
    for k = order'
        if ~inside(k)
            continue;
        end
        nearby_events = neighbors{k};
        nearby_events = nearby_events(~used(nearby_events));
        if numel(nearby_events) < 3
            continue;
        end
        pixel_error = warped_pixels(nearby_events, :) - projected_pixels(k, :);
        normal_error = sum(pixel_error .* flow_direction(nearby_events, :), 2);
        tangent_error = pixel_error(:, 1) .* flow_direction(nearby_events, 2) - pixel_error(:, 2) .* flow_direction(nearby_events, 1);
        ok = abs(normal_error) < settings.gate_n & abs(tangent_error) < settings.gate_t & (flow_direction(nearby_events, :) * predicted_flow(k, :)') > 0 & abs(flow_direction(nearby_events, :) * map.nrm(active_ids(k), :)') > 0.5;
        if nnz(ok) < 3
            continue;
        end
        claimed_ids = nearby_events(ok);
        used(claimed_ids) = true;
        mean_normal = mean(normal_flow(claimed_ids, :), 1);
        mean_normal = mean_normal / max(norm(mean_normal), 1e-12);
        map.nrm(active_ids(k), :) = mean_normal;
        rows(end+1, :) = [mean(event_time(claimed_ids)), active_ids(k), mean(event_x(claimed_ids)), mean(event_y(claimed_ids)), mean_normal]; %#ok<AGROW>
        mature(end+1) = ~ambiguous(k); %#ok<AGROW>
        if mature(end)
            ratio(end+1) = mean(flow_direction(claimed_ids, :) * predicted_flow(k, :)') / mean(vecnorm(normal_flow(claimed_ids, :), 2, 2));
        end  %#ok<AGROW>
    end
    found = ismember(active_ids, rows(:, 2));
    if ~isempty(ratio)
        map.ratio(end+1) = median(ratio);
    end
    if sum(mature) >= settings.min_mature && map.knots_free && it == 1      % correct the active knots with the last LOCAL_WIN s
        recent_observations = [map.O(map.O(:, 1) > reference_time - settings.local_win, :); rows];
        map.traj = refine_motion_and_structure(trajectory, landmarks, recent_observations, select_free_parameters(trajectory, false, reference_time, reference_time - settings.local_win, settings.free_V), [], settings.knot_iters, adjustment_settings);
        trajectory = map.traj;
    else
        break
    end
end
map.O = [map.O; rows];
for i = unique(rows(:, 2))'
    map.nobs(i) = map.nobs(i) + 1;
end
% new structure: 2-D candidate tracks on the unexplained events, triangulated once the trajectory has turned enough (03 s5)
unclaimed = find(~used);
candidate_claimed = false(numel(unclaimed), 1);
new_point_count = 0;
keep = struct('x', {}, 'y', {}, 'vx', {}, 'vy', {}, 'f', {}, 'hist', {}, 'miss', {});
if ~isempty(map.cand)
    prediction_interval = (slice_index - [map.cand.f]') * settings.dt;
    predicted_x = [map.cand.x]' + [map.cand.vx]' .* prediction_interval;
    predicted_y = [map.cand.y]' + [map.cand.vy]' .* prediction_interval;
    if ~isempty(unclaimed)
        candidate_neighbors = rangesearch(warped_pixels(unclaimed, :), [predicted_x predicted_y], settings.cand_gate);
    else
        candidate_neighbors = repmat({zeros(1, 0)}, numel(predicted_x), 1);
    end
    for candidate_index = 1:numel(map.cand)
        candidate = map.cand(candidate_index);
        nearby_events = candidate_neighbors{candidate_index};
        nearby_events = nearby_events(~candidate_claimed(nearby_events));
        if numel(nearby_events) >= 3
            candidate_claimed(nearby_events) = true;
            claimed_ids = unclaimed(nearby_events);
            measured_x = mean(warped_pixels(claimed_ids, 1));
            measured_y = mean(warped_pixels(claimed_ids, 2));
            candidate.vx = candidate.vx + 0.25 * (measured_x - predicted_x(candidate_index)) / prediction_interval(candidate_index);
            candidate.vy = candidate.vy + 0.25 * (measured_y - predicted_y(candidate_index)) / prediction_interval(candidate_index);
            candidate.x = predicted_x(candidate_index) + 0.6 * (measured_x - predicted_x(candidate_index));
            candidate.y = predicted_y(candidate_index) + 0.6 * (measured_y - predicted_y(candidate_index));
            candidate.f = slice_index;
            mean_normal = mean(normal_flow(claimed_ids, :), 1);
            mean_normal = mean_normal / max(norm(mean_normal), 1e-12);
            candidate.hist(end+1, :) = [slice_index, candidate.x, candidate.y, mean_normal];
            candidate.miss = 0;
        else
            candidate.miss = candidate.miss + 1;
        end
        if candidate.miss > settings.cand_max_miss
            continue;
        end
        history = candidate.hist;
        history_edge_indices = history(:, 1) + 1; % batch index -> edges index
        if size(history, 1) >= settings.cand_min_samples && ...
           abs(trajectory_angle(trajectory, edges(history_edge_indices(end))) - trajectory_angle(trajectory, edges(history_edge_indices(1)))) >= settings.cand_min_turn
            [Rs, Ts] = trajectory_pose(trajectory, edges(history_edge_indices));
            sample_count = size(history, 1);
            [new_point, point_covariance] = triangulate_points(Rs, Ts, ones(sample_count, 1), history(:, 2:3), history(:, 4:5), 1, settings.eps, settings.focal, settings.principal);
            [pr, Y] = project_points(Rs, Ts, repmat(new_point, sample_count, 1), settings.focal, settings.principal);
            normal_error = sum((history(:, 2:3) - pr) .* history(:, 4:5), 2);
            if min(Y(:, 3)) > settings.cand_min_depth && sqrt(mean(normal_error.^2)) < settings.cand_max_rms && ...
               sqrt(max(eig(squeeze(point_covariance(1, :, :))))) < settings.cov_gate                  % covariance gate
                i = size(map.X, 1) + 1;
                map.X(i, :) = new_point;
                map.O = [map.O; [edges(history_edge_indices)', repmat(i, sample_count, 1), history(:, 2:5)]];
                map.nobs(i) = sample_count;
                map.created(i) = slice_index;
                map.alive(i) = true;
                map.nrm(i, :) = history(end, 4:5);
                new_point_count = new_point_count + 1;
            end
            continue
        end
        keep(end+1) = candidate; %#ok<AGROW>
    end
end
remaining_events = unclaimed(~candidate_claimed);
if ~isempty(remaining_events)
    cell_xy = floor(warped_pixels(remaining_events, :) / settings.seed_cell);
    [~, ~, seed_id] = unique(cell_xy(:, 1) * 10000 + cell_xy(:, 2));
    seed_count = accumarray(seed_id, 1);
    for candidate = find(seed_count >= 3)'
        claimed_ids = remaining_events(seed_id == candidate);
        v = mean(normal_flow(claimed_ids, :), 1);
        keep(end+1) = struct('x', mean(warped_pixels(claimed_ids, 1)), 'y', mean(warped_pixels(claimed_ids, 2)), 'vx', v(1), 'vy', v(2), 'f', slice_index, ...
            'hist', [slice_index, mean(warped_pixels(claimed_ids, 1)), mean(warped_pixels(claimed_ids, 2)), v / max(norm(v), 1e-12)], 'miss', 0); %#ok<AGROW>
    end
end
map.cand = keep;
info = struct('uv', projected_pixels, 'found', found, 'used', used, 'e', warped_pixels, 'n_new', new_point_count);
end

% ========================================================================
%                         INPUT AND OUTPUT

%% Input, configuration, scaling, and output helpers
function options = default_options()
% Only experiment I/O and output choices are overridden here. Algorithm
% constants are grouped at the beginning of the main function for study.
root = fileparts(mfilename('fullpath'));
options = struct();
options.dataset_path = fullfile('/home/alexandercrain/Downloads/', ...
    'Dataset Release 1', 'ROT-NOM', 'recording_20251029_131131.hdf5');
options.calibration_xml = fullfile(root, ...
    'calibration_camera_DVXplorerM_DXUS0047-2026_07_27_11_26_49-fisheye.xml');
options.start_time_s = 60;
options.end_time_s = 185;
options.output_root = fullfile(root, 'output_reconstruction_gold_laptop');
options.make_figures = true;
options.save_surface_checkpoint = false; % large; useful for front-end comparisons
options.known_width_m = 1.27;
options.scale_endpoint_ids = []; % two original panel-tip IDs, if known
end

function options = resolve_options(user_options)
assert(isstruct(user_options) && isscalar(user_options), 'Options must be a scalar struct.');
options = default_options();
names = fieldnames(user_options);
for index = 1:numel(names)
    name = names{index};
    assert(isfield(options, name), 'Unknown option: %s', name);
    options.(name) = user_options.(name);
end
validateattributes(options.start_time_s, {'numeric'}, {'scalar', 'finite', 'nonnegative'});
validateattributes(options.end_time_s, {'numeric'}, {'scalar', 'finite', '>', options.start_time_s});
validateattributes(options.known_width_m, {'numeric'}, {'scalar', 'finite', 'positive'});
validateattributes(options.make_figures, {'logical'}, {'scalar'});
validateattributes(options.save_surface_checkpoint, {'logical'}, {'scalar'});
assert(isfile(options.dataset_path), 'Recording not found: %s', options.dataset_path);
assert(isfile(options.calibration_xml), 'Calibration not found: %s', options.calibration_xml);
if ~isfolder(options.output_root)
    mkdir(options.output_root);
end
end

function [time_s, x, y, polarity, identity] = load_event_interval(path, start_s, end_s, image_size)
% HDF5 stores event columns. Read vector shapes as columns, and retain the
% original file order, including events with equal timestamps.
raw_time = double(h5read(path, '/timestamp'));
raw_time = raw_time(:);
assert(~isempty(raw_time) && all(isfinite(raw_time)) && all(diff(raw_time) >= 0), ...
    'Event timestamps must be finite, nonempty and sorted.');
identity = struct('path', path, 'file', dir(path), 'event_count', numel(raw_time), ...
    'first_timestamp_us', raw_time(1), 'last_timestamp_us', raw_time(end), ...
    'selected_interval_s', [start_s end_s]);
all_time_s = (raw_time - raw_time(1)) / 1e6;
selected = all_time_s >= start_s & all_time_s < end_s;
assert(any(selected), 'No events in the requested time interval.');
assert(end_s <= all_time_s(end), 'Requested end exceeds the recording duration.');
x = double(h5read(path, '/x'));
x = x(:);
y = double(h5read(path, '/y'));
y = y(:);
polarity = double(h5read(path, '/polarity'));
polarity = polarity(:);
assert(numel(x) == numel(raw_time) && numel(y) == numel(raw_time) && ...
    numel(polarity) == numel(raw_time), 'Event columns must have equal lengths.');
time_s = all_time_s(selected);
x = x(selected);
y = y(selected);
polarity = polarity(selected);
assert(all(x >= 0 & x < image_size(1) & y >= 0 & y < image_size(2)), ...
    'Raw event coordinates must use the configured sensor size and zero origin.');
polarity(polarity <= 0) = -1;
end

function scale = calibrate_model_scale(points, original_ids, options)
% Scaling is a reporting step, never a change in the reconstructed shape.
% Known corresponding panel tips are preferable to a statistical cloud span.
scale = struct('known_width_m', options.known_width_m, ...
    'endpoint_ids', options.scale_endpoint_ids, 'provisional', false);
if isempty(options.scale_endpoint_ids)
    [~, ~, directions] = svd(points - mean(points, 1), 0);
    axis_vector = directions(:, 1);
    projected = sort(points * axis_vector);
    percentile_indices = 1 + (numel(projected) - 1) * [1 99] / 100;
    endpoints = interp1(1:numel(projected), projected, percentile_indices);
    span_model = endpoints(2) - endpoints(1);
    scale.method = 'provisional 1--99 percentile principal-axis span';
    scale.provisional = true;
    scale.axis = axis_vector;
    scale.percentiles = [1 99];
else
    requested = options.scale_endpoint_ids;
    assert(numel(requested) == 2 && requested(1) ~= requested(2), ...
        'Provide two distinct original panel-tip IDs.');
    [found, rows] = ismember(requested, original_ids);
    assert(all(found), 'A requested panel-tip ID is missing from the final cloud.');
    span_model = norm(points(rows(2), :) - points(rows(1), :));
    scale.method = 'specified panel-tip endpoints';
end
assert(isfinite(span_model) && span_model > 0, 'Cannot scale a zero or invalid cloud span.');
scale.span_model = span_model;
scale.m_per_unit = options.known_width_m / span_model;
end

function pose = sample_refined_trajectory(trajectory, time_s, metres_per_unit)
% Pose samples come from the FINAL optimized trajectory, not successive
% intermediate estimates. R(:,:,j) maps object coordinates into the camera.
[entries, translations] = trajectory_pose(trajectory, time_s);
count = numel(time_s);
rotation = zeros(3, 3, count);
for index = 1:count
    rotation(:, :, index) = [entries.r11(index) entries.r12(index) entries.r13(index); ...
                            entries.r21(index) entries.r22(index) entries.r23(index); ...
                            entries.r31(index) entries.r32(index) entries.r33(index)];
end
pose = struct('time_s', time_s, 'R', rotation, 'T_model', translations, ...
    'T_m', metres_per_unit * translations, ...
    'angle_rad', trajectory_angle(trajectory, time_s), ...
    'rate_deg_s', trajectory_rate_deg_s(trajectory, time_s), ...
    'convention', 'X_camera = R * X_object + T; column vectors');
end

function export_reconstruction(result)
folder = result.run_dir;
write_ply(fullfile(folder, 'cloud_model_units.ply'), result.X);
write_ply(fullfile(folder, 'cloud_m.ply'), result.X_m);
point_columns = [result.ids result.X result.X_m result.nobs];
point_names = {'original_id','x_model','y_model','z_model','x_m','y_m','z_m','observation_count'};
writetable(array2table(point_columns, 'VariableNames', point_names), fullfile(folder, 'landmarks.csv'));

pose = result.pose;
% MATLAB reshape stacks columns: R11,R21,R31,R12,... . Spell it out in CSV.
rotations = reshape(pose.R, 9, [])';
columns = [pose.time_s pose.T_model pose.T_m rotations pose.angle_rad pose.rate_deg_s];
names = {'time_s','tx_model','ty_model','tz_model','tx_m','ty_m','tz_m', ...
    'R11','R21','R31','R12','R22','R32','R13','R23','R33','angle_rad','rate_deg_s'};
writetable(array2table(columns, 'VariableNames', names), fullfile(folder, 'reconstruction_poses.csv'));

% Include both ID conventions so filtered points can be reprojected safely.
columns = [result.O(:,1:2) result.observations(:,2) result.O(:,3:6) result.normal_residual_px];
names = {'time_s','original_id','point_row','u_px','v_px','normal_u','normal_v','normal_residual_px'};
writetable(array2table(columns, 'VariableNames', names), fullfile(folder, 'observation_residuals.csv'));
end

function write_ply(path, points)
file = fopen(path, 'w');
assert(file > 0, 'Cannot open cloud output: %s', path);
cleanup = onCleanup(@() fclose(file));
fprintf(file, 'ply\nformat ascii 1.0\nelement vertex %d\n', size(points, 1));
fprintf(file, 'property double x\nproperty double y\nproperty double z\nend_header\n');
fprintf(file, '%.17g %.17g %.17g\n', points');
end

function plot_reconstruction(result)
% Figures are final diagnostics. There is no live reconstruction dashboard.
points = result.X_m;
figure_cloud = figure('Color', 'w', 'Name', 'Final reconstructed object');
scatter3(points(:,1), points(:,2), points(:,3), 14, result.nobs, 'filled');
axis equal;
grid on;
colorbar;
view(3);
xlabel('Object X [m]');
ylabel('Object Y [m]');
zlabel('Object Z [m]');
title(sprintf('%d landmarks; metric scale provisional = %d', ...
    size(points, 1), result.scale.provisional));
exportgraphics(figure_cloud, fullfile(result.run_dir, 'fig_cloud.png'), 'Resolution', 140);

figure_pose = figure('Color', 'w', 'Name', 'Final refined trajectory', 'Position', [50 50 1000 750]);
subplot(3,1,1);
plot(result.pose.time_s, result.pose.T_m);
grid on;
ylabel('Origin position [m]');
legend('Camera x','Camera y','Camera z');
title('Final refined object-to-camera pose (provisional scale)');
subplot(3,1,2);
plot(result.pose.time_s, rad2deg(result.pose.angle_rad));
grid on;
ylabel('Angle about fixed axis [deg]');
subplot(3,1,3);
plot(result.pose.time_s, result.pose.rate_deg_s);
grid on;
ylabel('Angular rate [deg/s]');
xlabel('Recording-relative time [s]');
exportgraphics(figure_pose, fullfile(result.run_dir, 'fig_pose.png'), 'Resolution', 140);

figure_fit = figure('Color','w','Name','Reconstruction diagnostics','Position',[50 50 1100 450]);
subplot(1,3,1);
histogram(result.normal_residual_px, -4:0.1:4);
grid on;
xlabel('Normal reprojection residual [px]');
ylabel('Observations');
title(sprintf('RMS %.3f px', result.normal_rms_px));
subplot(1,3,2);
plot(result.log(:,1), result.log(:,3), result.log(:,1), result.log(:,5));
grid on;
xlabel('Recording-relative time [s]');
legend('Map points','Associated points');
subplot(1,3,3);
plot(result.warm.rates, result.warm.prof - min(result.warm.prof));
grid on;
xlabel('Warm-start rate [deg/s]');
ylabel('Profile cost minus minimum');
exportgraphics(figure_fit, fullfile(result.run_dir, 'fig_diagnostics.png'), 'Resolution', 140);
end

function hash = hash_file(path)
file = fopen(path, 'rb');
assert(file > 0, 'Cannot read file for provenance: %s', path);
cleanup = onCleanup(@() fclose(file));
digest = java.security.MessageDigest.getInstance('SHA-256');
while ~feof(file)
    digest.update(fread(file, 1024*1024, '*uint8'));
end
hash = lower(reshape(dec2hex(typecast(digest.digest(), 'uint8'), 2)', 1, []));
end
