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
image_normals = geom.unit_rows(observations(:, 5:6));
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
[initial_basis_indices, initial_basis_values] = traj.spline_basis(trajectory, trajectory.t0);
[basis_indices, basis_values] = traj.spline_basis(trajectory, observation_times);
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
        R = geom.rodrigues_entries(tr.a, th);
        [pr, Y] = geom.project_points(R, T, Xp(landmark_ids, :), settings.focal, settings.principal);
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
        tr = traj.increment_trajectory(tr, dp);
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
        R = geom.rodrigues_entries(tr.a, th);
        Y = geom.apply_pose(R, T, Xp(landmark_ids, :));
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
            col = (evaluate_residual(traj.increment_trajectory(tr, dp), Xp) - r0) / 1e-6;
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
