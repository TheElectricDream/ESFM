function result = test_reconstruction_gold(output_root)
% Full real-data regression, intentionally using the complete original interval.
% Compares numerical results rather than accepting a visually similar cloud.
% This takes several minutes and requires the recording and MATLAB toolboxes.
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
if nargin < 1
    output_root = fullfile(root, 'experiments', 'reconstruction_gold_20260915', 'validation');
end
options = struct('output_root', output_root, 'make_figures', true);
result = main_reconstruction_gold(options);
reference = load(fullfile(root, 'output_golden', 'result.mat'), 'result');
reference = reference.result;
for name = {'X','ids','O','traj','nobs','log'}
    field = name{1};
    assert(isequaln(result.(field), reference.(field)), ...
        'The standalone reconstruction differs from main_gold in field %s.', field);
    fprintf('PASS exact reference agreement: %s\n', field);
end
assert(all(result.observations(:,2) >= 1 & result.observations(:,2) <= size(result.X,1)));
assert(isequal(result.ids(result.observations(:,2)), result.O(:,2)));

% Check exported rotations and scale using direct matrix projection,
% independently of the internal batched projection helper.
for index = [1 round(numel(result.pose.time_s)/2) numel(result.pose.time_s)]
    R = result.pose.R(:,:,index);
    assert(norm(R'*R-eye(3),'fro') < 1e-12 && abs(det(R)-1) < 1e-12);
    camera_points = result.X*R' + result.pose.T_model(index,:);
    metric_points = result.X_m*R' + result.pose.T_m(index,:);
    uv_model = camera_points(:,1:2)./camera_points(:,3).*result.camera.focal + result.camera.principal;
    uv_metric = metric_points(:,1:2)./metric_points(:,3).*result.camera.focal + result.camera.principal;
    assert(max(abs(uv_model-uv_metric),[],'all') < 1e-9, 'Metric scaling changed image projections.');
end
P = readtable(fullfile(result.run_dir, 'reconstruction_poses.csv'));
assert(height(P) == numel(result.pose.time_s));
assert(max(abs(P.tx_m-result.pose.T_m(:,1))) < 1e-10);
assert(max(abs(P.R12-squeeze(result.pose.R(1,2,:)))) < 1e-10);
assert(isfile(fullfile(result.run_dir,'cloud_model_units.ply')));
assert(isfile(fullfile(result.run_dir,'cloud_m.ply')));
assert(isfile(fullfile(result.run_dir,'fig_cloud.png')));
assert(isfile(fullfile(result.run_dir,'fig_pose.png')));
fprintf('PASS: point-ID remapping, proper rotations, metric projection invariance, CSV/PLY/figure exports.\n');
fprintf('Validated standalone result: %s\n', result.run_dir);
end
