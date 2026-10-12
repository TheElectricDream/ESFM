function [ev] = load_events(data_cfg)
    %   Imports all events from the HDF5 file defined in the
    %   configuration function.
    %
    %   Inputs: 
    %       DATA_CFG -> Struct, contains import settings.
    %     
    %   Outputs:
    %       EV -> Struct, contains all loaded events.

    % Define the path
    path = fullfile(data_cfg.hdf5_dir, data_cfg.hdf5_file);

    % Import event data
    ev.t = double(h5read(path, '/timestamp'));
    ev.x = double(h5read(path, '/x'));  % [px]
    ev.y = double(h5read(path, '/y'));  % [px]
    ev.p = int8(h5read(path, '/polarity'));  % [-]
    
    % Convert timestamps
    ev.t = (ev.t - ev.t(1))./ 1e6;  % [us] -> [s]

    % Get range of useful data
    time_range = ev.t >= data_cfg.start_time_s & ev.t < data_cfg.end_time_s;

    % Extract data within the range
    ev.t = ev.t(time_range);
    ev.x = ev.x(time_range);
    ev.y = ev.y(time_range);
    ev.p = ev.p(time_range);

    % Set the polarity to be between -1 and +1
    ev.p(ev.p<=0) = -1;

end