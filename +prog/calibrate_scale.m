function scale = calibrate_scale(X, ids, ocfg)
    %   This function converts model units to metres for reporting. Scaling
    %   never changes the reconstructed shape: multiplying both landmarks
    %   and translations by one factor leaves every projection unchanged.
    %   Without known endpoints, the 1-99 percentile extent of the cloud
    %   along its principal axis is ASSUMED to equal the known width,
    %   which is a provisional heuristic.
    %
    %   Inputs:
    %       X -> [K, 3], kept landmarks, model units
    %       IDS -> [K, 1], original IDs of the kept landmarks
    %       OCFG -> Struct, output configuration (known_width_m,
    %              scale_endpoint_ids)
    %
    %   Outputs:
    %       SCALE -> Struct with m_per_unit, span_model, method,
    %              provisional
    
    scale = struct('known_width_m', ocfg.known_width_m, 'provisional', false);
    
    if isempty(ocfg.scale_endpoint_ids)
        [~, ~, V] = svd(X - mean(X, 1), 0);
        p = sort(X * V(:, 1));
        e = interp1(1:numel(p), p, 1 + (numel(p) - 1) * [1 99] / 100);
        span = e(2) - e(1);
        scale.method      = 'provisional 1-99 percentile principal-axis span';
        scale.provisional = true;
    else
        req = ocfg.scale_endpoint_ids;
        assert(numel(req) == 2 && req(1) ~= req(2), 'Provide two distinct endpoint IDs.');
        [found, r] = ismember(req, ids);
        assert(all(found), 'A scale endpoint ID is not in the final cloud.');
        span = norm(X(r(2), :) - X(r(1), :));
        scale.method = 'specified endpoints';
    end
    
    assert(isfinite(span) && span > 0, 'Invalid cloud span for scaling.');
    scale.span_model = span;
    scale.m_per_unit = ocfg.known_width_m / span;

end