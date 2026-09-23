function model = export_reference_model(result_file,out_dir)
% Adapt the gold result without changing its geometry or original landmark IDs.
% Its full input interval is the reconstruction prefix; later tracking starts
% at the final timestamp. No observations outside that interval may be cached.
H=run_event_spacecraft_stream('handles'); c=H.defaults();
z=load(result_file); r=z.result;
cam=H.stream_calibration(c.camera.calibration_xml,c.camera);
X=r.X; ids=r.ids;
[ok,j]=ismember(r.O(:,2),ids); O=r.O(ok,:); O(:,2)=j(ok);
[re,tt]=H.trajectory_pose(r.traj,O(:,1));
[uv,~]=H.project_points(re,tt,X(O(:,2),:),cam.focal,cam.principal);
dn=sum((O(:,3:4)-uv).*O(:,5:6),2);
nobs=accumarray(O(:,2),1,[size(X,1) 1]);
rms=sqrt(accumarray(O(:,2),dn.^2,[size(X,1) 1])./max(nobs,1));
normals=zeros(size(X,1),2);
for k=1:size(X,1), row=find(O(:,2)==k,1,'last'); normals(k,:)=O(row,5:6); end
[~,~,V]=svd(X-mean(X,1),0); a=V(:,1); pr=sort(X*a);
ends=interp1(1:numel(pr),pr,1+(numel(pr)-1)*[1 99]/100);
scale=struct('known_width_m',1.27,'endpoint_ids',[],'span_model',diff(ends), ...
    'm_per_unit',1.27/diff(ends),'label','PROVISIONAL principal-axis span', ...
    'provisional',true,'axis',a');
t=r.edges(end); [R,T,v,w]=H.trajectory_state(r.traj,t);
model=struct('version',1,'X',X,'ids',ids,'quality',nobs./(1+rms.^2), ...
    'normals',normals,'camera',cam,'freeze_time_s',t,'source',c.data.hdf5_file, ...
    'scale',scale,'normal_rms_px',rms);
model.initial_tracker=struct('R',R,'T',T,'v',v,'w',w,'t',t,'last_good_t',t, ...
    'last_good_R',R,'last_good_T',T,'normals',normals,'axis',r.traj.a(:), ...
    'lost_count',0,'win',zeros(0,6));
if ~exist(out_dir,'dir'), mkdir(out_dir); end
save(fullfile(out_dir,'frozen_model.mat'),'model','-v7.3');
times=r.edges(:); P=zeros(numel(times),15);
for k=1:numel(times)
    [R,T]=H.trajectory_state(r.traj,times(k));
    P(k,:)=[times(k),0,0,T',R(:)'];
end
names={'time_s','status','measured','tx_model','ty_model','tz_model', ...
    'R11','R21','R31','R12','R22','R32','R13','R23','R33'};
writetable(array2table(P,'VariableNames',names),fullfile(out_dir,'reconstruction_poses.csv'));
fprintf('Adapted %d landmarks, reprojection RMS %.6f px, input cutoff %.6f s.\n', ...
    size(X,1),sqrt(mean(dn.^2)),t);
end
