function [trajectory, landmarks, info] = refine_warm_map(trajectory, landmarks, observations, settings)
% REFINE_WARM_MAP Jointly adjust mean motion and all seed landmarks.
% Spline coefficients remain fixed during this stage.
cols = traj.select_free_parameters(trajectory,true,[],[],settings.adjustment.free_V);
[trajectory, landmarks, info] = adjust.refine_motion_and_structure( ...
    trajectory,landmarks,observations,cols,(1:size(landmarks,1))', ...
    settings.schedule.warm_iterations,settings.adjustment);
end
