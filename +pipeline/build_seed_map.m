function [landmarks, observations, seed] = build_seed_map(trajectory, obs, slice_times, cam, tangent_weight)
% BUILD_SEED_MAP Triangulate the warm tracks using the initialized trajectory.
% obs: F-by-N-by-4, [u v nx ny]; NaN for unobserved tracks.
% slice_times: F-by-1 ORIGINAL recording-relative times, not tau.
% landmarks: N-by-3 object-frame coordinates in model units.
% observations: M-by-6 [time_s, landmark_id, u, v, nx, ny].
% This row layout is different from obs and from the separate fi/ii arrays.
slice_times = double(slice_times(:));
assert(size(obs,1)==numel(slice_times) && size(obs,3)==4, ...
    'obs must have one row per slice time and four components.');
assert(all(isfinite(slice_times)) && all(diff(slice_times)>0), ...
    'slice_times must be finite and strictly increasing.');
N = size(obs,2);
assert(N>=6, 'Too few warm tracks: need at least six.');
[fi, ii] = find(isfinite(obs(:,:,1)));
assert(~isempty(fi), 'The warm observation array is empty.');
M = numel(fi);
uv = [obs(sub2ind(size(obs),fi,ii,ones(M,1))), ...
      obs(sub2ind(size(obs),fi,ii,2*ones(M,1)))];
nn = [obs(sub2ind(size(obs),fi,ii,3*ones(M,1))), ...
      obs(sub2ind(size(obs),fi,ii,4*ones(M,1)))];
assert(all(isfinite([uv nn]),'all') && all(vecnorm(nn,2,2)>0), ...
    'Each present observation needs finite pixels and a nonzero normal.');
assert(all(accumarray(ii,1,[N 1])>=2), ...
    'Every warm track needs at least two observations.');
nn = geom.unit_rows(double(nn));
[R, T] = traj.pose(trajectory,slice_times);
landmarks = geom.triangulate_points(geom.select_entries(R,fi),T(fi,:), ...
    ii,double(uv),nn,N,tangent_weight,cam.focal,cam.principal);
observations = [slice_times(fi),double(ii),double(uv),nn];
seed = struct('slice_times',slice_times, 'n_tracks',N, 'X',landmarks, ...
    'O',observations, 'traj',trajectory);
end
