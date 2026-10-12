function export_result(result, folder)
    %-----%
    %   This function writes the result to disk: the MAT file, the cloud
    %   as PLY in model units and metres, and CSV tables of landmarks,
    %   refined poses and observation residuals.
    %-----%
    %
    %   Inputs:
    %       RESULT -> Struct from prog.package_result
    %       FOLDER -> Char, output directory (created if missing)
    
    if ~exist(folder, 'dir')
        mkdir(folder);
    end
    
    save(fullfile(folder, 'result.mat'), 'result', '-v7.3');
    io.write_ply(fullfile(folder, 'cloud_model_units.ply'), result.X);
    io.write_ply(fullfile(folder, 'cloud_m.ply'), result.X_m);
    
    % Landmarks
    writetable(array2table([result.ids, result.X, result.X_m, result.nobs], ...
        'VariableNames', {'original_id', 'x_model', 'y_model', 'z_model', ...
        'x_m', 'y_m', 'z_m', 'observation_count'}), ...
        fullfile(folder, 'landmarks.csv'));
    
    % Refined poses -- MATLAB reshape stacks columns, so the rotation is
    % written R11, R21, R31, R12, ...
    p = result.pose;
    writetable(array2table([p.time_s, p.T_model, p.T_m, reshape(p.R, 9, [])', ...
        p.angle_rad, p.rate_deg_s], ...
        'VariableNames', {'time_s', 'tx_model', 'ty_model', 'tz_model', ...
        'tx_m', 'ty_m', 'tz_m', 'R11', 'R21', 'R31', 'R12', ...
        'R22', 'R32', 'R13', 'R23', 'R33', 'angle_rad', 'rate_deg_s'}), ...
        fullfile(folder, 'poses_refined.csv'));
    
    %-----%
    % (The online pose table was removed with the real-time stage.)
    %-----%
    
    % Observations, with both ID conventions
    writetable(array2table([result.O(:, 1:2), result.observations(:, 2), ...
        result.O(:, 3:6), result.normal_residual_px], ...
        'VariableNames', {'time_s', 'original_id', 'point_row', 'u_px', 'v_px', ...
        'normal_u', 'normal_v', 'normal_residual_px'}), ...
        fullfile(folder, 'observation_residuals.csv'));

end