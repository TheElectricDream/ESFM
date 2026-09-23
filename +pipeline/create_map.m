function map = create_map(trajectory, landmarks, observations)
% CREATE_MAP Initialize persistent reconstruction state after joint warm fit.
% map.O has [time,id,u,v,nx,ny]; its IDs index rows of map.X.
N = size(landmarks,1);
assert(N>0 && ~isempty(observations), 'Cannot initialize an empty map.');
map = struct();
map.traj = trajectory;
map.X = landmarks;
map.O = observations;
map.nobs = accumarray(observations(:,2),1,[N 1]);
map.created = zeros(N,1);
map.alive = true(N,1);
map.cand = struct('x',{},'y',{},'vx',{},'vy',{},'f',{},'hist',{},'miss',{});
map.ratio = [];
map.nrm = zeros(N,2);
for i = 1:N
    rows_i = find(observations(:,2)==i);
    assert(~isempty(rows_i), 'A seed landmark has no observations.');
    map.nrm(i,:) = observations(rows_i(end),5:6);
end
map.knots_free = false;
end
