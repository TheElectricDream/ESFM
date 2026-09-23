function [fits] = sweep_axes(resid, nll, c0, V0, wcfg)
    %   This function takes the residuals function (see 'twist_residual')
    %   and the objective function (see 'cauchy'), and performs a first
    %   pass optimization to find the axis, rotation rate, centre offset,
    %   and drift of the object being reconstructed. For this first pass,
    %   we generate a bunch of candidate axes (see 'hemisphere_directions')
    %   and a set of initial guesses (see 'config' and 'initial_guess') 
    %   and we optimize the remaining parameters. This creates a structure
    %   called 'fits' which has all the candidate fits that we can refine. 
    %
    %   Inputs:
    %       RESID -> Handle, @(a, w, q) giving raw residuals
    %       NLL -> Handle, @(a, w, q) giving the scalar robust cost
    %       C0 -> [1, 2], initial centre offset
    %       V0 -> [1, 3], initial centre drift
    %       WCFG -> Struct, warm-start parameters
    %
    %   Outputs:
    %       FITS -> [1, K] struct array with fields a, w, q, seed, cost

    % Our goal here is to find a hypothesis which explains the tracks that
    % we are observing in 3D -- we do this by iterating over fixed axes and
    % solving for rotating rate, centre offset, and drift

    % For the moment, we will stick with 'lsqnonlin' as this is definitely
    % a nonlinear function, and 'lsqnonlin' is suitable for deployment to
    % an embedded computer -- but this is definitely a point to come back
    % and inspect

    % The first step is to set up the optimization settings
    opts = optimoptions('lsqnonlin', 'Display', 'off', ...
        'MaxFunctionEvaluations', wcfg.max_function_evals,...
        'FunctionTolerance', 1e-8, 'StepTolerance', 1e-8);

    % Next we generate the set ot axes to loop over during the optimization
    % process -- this uses the 'hemisphere_directions' function -- the
    % optimization will try to find the rate, offset, and drift for each
    % fixed axis
    dirs = geom.hemisphere_directions(wcfg.hemisphere_directions, ...
                            wcfg.base_axis);
    dirs = [dirs; -dirs];  % Include a negative axis

    % Knowing that the parameters we want to solve are defined as
    % [w, cx, cy, Vx, Vy, Vz], we set up the bounds accordingly in 'config'
    lb = [-1, -wcfg.max_centre_offset, -wcfg.max_centre_offset, ...
        -wcfg.max_velocity_per_s, -wcfg.max_velocity_per_s, ...
        -wcfg.max_velocity_per_s];
    ub = -lb;

    % Set up the struct array to store the results from the optimization
    % routine
    fits = struct('a', {}, 'w', {}, 'q', {}, 'seed', {}, 'cost', {});

    % The outter layer of the optimization loop selects an initial guess
    % for the angular rate
    for s = 1:numel(wcfg.rate_seeds_deg_s)
        wh = deg2rad(wcfg.rate_seeds_deg_s(s));

        % Now we select an axis
        for k = 1:size(dirs, 1)
            a = dirs(k,:)';

            % Run the optimization -- set the initial conditions
            p0 = [wh, c0, V0];

            % Set the objective function
            objective = @(p) warm.cauchy( ...
                resid(a, p(1), p(2:6)), wcfg.cauchy_px);

            % Adjust the parameters to reduce the sum of the squared
            % residuals
            p = lsqnonlin(objective, p0, lb, ub, opts);

            fits(end+1) = struct( ...
                'a', a, ...
                'w', p(1), ...
                'q', p(2:6), ...
                'seed', wh, ...
                'cost', nll(a, p(1), p(2:6))); %#ok<AGROW>

        end

    end

end