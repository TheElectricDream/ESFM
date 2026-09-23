function final = finalize_map(map, end_time_s, settings)
% FINALIZE_MAP Global fit, observation/RMS filtering, then a second fit.
% IDs remain original map IDs here. Packaging supplies compact IDs as well.
trajectory = map.traj;
observations = map.O;
keep = find(map.nobs >= settings.schedule.final_min_obs);
assert(~isempty(keep), 'No points meet final_min_obs; inspect map.nobs.');
observations = observations(ismember(observations(:,2),keep),:);
cols = traj.select_free_parameters(trajectory,true,end_time_s,[],settings.adjustment.free_V);
[trajectory, landmarks, info1] = adjust.refine_motion_and_structure( ...
    trajectory,map.X,observations,cols,keep, ...
    settings.schedule.final_iterations(1),settings.adjustment);
dn = adjust.edge_normal_residuals(trajectory,landmarks,observations, ...
    settings.adjustment.focal,settings.adjustment.principal);
point_rms = sqrt(accumarray(observations(:,2),dn.^2,[size(landmarks,1) 1]) ./ ...
    max(accumarray(observations(:,2),1,[size(landmarks,1) 1]),1));
keep = keep(point_rms(keep) < settings.schedule.final_max_rms_px);
assert(~isempty(keep), 'Final normal-RMS filtering removed all landmarks.');
observations = observations(ismember(observations(:,2),keep),:);
[trajectory, landmarks, info2] = adjust.refine_motion_and_structure( ...
    trajectory,landmarks,observations,cols,keep, ...
    settings.schedule.final_iterations(2),settings.adjustment);
dn = adjust.edge_normal_residuals(trajectory,landmarks,observations, ...
    settings.adjustment.focal,settings.adjustment.principal);
first_seen = accumarray(observations(:,2),observations(:,1),[size(landmarks,1) 1],@min,inf);
last_seen = accumarray(observations(:,2),observations(:,1),[size(landmarks,1) 1],@max,-inf);
revisit = (last_seen(keep)-first_seen(keep)) > 0.8*2*pi/abs(trajectory.omega);
final = struct('traj',trajectory,'X',landmarks(keep,:), 'O',observations, ...
    'ids',keep,'normal_residual_px',dn,'revisited',revisit, ...
    'prefilter_rms_px',point_rms,'first_fit',info1,'second_fit',info2);
end
