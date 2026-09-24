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
    cfg.data.hdf5_dir     = '/run/media/alexandercrain/Secondary_Drive/Event Datasets/SPOT/HDF5/';
    cfg.data.hdf5_file    = 'recording_20251029_131131.hdf5';
    cfg.data.start_time_s = 60.0;    % T0 [s]: first event time used
    cfg.data.end_time_s   = 185.0;   % T1 [s]: last event time used

    % camera: set the camera intrinsics (the image size is read from here too)
    cfg.camera.calibration_xml = ['calibration_camera_DVXplorerM_DXUS0047' ...
        '-2026_07_27_11_26_49-fisheye.xml'];

    % output: where results go, and the metric scale
    cfg.output.dir                = fullfile(pwd, 'output_current');
    cfg.output.known_width_m      = 1.27;  % panel span used for scaling [m]
    cfg.output.scale_endpoint_ids = [];    % two original landmark IDs spanning the known width, if known

    % scene: the only parameters that depend on how the target moves
    cfg.surface.cell_s       = 0.8;           % temporal window of a surface cell [s]; scale as 1/(image speed)
    cfg.warm.duration_s      = 6.0;           % warm-start window [s]; must cover ~30 deg of rotation
    cfg.warm.rate_seeds_deg_s = [2 4 6 8 10]; % spin rates the warm search starts from [deg/s]; bracket the expected rate
    cfg.traj.knot_spacing_s  = 1.0;           % spline knot spacing [s]; shortest time scale of spin-rate changes

    % Everything else follows from physics, geometry, the values above, or
    % was verified to have no significant effect
    cfg = derived_parameters(cfg);
end
