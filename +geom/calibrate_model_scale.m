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
