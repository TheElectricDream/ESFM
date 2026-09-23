function checks = inspect_reconstruction(result)
% INSPECT_RECONSTRUCTION Inspect saved reconstruction and verify ID/pose wiring.
% Accepts the new result or the gold result; does not change either.
% Geometry is shown at its native gauge, without shape alignment or rescaling.
X = result.X;
O = result.observations; % compact IDs into X, NOT result.O's original IDs
assert(~isempty(X) && size(X,2)==3 && size(O,2)==6, 'Invalid result layout.');
assert(all(O(:,2)>=1 & O(:,2)<=size(X,1) & O(:,2)==round(O(:,2))), ...
    'Observation IDs do not index the filtered point cloud.');
[R,T] = traj.pose(result.traj,O(:,1));
[uv,Y] = geom.project_points(R,T,X(O(:,2),:),result.camera.focal,result.camera.principal);
dn = sum((O(:,3:4)-uv).*O(:,5:6),2);
rms_px = sqrt(mean(dn.^2));
[uv_m,~] = geom.project_points(R,T*result.scale.m_per_unit, ...
    result.X_m(O(:,2),:),result.camera.focal,result.camera.principal);
metric_error = max(abs(uv_m-uv),[],'all');
residual_error = max(abs(dn-result.normal_residual_px));
rotation_error = 0;
for i = 1:size(result.pose.R,3)
    Ri = result.pose.R(:,:,i);
    rotation_error = max([rotation_error,norm(Ri'*Ri-eye(3),'fro'),abs(det(Ri)-1)]);
end
checks = table(size(X,1),size(O,1),rms_px,residual_error,metric_error, ...
    rotation_error,min(Y(:,3)), ...
    'VariableNames',{'Points','Observations','NormalRMS_px', ...
    'StoredResidualError_px','MetricProjectionError_px','RotationError','MinDepth_model'});
disp(checks);
assert(residual_error<1e-7 && metric_error<1e-7 && rotation_error<1e-7, ...
    'A result-consistency check failed.');

f1 = figure('Color','w','Name','Reconstruction: seed, growth and final cloud', ...
    'Position',[50 50 1200 700]);
tiledlayout(2,3,'TileSpacing','compact');
nexttile;
if isfield(result.warm,'X')
    scatter3(result.warm.X(:,1),result.warm.X(:,2),result.warm.X(:,3),12,'filled');
    title('Seed from refined warm hypothesis');
else
    text(0.1,0.5,'Seed cloud not stored in this result');
end
axis equal; grid on; view(3); xlabel('X [model]'); ylabel('Y [model]'); zlabel('Z [model]');
nexttile;
if isfield(result.warm,'joint_X')
    Xw = result.warm.joint_X;
    scatter3(Xw(:,1),Xw(:,2),Xw(:,3),12,'filled');
    title('After joint warm adjustment');
else
    text(0.1,0.5,'Joint warm cloud not stored');
end
axis equal; grid on; view(3); xlabel('X [model]'); ylabel('Y [model]'); zlabel('Z [model]');
nexttile;
scatter3(X(:,1),X(:,2),X(:,3),12,result.nobs,'filled');
axis equal; grid on; view(3); colorbar;
xlabel('X [model]'); ylabel('Y [model]'); zlabel('Z [model]');
title(sprintf('Final cloud: %d points; colour = observations',size(X,1)));
nexttile;
plot(result.log(:,1),result.log(:,3),result.log(:,1),result.log(:,5));
grid on; xlabel('Time [s]'); ylabel('Count'); legend('Map points','Matched points');
title('Progressive map growth');
nexttile;
plot(result.log(:,1),100*result.log(:,4));
grid on; xlabel('Time [s]'); ylabel('Explained accepted events [%]');
title('Association coverage');
nexttile;
histogram(dn,60); grid on; xlabel('Normal residual [px]'); ylabel('Observations');
title(sprintf('Final normal RMS %.4f px',rms_px));

f2 = figure('Color','w','Name','Final refined trajectory','Position',[70 70 950 700]);
tiledlayout(3,1,'TileSpacing','compact');
nexttile; plot(result.pose.time_s,result.pose.T_m); grid on;
ylabel('Object origin [m]'); legend('Camera X','Camera Y','Camera Z');
title(sprintf('Final pose; provisional metric scale = %d',result.scale.provisional));
nexttile; plot(result.pose.time_s,rad2deg(result.pose.angle_rad)); grid on;
ylabel('Fixed-axis angle [deg]');
nexttile; plot(result.pose.time_s,result.pose.rate_deg_s); grid on;
ylabel('Angular rate [deg/s]'); xlabel('Time [s]');

% One time neighbourhood: use each observation's own pose for projection.
% This is an overlay of nearby observations, not an event-camera frame.
unique_times = unique(O(:,1));
t_mid = unique_times(round((numel(unique_times)+1)/2));
[~,idx] = sort(abs(O(:,1)-t_mid)); idx = idx(1:min(150,numel(idx)));
f3 = figure('Color','w','Name','Reprojection spot check');
plot(O(idx,3),O(idx,4),'k.','DisplayName','Measured'); hold on;
plot(uv(idx,1),uv(idx,2),'ro','MarkerSize',4,'DisplayName','Projected at its own time');
plot([O(idx,3) uv(idx,1)]',[O(idx,4) uv(idx,2)]','-','Color',[0.6 0.6 0.6], ...
    'HandleVisibility','off');
set(gca,'YDir','reverse'); axis equal; grid on; legend('Location','best');
xlabel('Undistorted u [px]'); ylabel('Undistorted v [px]');
title(sprintf('Nearby observations, %.3f to %.3f s',min(O(idx,1)),max(O(idx,1))));
if isfield(result,'run_dir') && exist(result.run_dir,'dir')
    exportgraphics(f1,fullfile(result.run_dir,'fig_reconstruction.png'),'Resolution',140);
    exportgraphics(f2,fullfile(result.run_dir,'fig_pose.png'),'Resolution',140);
    exportgraphics(f3,fullfile(result.run_dir,'fig_reprojection.png'),'Resolution',140);
end
end
