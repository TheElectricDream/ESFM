function [pixel, Y] = project_points(R, T, landmarks, focal, principal)
% Perspective projection: u=fx*Xc/Zc+cx, v=fy*Yc/Zc+cy.
% The denominator floor avoids division by zero. Positive-depth acceptance
% is handled separately in initialization, promotion and residual evaluation.
Y = geom.apply_pose(R, T, landmarks);
z = max(Y(:, 3), 1e-6);
pixel = focal .* Y(:, 1:2) ./ z + principal;
end
