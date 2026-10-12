function cfg = config()
    %   This function initializes all user defined constants
    %   for the reconstruction pipeline. Only the scenario inputs and the
    %   few parameters that depend on the scene are set here -- every
    %   other constant is filled in by 'derived_parameters', which
    %   documents where each value comes from (see PARAMETERS.md).
    %
    %   INPUTS: NONE
    %
    %   OUTPUTS:
    %       CFG -> Struct, contains user parameters.

    % data: sets the import parameters
    %-----%
    cfg.data.hdf5_dir     = '/home/alexandercrain/esfm_work/hdf5/';   % verification recording (ROT-NOM)
    cfg.data.hdf5_file    = 'ROT-NOM.hdf5';
    cfg.data.start_time_s = 60.0;    % T0 [s]: first event time used
    cfg.data.end_time_s   = 185.0;   % T1 [s]: last event time used
    %-----%

    % camera: set the camera intrinsics (the image size is read from here too)
    cfg.camera.calibration_xml = ['calibration_camera_DVXplorerM_DXUS0047' ...
        '-2026_07_27_11_26_49-fisheye.xml'];

    MIN_EVENTS  = 3;    % FIXED: events that make a feature (claim, seed, warped support)
    GATE_PX     = 3.0;  % FIXED: how far an event may sit from a predicted edge [px]; 2 ok, 4 worse
    MAX_RMS_PX  = 2.0;  % FIXED: largest normal reprojection RMS a landmark may have [px]; 1.5-3 insensitive
    MIN_OBS     = 20;   % FIXED: samples that make a track trustworthy (warm tracks, final refinement)
    MAX_GAP_S   = 1.5;  % FIXED: time a 2D track may go unseen before it is dropped [s]
    LM_ITERS    = 10;   % FIXED: LM budget of every joint adjustment; x0.5 and x2 insensitive

    % output: where results go, and the metric scale
    cfg.output.dir                = fullfile(pwd, 'output_current');
    cfg.output.known_width_m      = 1.27;  % panel span used for scaling [m]
    cfg.output.scale_endpoint_ids = [];    % two original landmark IDs spanning the known width, if known

    % data
    cfg.data.slice_s = 0.1;  % FIXED: batch length [s]; 0.05 insensitive (latency/compute choice)

    % surface: the plane fit is done in a normalized space where one pixel
    % and sigma_s seconds have the same length. Scaling sigma_s with the
    % temporal window keeps the cell's shape in that space constant, so the
    % shape thresholds below do not depend on the scene
    cfg.surface.cell_px             = 8;     % FIXED: spatial cell [px]; 6 and 10 mildly worse
    cfg.surface.stride_px           = 4;     % EXPERIMENT: spacing of overlapping cells [px]; use cell_px for the original grids
    cfg.surface.cell_s              = 0.8;   % temporal window of a surface cell [s]; scale as 1/(image speed)
    cfg.surface.sigma_s             = cfg.surface.cell_s * 0.0375;  % DERIVED: 0.03 s at cell_s = 0.8 s
    cfg.surface.min_events_per_cell = 15;    % FIXED: minimum for a stable 3x3 covariance; 10 mildly worse
    cfg.surface.min_time_normal     = 0.05;  % FIXED: rejects static/flickering edges (planes containing the time axis); REQUIRED
    cfg.surface.max_planarity_ratio = 0.45;  % FIXED: thin-sheet test in normalized space; 0.35 and 0.55 both worse
    cfg.surface.min_warped_support  = MIN_EVENTS;  % FIXED: REQUIRED (removing it degrades the cloud)
    cfg.surface.split_polarities    = true;  % FIXED: structural choice
    cfg.surface.two_offset_grids    = true;  % use a second half-window temporal grid (original diagonal shift when stride_px = cell_px)

    %-----%
    % track: 2D Kalman tracker, shared by the seed tracks, the
    % initialisation tracks (track.*) and the progressive candidates
    % (prog.cand_*). Settings frozen after the ablation of 2026-10-09.
    cfg.track.gate_px       = GATE_PX;
    cfg.track.disc_px       = GATE_PX;      % events a track may claim: within this disc of the prediction
    cfg.track.seed_cell_px  = 2 * GATE_PX;  % DERIVED: seed cells span one gate diameter (6 px)
    cfg.track.min_events    = MIN_EVENTS;
    cfg.track.max_miss      = round(MAX_GAP_S / cfg.data.slice_s);  % DERIVED: slices in MAX_GAP_S
    cfg.track.min_length    = MIN_OBS;
    cfg.track.cos_edge      = cosd(20);     % FIXED: claimed events move within 20 deg of the track's normal (signed); 35 worse
    cfg.track.min_coherence = 0.7;          % FIXED: a seed cell needs one flow direction (mean resultant length)
    cfg.track.sigma_n       = 1.0;          % FIXED: centroid measurement noise [px]
    cfg.track.sigma_v_floor = 1.0;          % FIXED: normal-flow velocity measurement noise, floor [px/s]
    cfg.track.sigma_v_rel   = 0.3;          % FIXED: ... relative part
    cfg.track.q_acc         = 40;           % FIXED: process noise, image acceleration [px/s^2]
    cfg.track.seed_sigma_t  = 3.0;          % FIXED: along-edge position uncertainty of a seed [px]
    cfg.track.seed_sigma_v  = 3.0;          % FIXED: velocity uncertainty of a seed [px/s]
    cfg.track.dormant_s     = 3.0;          % FIXED: a lost track can be resumed for this long [s]
    cfg.track.dormant_gate_px = 8;          % FIXED: position gate for resuming a lost track [px]
    cfg.track.dormant_cos   = cosd(25);     % FIXED: normal agreement for resuming a lost track
    %-----%

    % adjust: robust bundle adjustment. Image residuals are in pixels, so
    % the prior weights below are "pixels of equivalent error per unit"
    cfg.adjust.tangent_weight     = 0.15;  % FIXED: along-edge/across-edge noise ratio; 0.10 and 0.25 mildly worse
    cfg.adjust.cauchy_px          = 4.0;   % FIXED: robust scale [px], also used by the warm fits; 2 insensitive
    cfg.adjust.min_depth          = 0.2;   % FIXED: depth limit [model units, range at t0 = 1]; never active here
    cfg.adjust.depth_weight       = 50;    % FIXED: hinge weight [px/unit]; x10 and /10 bit-identical (never active)
    cfg.adjust.lambda_rotation    = 250;   % FIXED: angular curvature weight [px per deg/s^2]; x3 and /3 insensitive
    cfg.adjust.lambda_translation = 1;   % Translation curvature [px per permille/s^2], validated with moving rendered events
    cfg.adjust.velocity_weight    = 3000;   % Total translation velocity [px/(range/s)]
    cfg.adjust.pull_fraction      = 0.1;   % FIXED: pull toward zero correction, relative to the curvature weights; /10 and x3 insensitive
    cfg.adjust.gauge_weight       = 5e3;   % FIXED: gauge (t0) constraint, just "large"; /10 lets the scale gauge drift
    cfg.adjust.centroid_weight    = 50;    % FIXED: gauge (centroid along axis), just "large"
    cfg.adjust.damping0           = 1e-3;  % FIXED: standard Levenberg-Marquardt constants
    cfg.adjust.damping_down       = 3;
    cfg.adjust.damping_up         = 4;
    cfg.adjust.max_attempts       = 6;
    cfg.adjust.step_tol           = 1e-8;
    %-----%
    % Convergence and solver (2026-10-11). The LM budgets are ceilings: a
    % call stops once the robust cost has decreased by less than cost_tol
    % (relative) on cost_tol_streak consecutive accepted steps. 'schur'
    % eliminates the landmarks in 3x3 blocks and solves the dense motion
    % system (no sparse matrices, same step to rounding); 'sparse' is the
    % original full sparse normal-equations solve, kept for A/B checks.
    cfg.adjust.cost_tol        = 1e-6;
    cfg.adjust.cost_tol_streak = 2;
    cfg.adjust.solver          = 'schur';
    %-----%

    %-----%
    % warm: the seed tracks that every re-association pass starts from,
    % and the adjuster settings those passes share
    cfg.warm.cauchy_px              = cfg.adjust.cauchy_px;
    cfg.warm.min_depth              = cfg.adjust.min_depth;
    cfg.warm.tangent_weight         = cfg.adjust.tangent_weight;
    cfg.warm.free_mean_velocity     = true;   % Fit baseline V in global/final solves; spline models departures from it
    cfg.warm.adjust_iterations      = LM_ITERS;
    cfg.warm.duration_s             = 6.0;    % seed-track window [s]; the first slices of every re-association pass

    cfg.traj.knot_spacing_s  = 1.0;           % spline knot spacing [s]; shortest time scale of spin-rate changes

    % init: the motion from 2D tracks over a long window (warm.init_tracks),
    % then re-association rounds over that window (prog.reassociate)
    cfg.init.window_s          = 48.0;        % initialisation window [s]; must cover >= 190 deg of rotation (6 s is ill-posed)
    cfg.init.chunk_s           = 10.0;        % tracks run in chunks of this length so none slides far along its edge
    cfg.init.min_track_length  = 8;           % samples a track needs to count
    cfg.init.rate_seeds_deg_s  = [2 4 6];     % starting rates, both signs are tried; selection by cost
    cfg.init.axis_guess        = [0 -1 0];    % starting axis (vertical in the camera frame); the adjuster frees it
    cfg.init.iterations        = 50;          % LM budget of each start
    cfg.init.reject_rounds     = 6;           % blind rejection rounds; converges in ~4
    cfg.init.reject_track_rms  = 0.8;         % a track is kept while its normal RMS is below this [px]
    cfg.init.reject_obs_px     = 1.5;         % an observation is kept while its residual is below this [px]
    cfg.init.reject_iterations = 30;          % LM budget of each rejection round
    cfg.init.rounds            = 2;           % re-association rounds over the window
    cfg.init.min_obs           = 8;           % observations a landmark needs to enter a global adjustment
    cfg.init.adjust_iterations = 40;          % LM budget of the global adjustment of a re-association pass
    %-----%
    % Multi-start pruning and thinning (2026-10-11). Every start first runs
    % prune_iterations on every prune_subsample-th observation of each
    % track; the prune_keep cheapest continue on the full set. thin_every
    % keeps every n-th observation of each track for the whole
    % initialisation (1 = all; 2 halves the stage but moves the init rate
    % by -0.3 %, which changed the closure's alias on ROT-NOM, so it is
    % off). The rejection rounds stop once a round drops less than
    % reject_stop_frac of the rows.
    cfg.init.prune_iterations  = 8;
    cfg.init.prune_subsample   = 4;
    cfg.init.prune_keep        = 2;
    cfg.init.thin_every        = 1;
    cfg.init.reject_stop_frac  = 1e-3;
    %-----%

    % closure: the offline rate-scale vote over the whole recording
    % (prog.closure_vote)
    cfg.closure.every_s         = 2.0;            % attempt spacing [s]
    cfg.closure.t_hidden_s      = 15.0;           % a landmark unseen this long is hidden
    cfg.closure.min_obs         = 5;              % observations a landmark needs to vote
    cfg.closure.min_hidden      = 6;              % hidden landmarks needed for an attempt
    cfg.closure.scales          = 0.90 : 0.0025 : 1.10;   % candidate rate scales
    cfg.closure.gate_normal_px  = 4.0;            % claim gates, looser than the loop's (the prediction carries the phase error)
    cfg.closure.gate_tangent_px = 10.0;
    cfg.closure.shifts_px       = [0 0; -6 0; 6 0; 0 -6; 0 6];   % image shifts that absorb a small translation error
    cfg.closure.max_passes      = 2;              % re-association passes after the vote
    cfg.closure.verify_tol      = 0.0025;         % verification vote within this of 1 ends the passes

    % filter: landmarks off the local surface (prog.plane_filter)
    cfg.filter.radius_m        = 0.15;        % neighbourhood radius [m]
    cfg.filter.min_neighbours  = 8;           % neighbours needed to decide
    cfg.filter.tolerance_m     = 0.03;        % distance to the local plane that flags a landmark [m]
    %-----%

    % prog: progressive map building
    cfg.prog.local_every_s          = cfg.traj.knot_spacing_s;      % DERIVED: one local adjustment per new knot
    cfg.prog.local_window_s         = 3 * cfg.traj.knot_spacing_s;  % DERIVED: the knots a cubic B-spline segment touches
    cfg.prog.global_growth          = 1.25;   % FIXED: global adjustment when the observations grow by 25 %; 1.10 insensitive
    cfg.prog.flow_half_step_s       = cfg.data.slice_s / 2;         % DERIVED: finite difference over one slice
    cfg.prog.gate_normal_px         = GATE_PX;
    cfg.prog.gate_tangent_px        = cfg.surface.cell_px;          % DERIVED: an edge fragment is one surface cell long
    cfg.prog.image_margin_px        = cfg.prog.gate_tangent_px;     % DERIVED: an off-image prediction can still reach events one gate away
    cfg.prog.min_normal_cos         = 0.5;    % FIXED: edge orientation within 60 deg
    cfg.prog.min_claim_events       = MIN_EVENTS;
    cfg.prog.correction_iterations  = 3;      % FIXED: in-slice motion correction budget (runs every slice)
    cfg.prog.local_iterations       = LM_ITERS;
    cfg.prog.global_iterations      = LM_ITERS;
    cfg.prog.cand_gate_px           = cfg.track.gate_px;
    cfg.prog.cand_max_gap_s         = MAX_GAP_S;
    cfg.prog.cand_min_events        = cfg.track.min_events;
    cfg.prog.seed_cell_px           = cfg.track.seed_cell_px;
    %-----%
    % (the alpha-beta gains cand_pos_gain / cand_vel_gain were removed with
    % the alpha-beta candidate filter)
    %-----%
    cfg.prog.cand_min_samples       = 12;     % FIXED: samples before triangulating; 8 insensitive, 20 loses coverage
    cfg.prog.cand_min_turn_deg      = 8.0;    % FIXED: viewing baseline [deg]; 5 and 12 insensitive
    cfg.prog.cand_min_depth         = cfg.adjust.min_depth;
    cfg.prog.cand_max_rms_px        = MAX_RMS_PX;

    % final: offline refinement after the loop
    cfg.final.min_obs          = MIN_OBS;
    cfg.final.iterations       = [LM_ITERS LM_ITERS];
    cfg.final.max_point_rms_px = MAX_RMS_PX;
    cfg.final.revisit_fraction = 0.8;  % FIXED: diagnostic only ("revisited" flag)
end
