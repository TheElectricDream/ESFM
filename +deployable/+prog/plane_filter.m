%-----%
function [flag, dist] = plane_filter(X_m, fcfg)
    %   This function flags landmarks that do not lie on the local surface
    %   of the cloud. For every landmark a plane is fitted to its
    %   neighbours within a radius (principal axes, with one trimming pass
    %   to shed outliers), and the landmark is flagged when it lies further
    %   from that plane than the tolerance. The panels and the bus faces
    %   are locally planar; a reflection of a lamp in the panel glass is a
    %   virtual point behind the surface and is caught here.
    %
    %   Inputs:
    %       X_M -> [N, 3], landmarks in metres
    %       FCFG -> Struct, filter parameters (cfg.filter): radius_m,
    %              min_neighbours, tolerance_m
    %
    %   Outputs:
    %       FLAG -> [N, 1], logical, landmarks to drop
    %       DIST -> [N, 1], distance to the local plane [m] (NaN where
    %              there were too few neighbours to decide)

    N    = size(X_m, 1);
    flag = false(N, 1);
    dist = nan(N, 1);

    [nb, d] = knnsearch(X_m, X_m, 'K', min(40, N));
    for i = 1:N
        k = nb(i, 2:end);
        k = k(d(i, 2:end) <= fcfg.radius_m);
        if numel(k) < fcfg.min_neighbours
            continue;
        end

        % Plane of the neighbours, refitted without the outliers once
        Q = X_m(k, :);
        [mu, n] = plane_of(Q);
        in = abs((Q - mu) * n') <= fcfg.tolerance_m;
        if nnz(in) >= fcfg.min_neighbours
            [mu, n] = plane_of(Q(in, :));
        end

        dist(i) = abs((X_m(i, :) - mu) * n');
        flag(i) = dist(i) > fcfg.tolerance_m;
    end
end

function [mu, n] = plane_of(Q)
    %   Mean and unit normal (smallest-variance axis) of a set of points.
    mu = mean(Q, 1);
    [V, ~] = eig(cov(Q));
    n = V(:, 1)';
end
%-----%
