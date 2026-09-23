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
    cfg.data.hdf5_file    = 'recording_20251029_135047.hdf5';
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
    cfg.data.slice_s                    = 0.05;  % batch length [s]; every stateful stage

    % track: 2D feature tracking over accepted events 
    cfg.track.gate_px                   = 3.0;  % claim radius around a track's prediction
    cfg.track.seed_cell_px              = 6;  % cell size for seeding new tracks
    cfg.track.min_events                = 5;  % events needed to claim, and to seed
    cfg.track.gain_position             = 0.6;  % constant gain on position correction
    cfg.track.gain_velocity             = 0.12;  % constant gain on velocity correction
    cfg.track.max_miss                  = 15;  % slices unclaimed before a track retires
    cfg.track.min_length                = 20;  % samples for a track to be returned

    % warm: warm-start window and track admission
    cfg.warm.duration_s                 = 6.0;  % length of the warm-start window [s]
    cfg.warm.min_obs_per_track          = 15;  % slices a track must appear in
    cfg.warm.min_track_motion_px        = 0.5;  % pixel std over the window; a track that never moves is a hot pixel, not a feature
    cfg.warm.cauchy_px                  = 2.0;            % robust scale of the warm fits [px]
    cfg.warm.free_mean_velocity         = false; % false pins the mean centre drift to zero
    cfg.warm.min_depth                  = 0.2;            % landmarks nearer than this are penalized
    cfg.warm.tangent_weight             = cfg.adjust.tangent_weight;  % same weighting as the adjuster

    % warm: the axis and rate search 
    cfg.warm.hemisphere_directions      = 13;       % axes tried, spread over a hemisphere
    cfg.warm.base_axis                  = [0 -1 0];             % hemisphere is centred here
    cfg.warm.rate_seeds_deg_s           = [2 4 6 8 10];  % rate starting points
    cfg.warm.max_function_evals         = 600;         % solver budget per fit
    cfg.warm.max_velocity_per_s         = 0.2;         % bound on centre drift [range/s]
    cfg.warm.max_centre_offset          = 1.0;          % bound on centre offset [range]
    cfg.warm.rate_profile_deg_s         = 1:0.2:12;    % rates scanned for the confidence valley

    % traj: the trajectory estimation
    cfg.traj.knot_spacing_s             = 1.0;

end