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
