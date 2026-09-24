function cfg = derived_parameters(cfg)
    %   Fills in every pipeline constant that is NOT a scene parameter.
    %   Each value is one of:
    %
    %     DERIVED  -- follows from another parameter, from geometry, or from
    %                 filter theory; change the source, never this line
    %     FIXED    -- a standard/structural constant, or a value whose
    %                 effect was verified to be within run-to-run noise
    %                 over the range noted
    %
    %   None of these should need tuning for a new recording. The trials
    %   behind every "insensitive" note are documented in PARAMETERS.md.
    %
    %   Inputs:
    %       CFG -> Struct from config(), holding the scene parameters
    %
    %   Outputs:
    %       CFG -> Struct, with every field the pipeline reads

    % Shared constants -- each is used by several stages, so it lives in
    % exactly one place
    MIN_EVENTS  = 3;    % FIXED: events that make a feature (claim, seed, warped support)
    GATE_PX     = 3.0;  % FIXED: how far an event may sit from a predicted edge [px]; 2 ok, 4 worse
    MAX_RMS_PX  = 2.0;  % FIXED: largest normal reprojection RMS a landmark may have [px]; 1.5-3 insensitive
    MIN_OBS     = 20;   % FIXED: samples that make a track trustworthy (warm tracks, final refinement)
    MAX_GAP_S   = 1.5;  % FIXED: time a 2D track may go unseen before it is dropped [s]
    LM_ITERS    = 10;   % FIXED: LM budget of every joint adjustment; x0.5 and x2 insensitive

    % data
    cfg.data.slice_s = 0.1;  % FIXED: batch length [s]; 0.05 insensitive (latency/compute choice)

    % surface: the plane fit is done in a normalized space where one pixel
    % and sigma_s seconds have the same length. Scaling sigma_s with the
    % temporal window keeps the cell's shape in that space constant, so the
    % shape thresholds below do not depend on the scene
    cfg.surface.cell_px             = 8;     % FIXED: spatial cell [px]; 6 and 10 mildly worse
    cfg.surface.sigma_s             = cfg.surface.cell_s * 0.0375;  % DERIVED: 0.03 s at cell_s = 0.8 s
    cfg.surface.min_events_per_cell = 15;    % FIXED: minimum for a stable 3x3 covariance; 10 mildly worse
    cfg.surface.min_time_normal     = 0.05;  % FIXED: rejects static/flickering edges (planes containing the time axis); REQUIRED
    cfg.surface.max_planarity_ratio = 0.45;  % FIXED: thin-sheet test in normalized space; 0.35 and 0.55 both worse
    cfg.surface.min_warped_support  = MIN_EVENTS;  % FIXED: REQUIRED (removing it degrades the cloud)
    cfg.surface.split_polarities    = true;  % FIXED: structural choice
    cfg.surface.two_offset_grids    = true;  % FIXED: structural choice

    % track: 2D alpha-beta tracker, shared by the warm start (track.*)
    % and the progressive candidates (prog.cand_*)
    cfg.track.gate_px       = GATE_PX;
    cfg.track.seed_cell_px  = 2 * GATE_PX;  % DERIVED: seed cells span one gate diameter (6 px)
    cfg.track.min_events    = MIN_EVENTS;
    cfg.track.gain_position = 0.6;  % FIXED: alpha
    cfg.track.gain_velocity = cfg.track.gain_position^2 / (2 - cfg.track.gain_position);  % DERIVED: Benedict-Bordner beta = alpha^2/(2-alpha)
    cfg.track.max_miss      = round(MAX_GAP_S / cfg.data.slice_s);  % DERIVED: slices in MAX_GAP_S
    cfg.track.min_length    = MIN_OBS;

    % adjust: robust bundle adjustment. Image residuals are in pixels, so
    % the prior weights below are "pixels of equivalent error per unit"
    cfg.adjust.tangent_weight     = 0.15;  % FIXED: along-edge/across-edge noise ratio; 0.10 and 0.25 mildly worse
    cfg.adjust.cauchy_px          = 4.0;   % FIXED: robust scale [px], also used by the warm fits; 2 insensitive
    cfg.adjust.min_depth          = 0.2;   % FIXED: depth limit [model units, range at t0 = 1]; never active here
    cfg.adjust.depth_weight       = 50;    % FIXED: hinge weight [px/unit]; x10 and /10 bit-identical (never active)
    cfg.adjust.lambda_rotation    = 250;   % FIXED: angular curvature weight [px per deg/s^2]; x3 and /3 insensitive
    cfg.adjust.lambda_translation = 100;   % FIXED: translation curvature weight [px per permille/s^2]; x3 and /3 insensitive
    cfg.adjust.pull_fraction      = 0.1;   % FIXED: pull toward zero correction, relative to the curvature weights; /10 and x3 insensitive
    cfg.adjust.gauge_weight       = 5e3;   % FIXED: gauge (t0) constraint, just "large"; /10 lets the scale gauge drift
    cfg.adjust.centroid_weight    = 50;    % FIXED: gauge (centroid along axis), just "large"
    cfg.adjust.damping0           = 1e-3;  % FIXED: standard Levenberg-Marquardt constants
    cfg.adjust.damping_down       = 3;
    cfg.adjust.damping_up         = 4;
    cfg.adjust.max_attempts       = 6;
    cfg.adjust.step_tol           = 1e-8;

    % warm: the warm start fits the same geometry as the adjuster
    cfg.warm.cauchy_px              = cfg.adjust.cauchy_px;
    cfg.warm.min_depth              = cfg.adjust.min_depth;
    cfg.warm.tangent_weight         = cfg.adjust.tangent_weight;
    cfg.warm.free_mean_velocity     = false;  % FIXED: the spline carries all translation; V stays 0
    cfg.warm.max_velocity_per_s     = 0.2;    % FIXED: bound on V, which has no effect while V is pinned
    cfg.warm.max_centre_offset      = 1.0;    % FIXED: loose bound on the centre offset [range]; never active
    cfg.warm.hemisphere_directions  = 13;     % FIXED: axis grid (x2 with the negated axes); 7 insensitive
    cfg.warm.base_axis              = [0 -1 0];  % FIXED: orientation of the grid only; [1 0 0] and [0 0 1] insensitive
    cfg.warm.max_function_evals     = 600;    % FIXED: lsqnonlin budget; 1200 bit-identical (never reached)
    cfg.warm.adjust_iterations      = LM_ITERS;

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
    cfg.prog.cand_pos_gain          = cfg.track.gain_position;
    cfg.prog.cand_vel_gain          = cfg.track.gain_velocity;
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
