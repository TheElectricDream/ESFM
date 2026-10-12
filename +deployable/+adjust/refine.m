function [tr, X, info] = refine(tr, X, observations, free_parameters, ...
    free_landmarks, max_iterations, cam, acfg)
    %   This function jointly refines the selected motion parameters and
    %   landmark coordinates by minimizing the robust reprojection cost
    %   plus priors with Levenberg-Marquardt. Parameters and landmarks
    %   that are not free still contribute residuals but do not move.
    %
    %   Inputs:
    %       TR -> Struct from deployable.traj.create_trajectory, initial estimate
    %       X -> [N, 3], initial landmark coordinates
    %       OBSERVATIONS -> [M, 6], rows [time_s, landmark_id, u, v, nx, ny]
    %       FREE_PARAMETERS -> [P, 1], trajectory indices from
    %              deployable.traj.select_free_parameters
    %       FREE_LANDMARKS -> [L, 1], indices of landmarks allowed to move
    %       MAX_ITERATIONS -> Scalar, maximum number of LM iterations
    %       CAM -> Struct, camera model with focal and principal
    %       ACFG -> Struct, adjuster parameters (cfg.adjust)
    %
    %   Outputs:
    %       TR -> Struct, refined trajectory
    %       X -> [N, 3], refined landmark coordinates
    %       INFO -> Struct, final cost, normal-residual RMS [px], number
    %              of accepted steps, number of active depth hinges, the
    %              iterations run and the cost after each of them
    
    info = struct('cost', NaN, 'rms', NaN, 'accepted_steps', 0, 'active_hinges', NaN, ...
                  'iterations', 0, 'cost_trace', zeros(0, 1));
    
    % Everything that stays constant for this call
    prob = deployable.adjust.setup_problem(tr, X, observations, free_parameters, ...
        free_landmarks, cam, acfg);
    if prob.empty
        return;
    end
    
    % Starting residuals and cost
    r       = deployable.adjust.residuals(prob, tr, X);
    cost    = deployable.adjust.robust_cost(prob, r);
    damping = acfg.damping0;

    %-----%
    % Solver and convergence settings (2026-10-11). 'schur' eliminates the
    % landmarks in 3x3 blocks and solves the dense motion system; 'sparse'
    % is the original full sparse solve. The budget MAX_ITERATIONS is a
    % ceiling: the loop also stops once the relative cost decrease has
    % stayed below cost_tol on cost_tol_streak consecutive accepted steps.
    use_schur = ~isfield(acfg, 'solver') || strcmp(acfg.solver, 'schur');
    cost_tol  = 0;
    streak_needed = inf;
    if isfield(acfg, 'cost_tol')
        cost_tol      = acfg.cost_tol;
        streak_needed = acfg.cost_tol_streak;
    end
    streak = 0;
    info.cost_trace = nan(max_iterations, 1);
    %-----%
    
    for iteration = 1:max_iterations
        info.iterations = iteration;
        cost_before     = cost;
    
        % Reweight: the Cauchy loss enters as a per-row weight
        % 1 / (1 + r^2/c^2) on the image rows, so the weighted
        % least-squares gradient equals the robust cost's gradient
        sw = ones(prob.n_res, 1);
        sw(1:prob.n_img) = 1 ./ sqrt(1 + r(1:prob.n_img).^2 / prob.cauchy_sq);

        %-----%
        % Linearize at the current estimate. The row weights are applied
        % to the Jacobian values directly (no diagonal sparse product)
        if use_schur
            sch = deployable.adjust.schur_setup(prob, tr, X, r, sw);
        else
            J = deployable.adjust.jacobian(prob, tr, X, sw);
            H = J' * J;
            g = J' * (sw .* r);
            D = spdiags(max(diag(H), 1e-9), 0, prob.n_free, prob.n_free);
        end
        %-----%
    
        % Try steps with increasing damping until the TRUE robust cost
        % decreases -- this is what makes any Jacobian approximation safe
        accepted = false;
        for attempt = 1:acfg.max_attempts
            %-----%
            if use_schur
                d = deployable.adjust.schur_solve(sch, damping);
            else
                d = -(H + damping * D) \ g;
            end
            %-----%
    
            [tr_trial, X_trial] = deployable.adjust.apply_step(prob, tr, X, d);
            r_trial    = deployable.adjust.residuals(prob, tr_trial, X_trial);
            cost_trial = deployable.adjust.robust_cost(prob, r_trial);
    
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
        info.cost_trace(iteration) = cost;
    
        % Stop if no step helped, or the step has become negligible
        if ~accepted || norm(d) < acfg.step_tol
            break;
        end

        %-----%
        % Converged: the robust cost no longer decreases materially
        if (cost_before - cost) / max(cost_before, eps) < cost_tol
            streak = streak + 1;
        else
            streak = 0;
        end
        if streak >= streak_needed
            break;
        end
        %-----%
    end
    info.cost_trace = info.cost_trace(1:info.iterations);
    
    % Summary: RMS of the normal residuals [px]
    info.cost          = cost;
    info.rms           = sqrt(mean(r(1:2:prob.n_img).^2));
    info.active_hinges = nnz(r(prob.n_img + prob.n_prior + 1:end));

end
