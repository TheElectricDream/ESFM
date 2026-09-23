function export_reconstruction(result)
folder = result.run_dir;
io.write_ply(fullfile(folder, 'cloud_model_units.ply'), result.X);
io.write_ply(fullfile(folder, 'cloud_m.ply'), result.X_m);
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
