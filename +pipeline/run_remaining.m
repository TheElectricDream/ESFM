function [result, map] = run_remaining(ev, cam, trajectory, obs, slice_times, settings)
% RUN_REMAINING All stages after trajectory initialization, without a warm refit search.
% ev.x/y must already be UNDISTORTED; accept/flow must cover the remaining interval.
% Inputs are copies: the caller's warm trajectory/obs are not changed.
% map is the progressive state BEFORE final batch refinement/filtering.
clock_start = tic;
assert(exist('rangesearch','file')==2, ...
    'Statistics and Machine Learning Toolbox (rangesearch) is required.');
assert(settings.end_time_s > settings.start_time_s + settings.warm_duration_s, ...
    'end_time_s must extend beyond the warm window.');
assert(settings.slice_s>0 && settings.warm_duration_s>0, 'Invalid time settings.');
assert(abs(settings.warm_duration_s/settings.slice_s - ...
    round(settings.warm_duration_s/settings.slice_s))<1e-8, ...
    'For gold scheduling, warm_duration_s must be a whole number of slices.');
assert(abs(trajectory.t0-settings.start_time_s)<1e-9, ...
    'trajectory.t0 must match the start used to construct warm tau.');
assert(settings.end_time_s < trajectory.t0+trajectory.n_seg*trajectory.h, ...
    'Trajectory allocation does not cover the requested end time.');
assert(all(isfinite([trajectory.a(:);trajectory.omega;trajectory.c(:); ...
    trajectory.V(:);trajectory.k(:);trajectory.m(:)])), 'Invalid trajectory parameters.');
assert(abs(norm(trajectory.a)-1)<1e-8 && isequal(size(trajectory.c),[1 2]) ...
    && isequal(size(trajectory.V),[1 3]), 'Unexpected trajectory shape.');
assert(all(slice_times(:)>=settings.start_time_s-1e-6) && ...
    max(slice_times(:))<=settings.start_time_s+settings.warm_duration_s+1e-5, ...
    'slice_times must belong to the warm window, in original timestamp coordinates.');
ev.t = double(ev.t(:)); ev.x = double(ev.x(:)); ev.y = double(ev.y(:));
ev.accept = logical(ev.accept(:)); ev.flow = double(ev.flow);
N = numel(ev.t);
assert(N>0 && numel(ev.x)==N && numel(ev.y)==N && numel(ev.accept)==N ...
    && isequal(size(ev.flow),[N 2]), 'Event arrays have inconsistent lengths.');
assert(all(isfinite(ev.t)) && all(diff(ev.t)>=0), 'ev.t must be finite and sorted.');
assert(all(isfinite(ev.x(ev.accept))) && all(isfinite(ev.y(ev.accept))) && ...
    all(isfinite(ev.flow(ev.accept,:)),'all'), 'Accepted events must be finite.');
assert(any(ev.accept & ev.t>settings.start_time_s+settings.warm_duration_s ...
    & ev.t<settings.end_time_s), ...
    'No accepted continuation events: compute flow AFTER the warm window first.');
% Synchronize duplicated settings to prevent stale defaults after main-script edits.
settings.association.dt = settings.slice_s;
settings.association.free_V = settings.adjustment.free_V;
settings.adjustment.focal = reshape(double(cam.focal),1,2);
settings.adjustment.principal = reshape(double(cam.principal),1,2);
settings.association.focal = settings.adjustment.focal;
settings.association.principal = settings.adjustment.principal;
settings.association.eps = settings.adjustment.eps;
cam.focal = settings.adjustment.focal; cam.principal = settings.adjustment.principal;
if ~settings.adjustment.free_V
    assert(all(trajectory.V==0), ...
        'free_V=false freezes V; initialize it to zero as in the warm motion model.');
end
if ~exist(settings.output.root,'dir'); mkdir(settings.output.root); end
run_dir = tempname(settings.output.root);
mkdir(run_dir);
[landmarks, observations, warm] = pipeline.build_seed_map( ...
    trajectory,obs,slice_times,cam,settings.adjustment.eps);
[trajectory, landmarks, warm.joint_info] = pipeline.refine_warm_map( ...
    trajectory,landmarks,observations,settings);
warm.joint_X = landmarks;
warm.joint_traj = trajectory;
if settings.output.save_checkpoints
    save(fullfile(run_dir,'initialization.mat'),'warm','settings','-v7.3');
end
settings.adjustment.fd_check = false;
fprintf('Joint warm fit: %d points, rate %.6f deg/s, RMS %.6f px.\n', ...
    size(landmarks,1),rad2deg(trajectory.omega),warm.joint_info.rms);
map = pipeline.create_map(trajectory,landmarks,observations);
[map,run_log,edges] = pipeline.grow_map(map,ev,settings);
if settings.output.save_checkpoints
    save(fullfile(run_dir,'pre_final_refinement.mat'),'map','run_log','settings','-v7.3');
end
final = pipeline.finalize_map(map,settings.end_time_s,settings);
result = pipeline.package_result(final,map,run_log,edges,warm,cam,settings);
result.run_dir = run_dir;
result.elapsed_s = toc(clock_start);
result.elapsed_scope = 'Backend only; excludes data loading, surface computation and warm search';
save(fullfile(run_dir,'result.mat'),'result','-v7.3');
io.export_reconstruction(result);
if settings.output.make_figures
    viz.inspect_reconstruction(result);
end
fprintf('Final: %d points, %d observations, normal RMS %.6f px.\n', ...
    size(result.X,1),size(result.O,1),result.normal_rms_px);
fprintf('Mean rate %.6f deg/s; scale %.6f m/model-unit (%s).\n', ...
    rad2deg(result.traj.omega),result.scale.m_per_unit,result.scale.method);
fprintf('Saved: %s\n',run_dir);
end
