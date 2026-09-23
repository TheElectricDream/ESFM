function [cam] = read_calibration(camera_cfg)
    %   Imports the camera calibration XML file to
    %   undistort events downstream
    %
    %   Inputs: 
    %       CAMERA_CFG -> Struct, contains XML filename.
    %     
    %   Outputs:
    %       CAM -> Struct, contains imported intrinsics.
    
    % Define path
    xml_path = fullfile(fileparts(which('config')),...
        camera_cfg.calibration_xml);

    % Pass an error to the user if there is no calibration file
    if ~exist(xml_path,'file')
        errMsg = sprintf('No XML calibration file found at:\n%s', xml_path);
        errordlg(errMsg, 'Calibration File Missing', 'modal');
        error('read_calibration:MissingFile', '%s', errMsg);
    end

    % Read the file
    text = fileread(xml_path);

    % Extract the relevant data
    K_tok = regexp(text, '<camera_matrix.*?<data>(.*?)</data>',...
        'tokens', 'once');
    d_tok = regexp(text, '<distortion_coefficients.*?<data>(.*?)</data>',...
        'tokens', 'once');
    if isempty(K_tok) || isempty(d_tok)
        error('io:read_calibration', ...
            'Calibration XML "%s" has no camera_matrix/distortion_coefficients block.', xml_path);
    end
    K = sscanf(K_tok{1}, '%f');
    d = sscanf(d_tok{1}, '%f');

    % Store the data in the cam structure
    cam.focal     = [K(1) K(5)];
    cam.principal = [K(3) K(6)];
    cam.k1        = d(1);
    if numel(d) >= 2
        cam.k2 = d(2); 
    end

    % Print a success message
    fprintf(['Calibration Loaded: f = [%.2f %.2f], c = [%.2f %.2f],'...
        ' k = [%.5f %.5f]\n'], cam.focal, cam.principal, cam.k1, cam.k2);
end