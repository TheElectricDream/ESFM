function test_remaining_pipeline()
% TEST_REMAINING_PIPELINE Synthetic numerical parity against ORIGINAL gold kernels.
% Run setup_remaining_pipeline first. Requires rangesearch; no recording needed.
% This checks extraction/integration, not spacecraft data quality or real-time speed.
old_rng = rng; cleanup = onCleanup(@()rng(old_rng)); %#ok<NASGU>
rng(7);
cam = struct('focal',[300 305],'principal',[320 240]);
cfg = pipeline.reconstruction_defaults(cam);
cfg.start_time_s=60; cfg.end_time_s=65; cfg.warm_duration_s=3; cfg.slice_s=0.1;
tr = traj.create_trajectory(60,65,1);
tr.a = [0.12;-1;0.08]; tr.a=tr.a/norm(tr.a);
tr.omega=0.30; tr.c=[0.01 -0.02]; tr.V=[0 0 0];
t = (60:0.1:63)';
N=12; F=numel(t);
X=0.12*(rand(N,3)-0.5); X=X-mean(X,1);
fi=repelem((1:F)',N); ii=repmat((1:N)',F,1);
[Ra,Ta]=traj.pose(tr,t(fi));
[Rb,Tb]=gold_kernel_reference('trajectory_pose',tr,t(fi));
assert_close(Ra,Rb,'trajectory rotations'); assert_close(Ta,Tb,'translations');
[uv,~]=geom.project_points(Ra,Ta,X(ii,:),cam.focal,cam.principal);
[Rp,Tp]=traj.pose(tr,t(fi)+0.01); [Rm,Tm]=traj.pose(tr,t(fi)-0.01);
vp=geom.project_points(Rp,Tp,X(ii,:),cam.focal,cam.principal);
vm=geom.project_points(Rm,Tm,X(ii,:),cam.focal,cam.principal);
nn=geom.unit_rows(vp-vm);
O=[t(fi),ii,uv,nn];
obs=nan(F,N,4);
for c=1:4
    values=[uv nn];
    obs(sub2ind(size(obs),fi,ii,c*ones(size(fi))))=values(:,c);
end
[Xa,Sa]=geom.triangulate_points(Ra,Ta,ii,uv,nn,N,0.15,cam.focal,cam.principal);
[Xb,Sb]=gold_kernel_reference('triangulate_points',Ra,Ta,ii,uv,nn,N,0.15,cam.focal,cam.principal);
assert_close(Xa,Xb,'triangulation'); assert_close(Sa,Sb,'covariance proxy');
assert(max(abs(Xa-X),[],'all')<1e-4,'Synthetic triangulation missed known structure.');
[Xseed,Oseed]=pipeline.build_seed_map(tr,obs,t,cam,0.15);
assert_close(Xseed,Xa,'seed assembly');
assert_close(sortrows(Oseed,[1 2]),sortrows(O,[1 2]),'seed observation assembly');

% Nonzero corrections, parameter indexing, and tangent-axis increments.
trc=tr; trc.k=0.001*randn(tr.K,1); trc.m=0.0001*randn(tr.K,3);
[Ra,Ta]=traj.pose(trc,t);
[Rb,Tb]=gold_kernel_reference('trajectory_pose',trc,t);
assert_close(Ra,Rb,'corrected rotations'); assert_close(Ta,Tb,'corrected translations');
ca=traj.select_free_parameters(trc,true,63,61,false);
cb=gold_kernel_reference('select_free_parameters',trc,true,63,61,false);
assert_close(ca,cb,'free parameter layout');
p=1e-5*randn(8+4*tr.K,1);
assert_close(traj.increment_trajectory(trc,p), ...
    gold_kernel_reference('increment_trajectory',trc,p),'parameter increments');

% Exercise the optimizer with nonzero residuals, then compare the SAME problem.
Xp=X+0.003*randn(size(X));
cols=traj.select_free_parameters(tr,true,63,[],false);
[~,~,before]=adjust.refine_motion_and_structure(tr,Xp,O,cols,(1:N)',0,cfg.adjustment);
[ta,xa,ia]=adjust.refine_motion_and_structure(tr,Xp,O,cols,(1:N)',5,cfg.adjustment);
[tb,xb,ib]=gold_kernel_reference('refine_motion_and_structure',tr,Xp,O,cols,(1:N)',5,cfg.adjustment);
assert_close(ta,tb,'joint fit motion'); assert_close(xa,xb,'joint fit structure');
assert_close(ia,ib,'joint fit diagnostics');
assert(ia.cost<before.cost,'The synthetic joint fit did not reduce its objective.');
fprintf('PASS geometry, parameter layout and joint optimization against gold kernels.\n');

% Exercise association, knot correction, candidate tracking and point promotion.
map_a=pipeline.create_map(tr,X,O); map_b=map_a;
map_a.knots_free=true; map_b.knots_free=true;
edges=60:0.1:65;
newX=[0.27 0.16 0.10]; allX=[X;newX];
s=cfg.association;
all_events=zeros(0,5);
for f=31:49
    tc=edges(f+1);
    [R0,T0]=traj.pose(tr,tc);
    [Rp,Tp]=traj.pose(tr,tc+0.01); [Rm,Tm]=traj.pose(tr,tc-0.01);
    up=geom.project_points(Rp,Tp,allX,cam.focal,cam.principal);
    um=geom.project_points(Rm,Tm,allX,cam.focal,cam.principal);
    velocity=(up-um)/0.02;
    event_times=tc+repmat([-0.02;-0.01;0;0.01;0.02],N+1,1);
    point_ids=repelem((1:N+1)',5);
    [Re,Te]=traj.pose(tr,event_times);
    pixels=geom.project_points(Re,Te,allX(point_ids,:),cam.focal,cam.principal);
    flow=velocity(point_ids,:);
    [event_times,order]=sort(event_times); pixels=pixels(order,:); flow=flow(order,:);
    [map_a,info_a]=pipeline.process_reconstruction_slice(f,tc,event_times, ...
        pixels(:,1),pixels(:,2),flow,map_a,edges,s,cfg.adjustment);
    [map_b,info_b]=gold_kernel_reference('process_reconstruction_slice',f,tc,event_times, ...
        pixels(:,1),pixels(:,2),flow,map_b,edges,s,cfg.adjustment);
    assert_close(map_a,map_b,'progressive map'); assert_close(info_a,info_b,'slice diagnostics');
    all_events=[all_events;event_times,pixels,flow]; %#ok<AGROW>
end
assert(size(map_a.X,1)>N,'The synthetic new feature was not promoted to a landmark.');
assert(any(map_a.nobs(1:N)>F),'No known synthetic landmark was matched.');
% Explicit empty-event slice exercises misses without deleting map points.
f=50; empty=zeros(0,1);
[ma,ia]=pipeline.process_reconstruction_slice(f,edges(f+1),empty,empty,empty,zeros(0,2),map_a,edges,s,cfg.adjustment);
[mb,ib]=gold_kernel_reference('process_reconstruction_slice',f,edges(f+1),empty,empty,empty,zeros(0,2),map_b,edges,s,cfg.adjustment);
assert_close(ma,mb,'empty slice map'); assert_close(ia,ib,'empty slice diagnostics');
fprintf('PASS association, knot correction, candidate promotion and empty slice against gold.\n');

% Full continuation wrapper, including final filtering, ID compaction and exports.
ev=struct('t',all_events(:,1),'x',all_events(:,2),'y',all_events(:,3), ...
    'flow',all_events(:,4:5),'accept',true(size(all_events,1),1));
cfg.schedule.warm_iterations=3; cfg.schedule.local_iterations=2;
cfg.schedule.global_iterations=2; cfg.schedule.final_iterations=[3 2];
cfg.output.make_figures=false; cfg.output.save_checkpoints=false;
cfg.output.root=tempname; mkdir(cfg.output.root);
[result,~]=pipeline.run_remaining(ev,cam,tr,obs,t,cfg);
assert(all(result.observations(:,2)<=size(result.X,1)),'Invalid compact IDs.');
assert(all(result.ids(result.observations(:,2))==result.O(:,2)),'Original/compact IDs disagree.');
assert(exist(fullfile(result.run_dir,'landmarks.csv'),'file')==2,'Missing exported landmarks.');
assert(isfinite(result.normal_rms_px) && result.normal_rms_px<0.5,'Unexpected synthetic reconstruction residual.');
assert(all(isfinite(result.X),'all') && result.scale.m_per_unit>0,'Invalid final geometry.');
fprintf('PASS complete synthetic continuation and exports. Temporary output: %s\n',result.run_dir);
fprintf('These tests do not establish real-data accuracy or deployment speed.\n');
end

function assert_close(a,b,label)
if isstruct(a)
    assert(isstruct(b) && isequal(size(a),size(b)) && isequal(fieldnames(a),fieldnames(b)), ...
        'Structure mismatch: %s',label);
    fields=fieldnames(a);
    for k=1:numel(a)
        for j=1:numel(fields)
            name=fields{j}; assert_close(a(k).(name),b(k).(name),[label '.' name]);
        end
    end
elseif isnumeric(a) || islogical(a)
    assert(isequal(size(a),size(b)), 'Size mismatch: %s',label);
    assert(isequal(isnan(a),isnan(b)) && isequal(isinf(a),isinf(b)), ...
        'Nonfinite mismatch: %s',label);
    assert(isequal(a(isinf(a)),b(isinf(b))), 'Infinity sign mismatch: %s',label);
    valid=isfinite(a) & isfinite(b);
    if any(valid(:))
        scale=max(1,max(abs(b(valid))));
        assert(max(abs(a(valid)-b(valid)))<1e-9*scale, 'Numerical mismatch: %s',label);
    end
else
    assert(isequaln(a,b), 'Value mismatch: %s',label);
end
end
