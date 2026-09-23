function [prof, interval] = rate_profile(best, resid, nll, wcfg)
    %   Maps the cost as a function of rotation rate so that we can assess
    %   how much the other parameters are compensating for errors in said
    %   rate. This function is a diagnostic one.
    %
    %   Inputs:
    %       BEST -> Struct, the refined best fit
    %       RESID -> Handle, @(a, w, q) giving raw residuals
    %       NLL -> Handle, @(a, w, q) giving the scalar robust cost
    %       WCFG -> Struct, warm-start parameters
    %
    %   Outputs:
    %       PROF -> [1, K], cost at each rate in wcfg.rate_profile_deg_s
    %       INTERVAL -> Scalar, half-width of the low-cost valley, as a fraction
    
    % First we set the optimization
    opts = optimoptions('lsqnonlin', 'Display', 'off', ...
        'MaxFunctionEvaluations', wcfg.max_function_evals, ...
        'FunctionTolerance', 1e-8, 'StepTolerance', 1e-8);

    % Then the bounds
    lb = [-wcfg.max_centre_offset, -wcfg.max_centre_offset, ...
        -wcfg.max_velocity_per_s, -wcfg.max_velocity_per_s, -wcfg.max_velocity_per_s];
    ub = -lb;

    % We extract the vector of rates that we want to investigate
    rates = wcfg.rate_profile_deg_s;

    % Preallocate an array
    prof = nan(size(rates));

    % Then we loop through the rates, and run the optimization for each
    % rate
    for k = 1:numel(rates)
        w = deg2rad(rates(k));
        q = lsqnonlin(@(q) warm.cauchy(resid(best.a, w, q), wcfg.cauchy_px), ...
            best.q, lb, ub, opts);
        prof(k) = nll(best.a, w, q);
    end
    
    % We check if there is a valid result
    valid = isfinite(prof);
    interval = NaN;

    if ~any(valid)
        return;
    end

    inside = rates(valid & prof <= min(prof(valid)) + 2);

    % Finally we calculate the interval
    bestSpeed = abs(rad2deg(best.w));
    
    if isfinite(bestSpeed) && bestSpeed > 0
        interval = (max(inside) - min(inside)) / (2 * bestSpeed);
    end

end