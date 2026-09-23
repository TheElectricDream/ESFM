function varargout = gold_kernel_reference(name, varargin)
% Unmodified local kernels extracted from the supplied gold script.
switch name
    case 'unit_rows'
        [varargout{1:nargout}] = unit_rows(varargin{:});
    case 'rodrigues_entries'
        [varargout{1:nargout}] = rodrigues_entries(varargin{:});
    case 'select_entries'
        [varargout{1:nargout}] = select_entries(varargin{:});
    case 'apply_pose'
        [varargout{1:nargout}] = apply_pose(varargin{:});
    case 'project_points'
        [varargout{1:nargout}] = project_points(varargin{:});
    case 'triangulate_points'
        [varargout{1:nargout}] = triangulate_points(varargin{:});
    case 'axis_tangent'
        [varargout{1:nargout}] = axis_tangent(varargin{:});
    case 'create_trajectory'
        [varargout{1:nargout}] = create_trajectory(varargin{:});
    case 'spline_basis'
        [varargout{1:nargout}] = spline_basis(varargin{:});
    case 'spline_eval'
        [varargout{1:nargout}] = spline_eval(varargin{:});
    case 'spline_active'
        [varargout{1:nargout}] = spline_active(varargin{:});
    case 'increment_trajectory'
        [varargout{1:nargout}] = increment_trajectory(varargin{:});
    case 'select_free_parameters'
        [varargout{1:nargout}] = select_free_parameters(varargin{:});
    case 'trajectory_angle'
        [varargout{1:nargout}] = trajectory_angle(varargin{:});
    case 'trajectory_translation'
        [varargout{1:nargout}] = trajectory_translation(varargin{:});
    case 'trajectory_pose'
        [varargout{1:nargout}] = trajectory_pose(varargin{:});
    case 'trajectory_rate_deg_s'
        [varargout{1:nargout}] = trajectory_rate_deg_s(varargin{:});
    case 'refine_motion_and_structure'
        [varargout{1:nargout}] = refine_motion_and_structure(varargin{:});
    case 'edge_normal_residuals'
        [varargout{1:nargout}] = edge_normal_residuals(varargin{:});
    case 'process_reconstruction_slice'
        [varargout{1:nargout}] = process_reconstruction_slice(varargin{:});
    case 'calibrate_model_scale'
        [varargout{1:nargout}] = calibrate_model_scale(varargin{:});
    case 'sample_refined_trajectory'
        [varargout{1:nargout}] = sample_refined_trajectory(varargin{:});
    case 'export_reconstruction'
        [varargout{1:nargout}] = export_reconstruction(varargin{:});
    case 'write_ply'
        [varargout{1:nargout}] = write_ply(varargin{:});
    otherwise
        error('Unknown reference kernel: %s', name);
end
end

function u = unit_rows(v)
u = v ./ max(vecnorm(v, 2, 2), 1e-12);
end

function R = rodrigues_entries(axis_unit, theta)
% Rodrigues' formula: R(theta) = cos(theta) I + sin(theta)[a]_x
%                                + (1-cos(theta)) a*a'.
% Store each entry as a vector to project all observation poses together;
% this avoids a loop that constructs thousands of individual 3-by-3 matrices.
% Entries of R = cos I + sin [a]_x + (1 - cos) a a', one array per entry.
a1 = axis_unit(1);
a2 = axis_unit(2);
a3 = axis_unit(3);
c = cos(theta);
s = sin(theta);
v = 1 - c;
R.r11 = c + v*a1*a1;
R.r12 = v*a1*a2 - s*a3;
R.r13 = v*a1*a3 + s*a2;
R.r21 = v*a2*a1 + s*a3;
R.r22 = c + v*a2*a2;
R.r23 = v*a2*a3 - s*a1;
R.r31 = v*a3*a1 - s*a2;
R.r32 = v*a3*a2 + s*a1;
R.r33 = c + v*a3*a3;
end

function Rs = select_entries(R, idx)
Rs = structfun(@(e) e(idx), R, 'UniformOutput', false);
end

function Y = apply_pose(R, T, landmarks)
% Y = R X + T per row (R entry arrays of length M, T (M x 3), X (M x 3))
Y = [R.r11.*landmarks(:,1) + R.r12.*landmarks(:,2) + R.r13.*landmarks(:,3) + T(:,1), ...
     R.r21.*landmarks(:,1) + R.r22.*landmarks(:,2) + R.r23.*landmarks(:,3) + T(:,2), ...
     R.r31.*landmarks(:,1) + R.r32.*landmarks(:,2) + R.r33.*landmarks(:,3) + T(:,3)];
end

function [pixel, Y] = project_points(R, T, landmarks, focal, principal)
% Perspective projection: u=fx*Xc/Zc+cx, v=fy*Yc/Zc+cy.
% The denominator floor avoids division by zero. Positive-depth acceptance
% is handled separately in initialization, promotion and residual evaluation.
Y = apply_pose(R, T, landmarks);
z = max(Y(:, 3), 1e-6);
pixel = focal .* Y(:, 1:2) ./ z + principal;
end

function [landmarks, covariance_proxy] = triangulate_points(R, T, landmark_id, observed_pixels, image_normal, point_count, tangent_weight, focal, principal)
% For normalized pixel m=(u-c)/f, rearrange perspective projection into
%   (m_x*r3-r1) X = T_x-m_x*T_z,
%   (m_y*r3-r2) X = T_y-m_y*T_z.
% Combine these two equations along the image normal and its perpendicular.
% The tangential ROW is multiplied by 0.15, so its squared information weight
% is 0.0225. Accumulate one 3-by-3 least-squares system per landmark.
% RETAINED APPROXIMATION: image normals are applied directly to normalized
% coordinate rows without an fx/fy correction. The original focal lengths
% are close, but this is not exact for an arbitrarily anisotropic camera.
% The ridge 1e-9 prevents a singular solve. The covariance output is a
% residual-scaled inverse normal matrix: a promotion heuristic, not calibrated
% uncertainty in metres. No new independent speed residual is introduced.
normalized_pixels = (observed_pixels - principal) ./ focal;
A1 = [normalized_pixels(:,1).*R.r31 - R.r11, normalized_pixels(:,1).*R.r32 - R.r12, normalized_pixels(:,1).*R.r33 - R.r13];
A2 = [normalized_pixels(:,2).*R.r31 - R.r21, normalized_pixels(:,2).*R.r32 - R.r22, normalized_pixels(:,2).*R.r33 - R.r23];
b1 = T(:,1) - normalized_pixels(:,1).*T(:,3);
b2 = T(:,2) - normalized_pixels(:,2).*T(:,3);
normal_matrices = zeros(point_count, 3, 3);
normal_rhs = zeros(point_count, 3);
rows = cell(2, 1);
rhs = cell(2, 1);
directions = {image_normal, [-image_normal(:,2) image_normal(:,1)]};
weights = [1 tangent_weight];
for pass = 1:2
    d = directions{pass};
    w = weights(pass);
    r = w * (d(:,1) .* A1 + d(:,2) .* A2);
    s = w * (d(:,1) .* b1 + d(:,2) .* b2);
    rows{pass} = r;
    rhs{pass} = s;
    for a = 1:3
        normal_rhs(:, a) = normal_rhs(:, a) + accumarray(landmark_id, r(:, a) .* s, [point_count 1]);
        for b = 1:3
            normal_matrices(:, a, b) = normal_matrices(:, a, b) + accumarray(landmark_id, r(:, a) .* r(:, b), [point_count 1]);
        end
    end
end
landmarks = zeros(point_count, 3);
for i = 1:point_count
    landmarks(i, :) = ((squeeze(normal_matrices(i, :, :)) + 1e-9 * eye(3)) \ normal_rhs(i, :)')';
end
if nargout > 1
    residual = [sum(rows{1} .* landmarks(landmark_id, :), 2) - rhs{1}; sum(rows{2} .* landmarks(landmark_id, :), 2) - rhs{2}];
    residual_variance = (residual' * residual) / max(numel(residual) - 3 * point_count, 1);
    covariance_proxy = zeros(point_count, 3, 3);
    for i = 1:point_count
        covariance_proxy(i, :, :) = residual_variance * inv(squeeze(normal_matrices(i, :, :)) + 1e-9 * eye(3));
    end
end
end

function [t1, t2] = axis_tangent(a)
if abs(a(1)) < 0.9
    t1 = cross(a(:), [1; 0; 0]);
else
    t1 = cross(a(:), [0; 1; 0]);
end
t1 = t1 / norm(t1);
t2 = cross(a(:), t1);
end

function trajectory = create_trajectory(t0, t1, h)
% The object-to-camera model is
%   theta(t) = omega*(t-t0) + sum_j B_j(t)*k_j,
%   T(t) = [c_x,c_y,1] + (t-t0)*V + sum_j B_j(t)*m_j.
% a: 3x1 fixed unit rotation axis; omega: mean angular rate [rad/s].
% c: 1x2 initial lateral position; V: 1x3 mean velocity [model units/s].
% k: Kx1 angular correction knots [rad]; m: Kx3 translation correction knots.
% t0: recording-relative reference time; h: knot spacing [s]; K: knot count.
% Initial depth 1 fixes monocular scale. Axis-centroid regularization chooses
% part of the origin gauge; it does not identify the physical centre of mass.
% Parameter order: [axis_tangent_1, axis_tangent_2, omega, cx, cy, Vx,Vy,Vz,
%                   k_1...k_K, mx_1,my_1,mz_1,...,mx_K,my_K,mz_K].
trajectory.t0 = t0;
trajectory.h = h;
trajectory.n_seg = ceil((t1 - t0) / h) + 2;
trajectory.K = trajectory.n_seg + 3;
trajectory.knot_t = t0 + h * ((0:trajectory.K - 1)' - 1);
trajectory.a = [0; -1; 0];
trajectory.omega = 0.1;
trajectory.c = [0 0];
trajectory.V = [0 0 0];
trajectory.k = zeros(trajectory.K, 1);
trajectory.m = zeros(trajectory.K, 3);
end

function [idx, val] = spline_basis(trajectory, t)
% Uniform cubic B-splines have only four nonzero weights per observation.
% For fractional segment coordinate s, those weights are
% [(1-s)^3, 3s^3-6s^2+4, -3s^3+3s^2+3s+1, s^3] / 6.
% idx stores the four supporting knot indices. The padded ends and limited
% extrapolation reproduce the reference boundary convention.
% idx (M x 4) control indices (1-based) and val (M x 4) weights; the last
% segment is extrapolated beyond the ends.
u = (t(:) - trajectory.t0) / trajectory.h;
j = min(max(floor(u), 0), trajectory.n_seg - 1);
s = min(max(u - j, -0.5), 1.5);
val = [(1 - s).^3, 3*s.^3 - 6*s.^2 + 4, -3*s.^3 + 3*s.^2 + 3*s + 1, s.^3] / 6;
idx = j + (1:4);
end

function out = spline_eval(trajectory, t, coef)
[idx, val] = spline_basis(trajectory, t);
out = zeros(numel(t), size(coef, 2));
for q = 1:4
    out = out + val(:, q) .* coef(idx(:, q), :);
end
end

function j = spline_active(trajectory, ta, tb)
[ia, ~] = spline_basis(trajectory, ta);
[ib, ~] = spline_basis(trajectory, tb);
j = (ia(1, 1) : ib(1, 4))';
end

function trajectory = increment_trajectory(trajectory, p)
% Perturb the axis in its two-dimensional tangent plane, then normalize.
% Add the remaining increments in the parameter order documented above.
% This is an update of fixed-axis trajectory parameters, not a free SE(3) pose.
[t1, t2] = axis_tangent(trajectory.a);
a = trajectory.a(:) + p(1) * t1 + p(2) * t2;
trajectory.a = a / norm(a);
trajectory.omega = trajectory.omega + p(3);
trajectory.c = trajectory.c + p(4:5)';
trajectory.V = trajectory.V + p(6:8)';
K = trajectory.K;
trajectory.k = trajectory.k + p(9:8 + K);
trajectory.m = trajectory.m + reshape(p(9 + K:end), 3, [])';
end

function cols = select_free_parameters(trajectory, mean_free, knots_upto, knots_from, free_V)
% Return parameter indices that a refinement call is allowed to change.
% A local call freezes mean motion and releases only active spline knots.
% A global call releases mean motion plus the selected knots. free_V=false
% keeps the mean velocity at zero while allowing translation spline motion.
% Column indices (1-based) of the 8 mean parameters and/or the knots whose
% support lies in [knots_from, knots_upto].
if mean_free
    if free_V
        cols = 1:8;
    else
        cols = 1:5;
    end
else
    cols = [];
end
if ~isempty(knots_upto)
    if isempty(knots_from)
        knots_from = trajectory.t0;
    end
    j = spline_active(trajectory, knots_from, knots_upto);
    cols = [cols, (8 + j)', reshape((8 + trajectory.K + 3 * (j - 1) + (1:3))', 1, [])];
end
cols = cols(:);
end

function theta = trajectory_angle(trajectory, t)
theta = trajectory.omega * (t(:) - trajectory.t0) + spline_eval(trajectory, t, trajectory.k);
end

function T = trajectory_translation(trajectory, t)
T = [trajectory.c 1] + (t(:) - trajectory.t0) * trajectory.V + spline_eval(trajectory, t, trajectory.m);
end

function [R, T] = trajectory_pose(trajectory, t)
R = rodrigues_entries(trajectory.a, trajectory_angle(trajectory, t));
T = trajectory_translation(trajectory, t);
end

function rate = trajectory_rate_deg_s(trajectory, t)
d = 0.05;
rate = rad2deg(trajectory_angle(trajectory, t(:) + d) - trajectory_angle(trajectory, t(:) - d)) / (2 * d);
end

function [trajectory, landmarks, info] = refine_motion_and_structure(trajectory, landmarks, observations, free_parameters, free_landmarks, max_iterations, settings)
% Optimize selected motion parameters and selected landmark coordinates.
% All other parameters/points still contribute residuals but remain fixed.
% For observation error d = observed_pixel - projected_pixel:
%   r_n = n' d / sigma; r_t = epsilon * n_perpendicular' d / sigma.
% Each scalar data residual uses Cauchy cost c^2*log(1+r^2/c^2).
% Priors stay quadratic: angular/translation second differences, weak knot
% pull toward zero, initial-pose gauges, and axial landmark centroid.
% These are soft numerical regularizers, not an exact rigid-body dynamics law.
%
% The LM step solves (J' W J + damping*D) delta = -J' W r. A step is accepted
% only when the full robust objective decreases; otherwise increase damping.
% Sparse triplets below assemble only requested parameter columns. Rotation
% axis columns use finite differences; other columns are analytic.
%
% REFERENCE APPROXIMATIONS, deliberately retained for reproducibility:
% 1. Invalid-depth image residuals are clamped to 10, but analytic image
%    Jacobian rows are not zeroed there. Avoid interpreting that Jacobian as
%    exact in the invalid-depth region.
% 2. Axial-centroid landmark coefficients are built at the axis on entry to
%    this refinement call and remain fixed during its iterations. The axis
%    derivative itself is included through the finite-difference columns.
% The full real-data parity test checks the resulting estimator, including
% these choices. They are explicit review points for a future mathematical fix.
info = struct('cost', nan, 'rms', nan);
free_landmarks = free_landmarks(:);
observation_times = observations(:, 1);
landmark_ids = observations(:, 2);
measured_pixels = observations(:, 3:4);
image_normals = unit_rows(observations(:, 5:6));
observation_count = size(observations, 1);
knot_count = trajectory.K;
knot_spacing_s = trajectory.h;
trajectory_parameter_count = 8 + 4 * knot_count;
landmark_count = size(landmarks, 1);
free_motion_count = numel(free_parameters);
free_parameter_count = free_motion_count + 3 * numel(free_landmarks);
if free_parameter_count == 0 || observation_count == 0
    return;
end
weighted_normals = image_normals / settings.sigma; % [n' ; eps e'] / sigma
weighted_tangents = settings.eps * [-image_normals(:, 2), image_normals(:, 1)] / settings.sigma;
radians_to_degrees = 180 / pi;
model_to_permille = 1000;
parameter_to_column = zeros(trajectory_parameter_count + 3 * landmark_count, 1);
parameter_to_column(free_parameters) = 1:free_motion_count;
for d = 1:3
    parameter_to_column(trajectory_parameter_count + 3 * (free_landmarks - 1) + d) = free_motion_count + 3 * (0:numel(free_landmarks) - 1)' + d;
end
[initial_basis_indices, initial_basis_values] = spline_basis(trajectory, trajectory.t0);
[basis_indices, basis_values] = spline_basis(trajectory, observation_times);
tau = observation_times - trajectory.t0;
fx = settings.focal(1);
fy = settings.focal(2);
image_residual_count = 2 * observation_count;
residual_count = image_residual_count + (knot_count - 2) + 3 * (knot_count - 2) + knot_count + 3 * knot_count + 1 + 3 + 1;
% Build prior rows in the same order as evaluate_residual; capture the entry axis.
reference_axis = trajectory.a;
[J_prior_rows, J_prior_cols, J_prior_vals] = assemble_prior_jacobian();

cauchy_scale_squared = (settings.cauchy / settings.sigma)^2;
r = evaluate_residual(trajectory, landmarks);
cost = robust_cost(r);
damping = settings.damping0;
if settings.fd_check
    check_jacobian(trajectory, landmarks, r);
end
for iteration = 1:max_iterations
    J = assemble_jacobian(trajectory, landmarks, r);
    sqrt_weights = ones(residual_count, 1);
    sqrt_weights(1:image_residual_count) = 1 ./ sqrt(1 + r(1:image_residual_count).^2 / cauchy_scale_squared);
    weighted_jacobian = spdiags(sqrt_weights, 0, residual_count, residual_count) * J;
    normal_matrix = weighted_jacobian' * weighted_jacobian;
    gradient = weighted_jacobian' * (r .* sqrt_weights);
    damping_diagonal = spdiags(max(diag(normal_matrix), 1e-9), 0, free_parameter_count, free_parameter_count);
    accepted = false;
    for attempt = 1:6
        d = -(normal_matrix + damping * damping_diagonal) \ gradient;
        [trial_trajectory, trial_landmarks] = apply_parameter_step(trajectory, landmarks, d);
        trial_residual = evaluate_residual(trial_trajectory, trial_landmarks);
        trial_cost = robust_cost(trial_residual);
        if trial_cost < cost
            trajectory = trial_trajectory;
            landmarks = trial_landmarks;
            r = trial_residual;
            cost = trial_cost;
            damping = damping / 3;
            accepted = true;
            break
        end
        damping = damping * 4;
    end
    if ~accepted
        break;
    end
    if norm(d) < 1e-8
        break;
    end
end
info.cost = cost;
info.rms = sqrt(mean((r(1:2:image_residual_count) * settings.sigma).^2));

    function r = evaluate_residual(tr, Xp)
        th = tr.omega * tau + sum(basis_values .* tr.k(basis_indices), 2);
        T = [tr.c 1] + tau * tr.V + [sum(basis_values .* reshape(tr.m(basis_indices, 1), observation_count, 4), 2), ...
                                     sum(basis_values .* reshape(tr.m(basis_indices, 2), observation_count, 4), 2), ...
                                     sum(basis_values .* reshape(tr.m(basis_indices, 3), observation_count, 4), 2)];
        R = rodrigues_entries(tr.a, th);
        [pr, Y] = project_points(R, T, Xp(landmark_ids, :), settings.focal, settings.principal);
        dd = measured_pixels - pr;
        rn = sum(weighted_normals .* dd, 2);
        rt = sum(weighted_tangents .* dd, 2);
        bad = Y(:, 3) < settings.min_depth;
        rn(bad) = 10;
        rt(bad) = 10;
        r_img = reshape([rn rt]', [], 1);
        k = tr.k;
        m = tr.m;
        % Residual blocks, in order: image observations; angular curvature;
        % translation curvature; angular knot pull; translation knot pull;
        % zero initial angular correction; zero initial translation correction;
        % landmark centroid projected onto the rotation axis.
        r = [r_img;
             settings.lam_th * radians_to_degrees * (k(3:end) - 2 * k(2:end-1) + k(1:end-2)) / knot_spacing_s^2;
             settings.lam_T * model_to_permille * reshape((m(3:end, :) - 2 * m(2:end-1, :) + m(1:end-2, :))', [], 1) / knot_spacing_s^2;
             settings.pull * settings.lam_th * radians_to_degrees * k;
             settings.pull * settings.lam_T * model_to_permille * reshape(m', [], 1);
             settings.gauge * (initial_basis_values * k(initial_basis_indices'));
             settings.gauge * (initial_basis_values * m(initial_basis_indices', :))';
             settings.centroid * (tr.a(:)' * mean(Xp, 1)')];
    end

    function c = robust_cost(rr)
        c = sum(cauchy_scale_squared * log1p(rr(1:image_residual_count).^2 / cauchy_scale_squared)) + sum(rr(image_residual_count+1:end).^2);
    end

    function [tr, Xp] = apply_parameter_step(tr, Xp, d)
        dp = zeros(trajectory_parameter_count, 1);
        dp(free_parameters) = d(1:free_motion_count);
        tr = increment_trajectory(tr, dp);
        Xp(free_landmarks, :) = Xp(free_landmarks, :) + reshape(d(free_motion_count+1:end), 3, [])';
    end

    function [rows, cols, vals] = assemble_prior_jacobian()
        rows = {};
        cols = {};
        vals = {};
        row = image_residual_count;
        j = (1:knot_count-2)';
        stencil = [1 -2 1];
        for stencil_index = 1:3
            rows{end+1} = row + j;
            cols{end+1} = 8 + j + stencil_index - 1;
            vals{end+1} = repmat(stencil(stencil_index) * settings.lam_th * radians_to_degrees / knot_spacing_s^2, knot_count-2, 1); %#ok<AGROW>
            for coordinate = 1:3
                rows{end+1} = row + (knot_count-2) + 3*(j-1) + coordinate;
                cols{end+1} = 8 + knot_count + 3*(j + stencil_index - 2) + coordinate; %#ok<AGROW>
                vals{end+1} = repmat(stencil(stencil_index) * settings.lam_T * model_to_permille / knot_spacing_s^2, knot_count-2, 1); %#ok<AGROW>
            end
        end
        row = row + 4 * (knot_count - 2);
        j = (1:knot_count)';
        rows{end+1} = row + j;
        cols{end+1} = 8 + j;
        vals{end+1} = repmat(settings.pull * settings.lam_th * radians_to_degrees, knot_count, 1);
        for coordinate = 1:3
            rows{end+1} = row + knot_count + 3*(j-1) + coordinate;
            cols{end+1} = 8 + knot_count + 3*(j-1) + coordinate;
            vals{end+1} = repmat(settings.pull * settings.lam_T * model_to_permille, knot_count, 1); %#ok<AGROW>
        end
        row = row + 4 * knot_count;
        rows{end+1} = repmat(row + 1, 4, 1);
        cols{end+1} = 8 + initial_basis_indices';
        vals{end+1} = settings.gauge * initial_basis_values';
        for coordinate = 1:3
            rows{end+1} = repmat(row + 1 + coordinate, 4, 1);
            cols{end+1} = 8 + knot_count + 3*(initial_basis_indices' - 1) + coordinate;
            vals{end+1} = settings.gauge * initial_basis_values'; %#ok<AGROW>
        end
        row = row + 4;
        for coordinate = 1:3
            rows{end+1} = repmat(row + 1, landmark_count, 1);
            cols{end+1} = trajectory_parameter_count + 3*(0:landmark_count-1)' + coordinate; %#ok<AGROW>
            vals{end+1} = repmat(settings.centroid * reference_axis(coordinate) / landmark_count, landmark_count, 1); %#ok<AGROW>
        end
        rows = vertcat(rows{:});
        cols = vertcat(cols{:});
        vals = vertcat(vals{:});
    end

    function J = assemble_jacobian(tr, Xp, r0)
        th = tr.omega * tau + sum(basis_values .* tr.k(basis_indices), 2);
        T = [tr.c 1] + tau * tr.V + [sum(basis_values .* reshape(tr.m(basis_indices, 1), observation_count, 4), 2), ...
                                     sum(basis_values .* reshape(tr.m(basis_indices, 2), observation_count, 4), 2), ...
                                     sum(basis_values .* reshape(tr.m(basis_indices, 3), observation_count, 4), 2)];
        R = rodrigues_entries(tr.a, th);
        Y = apply_pose(R, T, Xp(landmark_ids, :));
        z = max(Y(:, 3), 1e-6);
        % BA = B * dproj (2 x 3 per observation), already / sigma and eps
        BA1 = [weighted_normals(:,1)*fx./z, weighted_normals(:,2)*fy./z, -(weighted_normals(:,1)*fx.*Y(:,1) + weighted_normals(:,2)*fy.*Y(:,2))./z.^2];
        BA2 = [weighted_tangents(:,1)*fx./z, weighted_tangents(:,2)*fy./z, -(weighted_tangents(:,1)*fx.*Y(:,1) + weighted_tangents(:,2)*fy.*Y(:,2))./z.^2];
        Pp = Y - T; % R X
        a = tr.a(:);
        Pxa = [Pp(:,2)*a(3) - Pp(:,3)*a(2), Pp(:,3)*a(1) - Pp(:,1)*a(3), Pp(:,1)*a(2) - Pp(:,2)*a(1)];
        Ja1 = sum(BA1 .* Pxa, 2);
        Ja2 = sum(BA2 .* Pxa, 2); % d r / d theta (left perturbation a dtheta)
        JX1 = -[BA1(:,1).*R.r11 + BA1(:,2).*R.r21 + BA1(:,3).*R.r31, ...
                BA1(:,1).*R.r12 + BA1(:,2).*R.r22 + BA1(:,3).*R.r32, ...
                BA1(:,1).*R.r13 + BA1(:,2).*R.r23 + BA1(:,3).*R.r33];
        JX2 = -[BA2(:,1).*R.r11 + BA2(:,2).*R.r21 + BA2(:,3).*R.r31, ...
                BA2(:,1).*R.r12 + BA2(:,2).*R.r22 + BA2(:,3).*R.r32, ...
                BA2(:,1).*R.r13 + BA2(:,2).*R.r23 + BA2(:,3).*R.r33];
        rid = (1:observation_count)';
        row_blocks = {};
        column_blocks = {};
        value_blocks = {};
        for q = 1:2
            if q == 1
                rows_q = 2*rid - 1;
                Ja = Ja1;
                JT = -BA1;
                JX = JX1;
            else
                rows_q = 2*rid;
                Ja = Ja2;
                JT = -BA2;
                JX = JX2;
            end
            row_blocks{end+1} = rows_q;
            column_blocks{end+1} = repmat(3, observation_count, 1);
            value_blocks{end+1} = Ja .* tau; % omega
            for d = 1:3
                row_blocks{end+1} = rows_q;
                column_blocks{end+1} = repmat(5 + d, observation_count, 1);
                value_blocks{end+1} = JT(:, d) .* tau; % V
                row_blocks{end+1} = rows_q;
                column_blocks{end+1} = trajectory_parameter_count + 3*(landmark_ids - 1) + d;
                value_blocks{end+1} = JX(:, d); % X_i
                if d < 3
                    row_blocks{end+1} = rows_q;
                    column_blocks{end+1} = repmat(3 + d, observation_count, 1);
                    value_blocks{end+1} = JT(:, d);
                end    % cx, cy
            end
            for b = 1:4
                row_blocks{end+1} = rows_q;
                column_blocks{end+1} = 8 + basis_indices(:, b);
                value_blocks{end+1} = Ja .* basis_values(:, b); % k_j
                for d = 1:3
                    row_blocks{end+1} = rows_q;
                    column_blocks{end+1} = 8 + knot_count + 3*(basis_indices(:, b) - 1) + d;
                    value_blocks{end+1} = JT(:, d) .* basis_values(:, b); % m_j
                end
            end
        end
        for cidx = 1:2                                   % axis: two finite-difference columns
            dp = zeros(trajectory_parameter_count, 1);
            dp(cidx) = 1e-6;
            col = (evaluate_residual(increment_trajectory(tr, dp), Xp) - r0) / 1e-6;
            nz = find(col);
            row_blocks{end+1} = nz;
            column_blocks{end+1} = repmat(cidx, numel(nz), 1);
            value_blocks{end+1} = col(nz);
        end
        rows = [vertcat(row_blocks{:}); J_prior_rows];
        cols = [vertcat(column_blocks{:}); J_prior_cols];
        vals = [vertcat(value_blocks{:}); J_prior_vals];
        keep = parameter_to_column(cols) > 0;
        J = sparse(rows(keep), parameter_to_column(cols(keep)), vals(keep), residual_count, free_parameter_count);
    end

    function check_jacobian(tr, Xp, r0)
        J_an = full(assemble_jacobian(tr, Xp, r0));
        max_cols = min(free_parameter_count, free_motion_count + 30);
        hh = 1e-6;
        J_num = zeros(residual_count, max_cols);
        for q = 1:max_cols
            d = zeros(free_parameter_count, 1);
            d(q) = hh;
            [trp, Xpp] = apply_parameter_step(tr, Xp, d);
            [trm, Xpm] = apply_parameter_step(tr, Xp, -d);
            J_num(:, q) = (evaluate_residual(trp, Xpp) - evaluate_residual(trm, Xpm)) / (2 * hh);
        end
        fprintf('Jacobian finite-difference check (h = %.0e, %d of %d columns):\n', hh, max_cols, free_parameter_count);
        labels = {'axis (FD)', 'omega', 'c', 'V', 'k knots', 'm knots', 'points'};
        ranges = {1:2, 3, 4:5, 6:8, 8 + (1:knot_count), 8 + knot_count + (1:3*knot_count), trajectory_parameter_count + (1:3*landmark_count)};
        for b = 1:numel(labels)
            sel = find(ismember([free_parameters; trajectory_parameter_count + reshape((3*(free_landmarks-1) + (1:3))', [], 1)], ranges{b}));
            sel = sel(sel <= max_cols);
            if isempty(sel)
                continue;
            end
            err = max(abs(J_an(:, sel) - J_num(:, sel)), [], 'all');
            scale = max(abs(J_num(:, sel)), [], 'all');
            fprintf('  %-10s max |dJ| %.3e relative to max |J| %.3e -> %.3e\n', labels{b}, err, scale, err / max(scale, 1e-300));
        end
    end
end

function dn = edge_normal_residuals(trajectory, landmarks, observations, focal, principal)
[R, T] = trajectory_pose(trajectory, observations(:, 1));
pr = project_points(R, T, landmarks(observations(:, 2), :), focal, principal);
dn = sum((observations(:, 3:4) - pr) .* observations(:, 5:6), 2);
end

function [map, info] = process_reconstruction_slice(slice_index, reference_time, event_time, event_x, event_y, normal_flow, map, edges, settings, adjustment_settings)
% This step still changes geometry AND motion during reconstruction.
% 1. Project current landmarks and estimate their predicted image velocities.
% 2. Warp events to the slice centre; claim them by normal/tangent distance,
%    compatible image-normal orientation, and signed motion direction.
% 3. Use enough unambiguous claims to trigger a correction of active knots.
% 4. Add observations, extend unmatched-event candidates, and triangulate
%    candidates that have enough samples and angular baseline.
% 5. Keep new points only if depth, reprojection and covariance-proxy gates pass.
% map.nrm stores 2D image normals, not object-frame 3D normals.
% RETAINED CHOICES: ambiguity gates the correction count, but ALL current
% claims enter that correction; a mature candidate is retired after its
% triangulation attempt even if it fails promotion.
% Predict from the trajectory, explain events by the map (position + orientation +
% direction of motion), correct the active knots (twice), track the unexplained
% events in 2-D and triangulate them once the trajectory has turned enough.
trajectory = map.traj;
landmarks = map.X;
active_ids = find(map.alive);
warped_pixels = [event_x - normal_flow(:, 1) .* (event_time - reference_time), event_y - normal_flow(:, 2) .* (event_time - reference_time)];
flow_direction = unit_rows(normal_flow);
event_count = size(warped_pixels, 1);
    function [projected_pixels, Y, predicted_flow] = predict(tr)
        [Rf, Tf] = trajectory_pose(tr, reference_time);
        Rf = select_entries(Rf, ones(numel(active_ids), 1));
        [projected_pixels, Y] = project_points(Rf, repmat(Tf, numel(active_ids), 1), landmarks(active_ids, :), settings.focal, settings.principal);
        [Rp, Tp] = trajectory_pose(tr, reference_time + 0.05);
        [Rm, Tm] = trajectory_pose(tr, reference_time - 0.05);
        up = project_points(select_entries(Rp, ones(numel(active_ids), 1)), repmat(Tp, numel(active_ids), 1), landmarks(active_ids, :), settings.focal, settings.principal);
        um = project_points(select_entries(Rm, ones(numel(active_ids), 1)), repmat(Tm, numel(active_ids), 1), landmarks(active_ids, :), settings.focal, settings.principal);
        predicted_flow = (up - um) / 0.1;
    end
rows = zeros(0, 6);
used = false(event_count, 1);
projected_pixels = zeros(numel(active_ids), 2);
found = false(numel(active_ids), 1);
for it = 1:2
    [projected_pixels, ~, predicted_flow] = predict(trajectory);
    used = false(event_count, 1);
    rows = zeros(0, 6);
    mature = [];
    ratio = [];
    inside = projected_pixels(:, 1) > -20 & projected_pixels(:, 1) < settings.image_size(1) + 20 & projected_pixels(:, 2) > -20 & projected_pixels(:, 2) < settings.image_size(2) + 20;
    previous_normals = map.nrm(active_ids, :);
    ambiguous = false(numel(active_ids), 1);
    visible_ids = find(inside);
    if numel(visible_ids) > 1                                   % ambiguity: coinciding predicted edge lines
        pairs = rangesearch(projected_pixels(visible_ids, :), projected_pixels(visible_ids, :), settings.gate_t);
        for pk = 1:numel(visible_ids)
            k = visible_ids(pk);
            for l = visible_ids(pairs{pk}(pairs{pk} > pk))'
                dlt = projected_pixels(l, :) - projected_pixels(k, :);
                if abs(dlt * previous_normals(k, :)') < settings.gate_n && abs(previous_normals(k, :) * previous_normals(l, :)') > 0.5 && ...
                   (previous_normals(k, :) * predicted_flow(k, :)') * (previous_normals(k, :) * predicted_flow(l, :)') > 0
                    ambiguous(k) = true;
                    ambiguous(l) = true;
                end
            end
        end
    end
    if event_count > 0
        neighbors = rangesearch(warped_pixels, projected_pixels, settings.gate_t);
    else
        neighbors = repmat({zeros(1, 0)}, numel(active_ids), 1);
    end
    [~, order] = sort(map.nobs(active_ids), 'descend'); % well-observed points claim first
    for k = order'
        if ~inside(k)
            continue;
        end
        nearby_events = neighbors{k};
        nearby_events = nearby_events(~used(nearby_events));
        if numel(nearby_events) < 3
            continue;
        end
        pixel_error = warped_pixels(nearby_events, :) - projected_pixels(k, :);
        normal_error = sum(pixel_error .* flow_direction(nearby_events, :), 2);
        tangent_error = pixel_error(:, 1) .* flow_direction(nearby_events, 2) - pixel_error(:, 2) .* flow_direction(nearby_events, 1);
        ok = abs(normal_error) < settings.gate_n & abs(tangent_error) < settings.gate_t & (flow_direction(nearby_events, :) * predicted_flow(k, :)') > 0 & abs(flow_direction(nearby_events, :) * map.nrm(active_ids(k), :)') > 0.5;
        if nnz(ok) < 3
            continue;
        end
        claimed_ids = nearby_events(ok);
        used(claimed_ids) = true;
        mean_normal = mean(normal_flow(claimed_ids, :), 1);
        mean_normal = mean_normal / max(norm(mean_normal), 1e-12);
        map.nrm(active_ids(k), :) = mean_normal;
        rows(end+1, :) = [mean(event_time(claimed_ids)), active_ids(k), mean(event_x(claimed_ids)), mean(event_y(claimed_ids)), mean_normal]; %#ok<AGROW>
        mature(end+1) = ~ambiguous(k); %#ok<AGROW>
        if mature(end)
            ratio(end+1) = mean(flow_direction(claimed_ids, :) * predicted_flow(k, :)') / mean(vecnorm(normal_flow(claimed_ids, :), 2, 2));
        end  %#ok<AGROW>
    end
    found = ismember(active_ids, rows(:, 2));
    if ~isempty(ratio)
        map.ratio(end+1) = median(ratio);
    end
    if sum(mature) >= settings.min_mature && map.knots_free && it == 1      % correct the active knots with the last LOCAL_WIN s
        recent_observations = [map.O(map.O(:, 1) > reference_time - settings.local_win, :); rows];
        map.traj = refine_motion_and_structure(trajectory, landmarks, recent_observations, select_free_parameters(trajectory, false, reference_time, reference_time - settings.local_win, settings.free_V), [], settings.knot_iters, adjustment_settings);
        trajectory = map.traj;
    else
        break
    end
end
map.O = [map.O; rows];
for i = unique(rows(:, 2))'
    map.nobs(i) = map.nobs(i) + 1;
end
% new structure: 2-D candidate tracks on the unexplained events, triangulated once the trajectory has turned enough (03 s5)
unclaimed = find(~used);
candidate_claimed = false(numel(unclaimed), 1);
new_point_count = 0;
keep = struct('x', {}, 'y', {}, 'vx', {}, 'vy', {}, 'f', {}, 'hist', {}, 'miss', {});
if ~isempty(map.cand)
    prediction_interval = (slice_index - [map.cand.f]') * settings.dt;
    predicted_x = [map.cand.x]' + [map.cand.vx]' .* prediction_interval;
    predicted_y = [map.cand.y]' + [map.cand.vy]' .* prediction_interval;
    if ~isempty(unclaimed)
        candidate_neighbors = rangesearch(warped_pixels(unclaimed, :), [predicted_x predicted_y], settings.cand_gate);
    else
        candidate_neighbors = repmat({zeros(1, 0)}, numel(predicted_x), 1);
    end
    for candidate_index = 1:numel(map.cand)
        candidate = map.cand(candidate_index);
        nearby_events = candidate_neighbors{candidate_index};
        nearby_events = nearby_events(~candidate_claimed(nearby_events));
        if numel(nearby_events) >= 3
            candidate_claimed(nearby_events) = true;
            claimed_ids = unclaimed(nearby_events);
            measured_x = mean(warped_pixels(claimed_ids, 1));
            measured_y = mean(warped_pixels(claimed_ids, 2));
            candidate.vx = candidate.vx + 0.25 * (measured_x - predicted_x(candidate_index)) / prediction_interval(candidate_index);
            candidate.vy = candidate.vy + 0.25 * (measured_y - predicted_y(candidate_index)) / prediction_interval(candidate_index);
            candidate.x = predicted_x(candidate_index) + 0.6 * (measured_x - predicted_x(candidate_index));
            candidate.y = predicted_y(candidate_index) + 0.6 * (measured_y - predicted_y(candidate_index));
            candidate.f = slice_index;
            mean_normal = mean(normal_flow(claimed_ids, :), 1);
            mean_normal = mean_normal / max(norm(mean_normal), 1e-12);
            candidate.hist(end+1, :) = [slice_index, candidate.x, candidate.y, mean_normal];
            candidate.miss = 0;
        else
            candidate.miss = candidate.miss + 1;
        end
        if candidate.miss > settings.cand_max_miss
            continue;
        end
        history = candidate.hist;
        history_edge_indices = history(:, 1) + 1; % batch index -> edges index
        if size(history, 1) >= settings.cand_min_samples && ...
           abs(trajectory_angle(trajectory, edges(history_edge_indices(end))) - trajectory_angle(trajectory, edges(history_edge_indices(1)))) >= settings.cand_min_turn
            [Rs, Ts] = trajectory_pose(trajectory, edges(history_edge_indices));
            sample_count = size(history, 1);
            [new_point, point_covariance] = triangulate_points(Rs, Ts, ones(sample_count, 1), history(:, 2:3), history(:, 4:5), 1, settings.eps, settings.focal, settings.principal);
            [pr, Y] = project_points(Rs, Ts, repmat(new_point, sample_count, 1), settings.focal, settings.principal);
            normal_error = sum((history(:, 2:3) - pr) .* history(:, 4:5), 2);
            if min(Y(:, 3)) > settings.cand_min_depth && sqrt(mean(normal_error.^2)) < settings.cand_max_rms && ...
               sqrt(max(eig(squeeze(point_covariance(1, :, :))))) < settings.cov_gate                  % covariance gate
                i = size(map.X, 1) + 1;
                map.X(i, :) = new_point;
                map.O = [map.O; [edges(history_edge_indices)', repmat(i, sample_count, 1), history(:, 2:5)]];
                map.nobs(i) = sample_count;
                map.created(i) = slice_index;
                map.alive(i) = true;
                map.nrm(i, :) = history(end, 4:5);
                new_point_count = new_point_count + 1;
            end
            continue
        end
        keep(end+1) = candidate; %#ok<AGROW>
    end
end
remaining_events = unclaimed(~candidate_claimed);
if ~isempty(remaining_events)
    cell_xy = floor(warped_pixels(remaining_events, :) / settings.seed_cell);
    [~, ~, seed_id] = unique(cell_xy(:, 1) * 10000 + cell_xy(:, 2));
    seed_count = accumarray(seed_id, 1);
    for candidate = find(seed_count >= 3)'
        claimed_ids = remaining_events(seed_id == candidate);
        v = mean(normal_flow(claimed_ids, :), 1);
        keep(end+1) = struct('x', mean(warped_pixels(claimed_ids, 1)), 'y', mean(warped_pixels(claimed_ids, 2)), 'vx', v(1), 'vy', v(2), 'f', slice_index, ...
            'hist', [slice_index, mean(warped_pixels(claimed_ids, 1)), mean(warped_pixels(claimed_ids, 2)), v / max(norm(v), 1e-12)], 'miss', 0); %#ok<AGROW>
    end
end
map.cand = keep;
info = struct('uv', projected_pixels, 'found', found, 'used', used, 'e', warped_pixels, 'n_new', new_point_count);
end

function scale = calibrate_model_scale(points, original_ids, options)
% Scaling is a reporting step, never a change in the reconstructed shape.
% Known corresponding panel tips are preferable to a statistical cloud span.
scale = struct('known_width_m', options.known_width_m, ...
    'endpoint_ids', options.scale_endpoint_ids, 'provisional', false);
if isempty(options.scale_endpoint_ids)
    [~, ~, directions] = svd(points - mean(points, 1), 0);
    axis_vector = directions(:, 1);
    projected = sort(points * axis_vector);
    percentile_indices = 1 + (numel(projected) - 1) * [1 99] / 100;
    endpoints = interp1(1:numel(projected), projected, percentile_indices);
    span_model = endpoints(2) - endpoints(1);
    scale.method = 'provisional 1--99 percentile principal-axis span';
    scale.provisional = true;
    scale.axis = axis_vector;
    scale.percentiles = [1 99];
else
    requested = options.scale_endpoint_ids;
    assert(numel(requested) == 2 && requested(1) ~= requested(2), ...
        'Provide two distinct original panel-tip IDs.');
    [found, rows] = ismember(requested, original_ids);
    assert(all(found), 'A requested panel-tip ID is missing from the final cloud.');
    span_model = norm(points(rows(2), :) - points(rows(1), :));
    scale.method = 'specified panel-tip endpoints';
end
assert(isfinite(span_model) && span_model > 0, 'Cannot scale a zero or invalid cloud span.');
scale.span_model = span_model;
scale.m_per_unit = options.known_width_m / span_model;
end

function pose = sample_refined_trajectory(trajectory, time_s, metres_per_unit)
% Pose samples come from the FINAL optimized trajectory, not successive
% intermediate estimates. R(:,:,j) maps object coordinates into the camera.
[entries, translations] = trajectory_pose(trajectory, time_s);
count = numel(time_s);
rotation = zeros(3, 3, count);
for index = 1:count
    rotation(:, :, index) = [entries.r11(index) entries.r12(index) entries.r13(index); ...
                            entries.r21(index) entries.r22(index) entries.r23(index); ...
                            entries.r31(index) entries.r32(index) entries.r33(index)];
end
pose = struct('time_s', time_s, 'R', rotation, 'T_model', translations, ...
    'T_m', metres_per_unit * translations, ...
    'angle_rad', trajectory_angle(trajectory, time_s), ...
    'rate_deg_s', trajectory_rate_deg_s(trajectory, time_s), ...
    'convention', 'X_camera = R * X_object + T; column vectors');
end

function export_reconstruction(result)
folder = result.run_dir;
write_ply(fullfile(folder, 'cloud_model_units.ply'), result.X);
write_ply(fullfile(folder, 'cloud_m.ply'), result.X_m);
point_columns = [result.ids result.X result.X_m result.nobs];
point_names = {'original_id','x_model','y_model','z_model','x_m','y_m','z_m','observation_count'};
writetable(array2table(point_columns, 'VariableNames', point_names), fullfile(folder, 'landmarks.csv'));

pose = result.pose;
% MATLAB reshape stacks columns: R11,R21,R31,R12,... . Spell it out in CSV.
rotations = reshape(pose.R, 9, [])';
columns = [pose.time_s pose.T_model pose.T_m rotations pose.angle_rad pose.rate_deg_s];
names = {'time_s','tx_model','ty_model','tz_model','tx_m','ty_m','tz_m', ...
    'R11','R21','R31','R12','R22','R32','R13','R23','R33','angle_rad','rate_deg_s'};
writetable(array2table(columns, 'VariableNames', names), fullfile(folder, 'reconstruction_poses.csv'));

% Include both ID conventions so filtered points can be reprojected safely.
columns = [result.O(:,1:2) result.observations(:,2) result.O(:,3:6) result.normal_residual_px];
names = {'time_s','original_id','point_row','u_px','v_px','normal_u','normal_v','normal_residual_px'};
writetable(array2table(columns, 'VariableNames', names), fullfile(folder, 'observation_residuals.csv'));
end

function write_ply(path, points)
file = fopen(path, 'w');
assert(file > 0, 'Cannot open cloud output: %s', path);
cleanup = onCleanup(@() fclose(file));
fprintf(file, 'ply\nformat ascii 1.0\nelement vertex %d\n', size(points, 1));
fprintf(file, 'property double x\nproperty double y\nproperty double z\nend_header\n');
fprintf(file, '%.17g %.17g %.17g\n', points');
end
