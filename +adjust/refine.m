function [tr, X, info] = refine(tr, X, observations, free_parameters, ...
    free_landmarks, max_iterations, cam, acfg)
    %   This function jointly refines the selected motion parameters and
    %   landmark coordinates by minimizing the robust reprojection cost
    %   plus priors with Levenberg-Marquardt. Parameters and landmarks
    %   that are not free still contribute residuals but do not move.
    %
    %   Inputs:
    %       TR -> Struct from traj.create_trajectory, initial estimate
    %       X -> [N, 3], initial landmark coordinates
    %       OBSERVATIONS -> [M, 6], rows [time_s, landmark_id, u, v, nx, ny]
    %       FREE_PARAMETERS -> [P, 1], trajectory indices from
    %              traj.select_free_parameters
    %       FREE_LANDMARKS -> [L, 1], indices of landmarks allowed to move
    %       MAX_ITERATIONS -> Scalar, maximum number of LM iterations
    %       CAM -> Struct, camera model with focal and principal
    %       ACFG -> Struct, adjuster parameters (cfg.adjust)
    %
    %   Outputs:
    %       TR -> Struct, refined trajectory
    %       X -> [N, 3], refined landmark coordinates
    %       INFO -> Struct, final cost, normal-residual RMS [px], number
    %              of accepted steps, and number of active depth hinges
    
    info = struct('cost', NaN, 'rms', NaN, 'accepted_steps', 0, 'active_hinges', NaN);
    
    % Everything that stays constant for this call
    prob = adjust.setup_problem(tr, X, observations, free_parameters, ...
        free_landmarks, cam, acfg);
    if prob.empty
        return;
    end
    
    % Starting residuals and cost
    r       = adjust.residuals(prob, tr, X);
    cost    = adjust.robust_cost(prob, r);
    damping = acfg.damping0;
    
    for iteration = 1:max_iterations
    
        % Linearize at the current estimate
        J = adjust.jacobian(prob, tr, X);
    
        % Reweight: the Cauchy loss enters as a per-row weight
        % 1 / (1 + r^2/c^2) on the image rows, so the weighted
        % least-squares gradient equals the robust cost's gradient
        sw = ones(prob.n_res, 1);
        sw(1:prob.n_img) = 1 ./ sqrt(1 + r(1:prob.n_img).^2 / prob.cauchy_sq);
        Jw = spdiags(sw, 0, prob.n_res, prob.n_res) * J;
    
        % Normal equations, with Marquardt's diagonal scaling so each
        % parameter is damped relative to its own curvature
        H = Jw' * Jw;
        g = Jw' * (sw .* r);
        D = spdiags(max(diag(H), 1e-9), 0, prob.n_free, prob.n_free);
    
        % Try steps with increasing damping until the TRUE robust cost
        % decreases -- this is what makes any Jacobian approximation safe
        accepted = false;
        for attempt = 1:acfg.max_attempts
            d = -(H + damping * D) \ g;
    
            [tr_trial, X_trial] = adjust.apply_step(prob, tr, X, d);
            r_trial    = adjust.residuals(prob, tr_trial, X_trial);
            cost_trial = adjust.robust_cost(prob, r_trial);
    
            if cost_trial < cost
                tr       = tr_trial;
                X        = X_trial;
                r        = r_trial;
                cost     = cost_trial;
                damping  = damping / acfg.damping_down;
                accepted = true;
                info.accepted_steps = info.accepted_steps + 1;
                break;
            end
    
            damping = damping * acfg.damping_up;
        end
    
        % Stop if no step helped, or the step has become negligible
        if ~accepted || norm(d) < acfg.step_tol
            break;
        end
    end
    
    % Summary: RMS of the normal residuals, converted back to pixels
    info.cost          = cost;
    info.rms           = sqrt(mean((r(1:2:prob.n_img) * acfg.sigma_px).^2));
    info.active_hinges = nnz(r(prob.n_img + prob.n_prior + 1:end));

end