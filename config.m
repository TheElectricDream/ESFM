function cfg = config()
    %   This function initializes all user defined constants
    %   for the reconstruction pipeline.
    %
    %   INPUTS: NONE
    %     
    %   OUTPUTS:
    %       CFG -> Struct, contains user parameters.

    % data: sets the import parameters
    cfg.data.hdf5_dir     = '/run/media/alexandercrain/Secondary_Drive/Event Datasets/SPOT/HDF5/';
    cfg.data.hdf5_file    = 'recording_20251029_131131.hdf5';
    cfg.data.start_time_s = 60.0;    % T0 [s]: first event time used
    cfg.data.end_time_s   = 185.0;   % T1 [s]: last event time used

    % camera: set the camera intrinsics
    cfg.camera.calibration_xml = ['calibration_camera_DVXplorerM_DXUS0047' ...
        '-2026_07_27_11_26_49-fisheye.xml'];

    % surface: event-surface parameters for cell-fitting
    cfg.surface.cell_px                 = 8;  % size of spacial cell kernel [px]
    cfg.surface.cell_s                  = 0.8;  % size of temporal window [s]
    cfg.surface.sigma_s                 = 0.03;  % time scale -- number of seconds that count as "1" pixel
    cfg.surface.min_events_per_cell     = 15;  % no plane-fitting below this number
    cfg.surface.min_time_normal         = 0.05;  % used to reject static flicker
    cfg.surface.min_in_surface_extent   = 1.0;  % kills hot-pixels

    % surface: acceptance gates applied after the cell fits 
    cfg.surface.max_planarity_ratio     = 0.45;  % lambda_min/lambda_mid ceiling
    cfg.surface.max_normal_speed_px_s   = 60;  % implausibly fast flow rejected
    cfg.surface.min_warped_support      = 3;  % companions on the warped pixel
    cfg.surface.split_polarities        = true;  % ON and OFF events fitted apart
    cfg.surface.two_offset_grids        = true;  % second grid shifted half a cell;

    % adjust: weight for residuals 
    cfg.adjust.tangent_weight           = 0.15;  % keeps normal equations for going singular

    % data: slicing
    cfg.data.slice_s                    = 0.1;  % batch length [s]; every stateful stage
    cfg.data.image_size                 = [640 480];  % sensor width, height [px] (DVXplorer)

    % track: 2D feature tracking over accepted events 
    cfg.track.gate_px                   = 3.0;  % claim radius around a track's prediction
    cfg.track.seed_cell_px              = 6;  % cell size for seeding new tracks
    cfg.track.min_events                = 3;  % events needed to claim, and to seed
    cfg.track.gain_position             = 0.6;  % constant gain on position correction
    cfg.track.gain_velocity             = 0.25;  % constant gain on velocity correction
    cfg.track.max_miss                  = 15;  % slices unclaimed before a track retires
    cfg.track.min_length                = 20;  % samples for a track to be returned

    % warm: warm-start window and track admission
    cfg.warm.duration_s                 = 6.0;  % length of the warm-start window [s]
    cfg.warm.min_track_motion_px        = 0.5;  % pixel std over the window; a track that never moves is a hot pixel, not a feature
    cfg.warm.cauchy_px                  = 2.0;            % robust scale of the warm fits [px]
    cfg.warm.free_mean_velocity         = false; % false pins the mean centre drift to zero
    cfg.warm.min_depth                  = 0.2;            % landmarks nearer than this are penalized
    cfg.warm.tangent_weight             = cfg.adjust.tangent_weight;  % same weighting as the adjuster

    % warm: the axis and rate search 
    cfg.warm.hemisphere_directions      = 13;  % axes tried, spread over a hemisphere
    cfg.warm.base_axis                  = [0 -1 0];  % hemisphere is centred here
    cfg.warm.rate_seeds_deg_s           = [2 4 6 8 10];  % rate starting points
    cfg.warm.max_function_evals         = 600;  % solver budget per fit
    cfg.warm.max_velocity_per_s         = 0.2;  % bound on centre drift [range/s]
    cfg.warm.max_centre_offset          = 1.0;  % bound on centre offset [range]
    cfg.warm.rate_profile_deg_s         = 1:0.2:12;  % rates scanned for the confidence valley
    cfg.warm.adjust_iterations          = 20; % LM iterations for the warm joint adjustment

    % traj: the trajectory estimation
    cfg.traj.knot_spacing_s             = 1.0;
    
    % adjust: the point cloud and pose refinement
    cfg.adjust.sigma_px                 = 0.5;  % expected pixel noise; whitens every image residual [px]
    cfg.adjust.cauchy_px                = 4.0;  % robust scale of the adjuster [px] (the warm stage uses 2.0)
    cfg.adjust.min_depth                = 0.2;  % depth limit; closer observations are penalized [model units]
    cfg.adjust.depth_weight             = 100;  % hinge residual per model unit of depth violation [sigma/unit]
    cfg.adjust.lambda_rotation          = 500;  % angular curvature weight [sigma per deg/s^2]
    cfg.adjust.lambda_translation       = 200;  % translation curvature weight [sigma per permille/s^2]
    cfg.adjust.pull_fraction            = 0.1;  % coefficient pull, as a fraction of the curvature weights
    cfg.adjust.gauge_weight             = 1e4;  % zero spline correction at t0 (fixes frame and scale)
    cfg.adjust.centroid_weight          = 1e2;  % map centroid at zero along the axis
    cfg.adjust.damping0                 = 1e-3;  % initial Marquardt damping
    cfg.adjust.damping_down             = 3;     % divide damping by this after an accepted step
    cfg.adjust.damping_up               = 4;     % multiply damping by this after a rejected step
    cfg.adjust.max_attempts             = 6;     % rejected steps allowed per iteration before stopping
    cfg.adjust.step_tol                 = 1e-8;  % stop when the step norm falls below this
    
    % prog: progressive improvment of point cloud
    cfg.prog.knots_free_after_s = 0.0;       % release the spline this long after the warm start [s]
    cfg.prog.local_every_s      = 1.0;       % local adjustment cadence [s]
    cfg.prog.global_every_s     = 10.0;      % global adjustment cadence [s]
    cfg.prog.early_global_s     = [1 3 6];   % extra global adjustments, seconds after the warm start
    cfg.prog.print_every_s      = 10.0;      % progress print cadence [s]
    cfg.prog.flow_half_step_s   = 0.05;       % half-width of the predicted-flow difference [s]
    cfg.prog.image_margin_px    = 20;         % predictions this far outside the image still count
    cfg.prog.gate_normal_px     = 3.0;   % max event distance across the predicted edge [px]
    cfg.prog.gate_tangent_px    = 8.0;   % max event distance along it, and neighbour radius [px]
    cfg.prog.min_normal_cos     = 0.5;   % edge orientation within 60 deg of the landmark's normal
    cfg.prog.min_claim_events   = 3;     % events needed for a claim
    cfg.prog.local_window_s        = 3.0;  % recent window for the in-slice correction and local adjustment [s]
    cfg.prog.min_mature_claims     = 6;    % unambiguous claims needed to run the in-slice correction
    cfg.prog.correction_iterations = 3;    % LM iterations of the in-slice correction
    cfg.prog.cand_gate_px    = 3.0;   % candidate search radius around its prediction [px]
    cfg.prog.cand_max_gap_s  = 0.5;   % drop a candidate after this long without a hit [s] (gold: 5 slices of 0.1 s)
    cfg.prog.cand_min_events = 3;     % events needed to update or seed a candidate
    cfg.prog.seed_cell_px    = 6;     % grid cell size for seeding candidates [px]
    cfg.prog.cand_pos_gain   = 0.6;   % alpha: position gain of the candidate filter
    cfg.prog.cand_vel_gain   = 0.25;  % beta: velocity gain of the candidate filter
    cfg.prog.cand_min_samples  = 12;    % history samples needed before triangulating
    cfg.prog.cand_min_turn_deg = 8.0;   % rotation needed over the history (viewing baseline) [deg]
    cfg.prog.cand_min_depth    = 0.3;   % every sample must be deeper than this [model units]
    cfg.prog.cand_max_rms_px   = 2.0;   % max normal reprojection RMS over the history [px]
    cfg.prog.cand_max_sigma    = 0.03;  % max std-dev of the covariance proxy [model units]
    cfg.prog.local_iterations  = 8;    % LM iterations of the local adjustment
    cfg.prog.global_iterations = 10;   % LM iterations of the global adjustment
    cfg.prog.global_min_nobs   = 10;   % observations a landmark needs to enter the global adjustment

    cfg.final.min_obs          = 20;       % observations a landmark needs for the final refinement
    cfg.final.iterations       = [20 10];  % LM iterations of the two final passes
    cfg.final.max_point_rms_px = 2.0;      % drop landmarks above this normal RMS after pass 1 [px]
    cfg.final.revisit_fraction = 0.8;      % "revisited" = seen over this fraction of a rotation

    cfg.output.dir                = fullfile(pwd, 'output_current');
    cfg.output.known_width_m      = 1.27;  % panel span used for scaling [m]
    cfg.output.scale_endpoint_ids = [];    % two original landmark IDs spanning the known width, if known
end