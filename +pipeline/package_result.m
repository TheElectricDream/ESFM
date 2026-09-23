function result = package_result(final, map, run_log, edges, warm, cam, settings)
% PACKAGE_RESULT Compact landmark IDs, apply known scale, and sample poses.
% result.traj stays in MODEL units. result.pose.T_m is the metric translation.
% result.O retains original map IDs; result.observations indexes result.X.
result = struct();
result.traj = final.traj;
result.X = final.X;
result.O = final.O;
result.ids = final.ids;
result.edges = edges;
result.log = run_log;
result.warm = warm;
result.nobs = map.nobs(final.ids);
result.observations = final.O;
[found,compact_ids] = ismember(final.O(:,2),final.ids);
assert(all(found), 'An observation refers to a removed landmark.');
result.observations(:,2) = compact_ids;
result.normal_residual_px = final.normal_residual_px;
result.normal_rms_px = sqrt(mean(final.normal_residual_px.^2));
result.revisited = final.revisited;
result.parameters = settings;
result.camera = cam;
result.scale = geom.calibrate_model_scale(result.X,result.ids,settings.output);
result.X_m = result.scale.m_per_unit*result.X;
result.pose = traj.sample_refined_trajectory(result.traj,edges(:),result.scale.m_per_unit);
result.final_pose = struct('time_s',edges(end),'R',result.pose.R(:,:,end), ...
    'T_model',result.pose.T_model(end,:)', 'T_m',result.pose.T_m(end,:)');
result.final_diagnostics = rmfield(final,{'traj','X','O','ids','normal_residual_px','revisited'});
end
