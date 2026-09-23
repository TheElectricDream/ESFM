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
flow_direction = geom.unit_rows(normal_flow);
event_count = size(warped_pixels, 1);
    function [projected_pixels, Y, predicted_flow] = predict(tr)
        [Rf, Tf] = traj.pose(tr, reference_time);
        Rf = geom.select_entries(Rf, ones(numel(active_ids), 1));
        [projected_pixels, Y] = geom.project_points(Rf, repmat(Tf, numel(active_ids), 1), landmarks(active_ids, :), settings.focal, settings.principal);
        [Rp, Tp] = traj.pose(tr, reference_time + 0.05);
        [Rm, Tm] = traj.pose(tr, reference_time - 0.05);
        up = geom.project_points(geom.select_entries(Rp, ones(numel(active_ids), 1)), repmat(Tp, numel(active_ids), 1), landmarks(active_ids, :), settings.focal, settings.principal);
        um = geom.project_points(geom.select_entries(Rm, ones(numel(active_ids), 1)), repmat(Tm, numel(active_ids), 1), landmarks(active_ids, :), settings.focal, settings.principal);
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
        map.traj = adjust.refine_motion_and_structure(trajectory, landmarks, recent_observations, traj.select_free_parameters(trajectory, false, reference_time, reference_time - settings.local_win, settings.free_V), [], settings.knot_iters, adjustment_settings);
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
           abs(traj.angle(trajectory, edges(history_edge_indices(end))) - traj.angle(trajectory, edges(history_edge_indices(1)))) >= settings.cand_min_turn
            [Rs, Ts] = traj.pose(trajectory, edges(history_edge_indices));
            sample_count = size(history, 1);
            [new_point, point_covariance] = geom.triangulate_points(Rs, Ts, ones(sample_count, 1), history(:, 2:3), history(:, 4:5), 1, settings.eps, settings.focal, settings.principal);
            [pr, Y] = geom.project_points(Rs, Ts, repmat(new_point, sample_count, 1), settings.focal, settings.principal);
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
