function [prob] = setup_problem(trajectory, landmarks, observations, ...
                    free_parameters, free_landmarks, cam, acfg)

    %   This function collects all the parameters needed for the bundle
    %   adjustment stage: the unpacked observations, the whitened
    %   measurement directions, the map from global parameter indices to
    %   Jacobian columns, and the spline weights at every observation time.
    %   The residual, Jacobian, and LM stages are all read from the output
    %   struct.
    %
    %   Inputs: 
    %       TRAJECTORY -> Struct, created in 'deployable.traj.create_trajectory' and
    %           contains the current motion estimate
    %       LANDMARKS -> [N, 3], landmark coordinates in the object frame
    %       OBSERVATIONS -> [M, 6], rows [time_s, landmark_id, u, v, nx,
    %           ny]
    %       FREE_PARAMETERS -> [P, 1], trajectory indices as defined in
    %           'deployable.traj.select_free_parameters'
    %       FREE_LANDMARKS -> [L, 1], indices for the landmarks which are
    %           allowed to change
    %       CAM -> Struct, camera model as defined in the configuration
    %       ACFG -> Struct, contains the bundle adjustment parameters
    %
    %   Outputs:
    %       PROB -> Struct, contains the constant data needed for the
    %           bundle adjustment

    % The main thing we need to check to start off is that we have
    % observations which are the correct size
    assert(size(observations, 2) == 6, 'Observations must be M-by-6.');

    % Next we want to split up the observation rows into their columns,
    % noting the renormalization (just to be sure)
    prob.t   = observations(:,1);  % time of observation
    prob.ids = observations(:,2);  % ID for track
    prob.uv  = observations(:,3:4);  % pixel coordinates of track
    prob.nn  = deployable.geom.unit_rows(observations(:,5:6));  % normals
    
    % Now set up the problem sizes, remembering that the trajecotyr uses
    % 8+4K global parameters, which is followed by [x, y, z] for each
    % landmark
    prob.M               = size(observations, 1);
    prob.N               = size(landmarks, 1);
    prob.K               = trajectory.K;
    prob.h               = trajectory.h;
    prob.n_traj          = 8 + 4*prob.K;
    assert(all(ismember(free_parameters, 1:prob.n_traj)) && ...
        numel(unique(free_parameters)) == numel(free_parameters), ...
        'Free parameters must be unique trajectory indices.');
    [prob.b0_idx, prob.b0_val] = deployable.traj.spline_basis(trajectory,trajectory.t0);
    [prob.b_idx, prob.b_val] = deployable.traj.spline_basis(trajectory,prob.t);
    prob.support_end = 0;
    if prob.M > 0, prob.support_end = max(prob.b_idx,[],'all'); end
    % Requested horizon may extend beyond the last usable observation.
    % Freeze unsupported spline columns rather than damping empty columns.
    angular_future=free_parameters>8+prob.support_end & free_parameters<=8+prob.K;
    translation_future=free_parameters>8+prob.K+3*prob.support_end;
    free_parameters=free_parameters(~angular_future & ~translation_future);

    prob.free_parameters = free_parameters(:);
    prob.free_landmarks  = free_landmarks(:);
    prob.n_free_motion   = numel(prob.free_parameters);
    prob.n_free          = prob.n_free_motion +...
                            3 * numel(prob.free_landmarks);
    
    % If there is nothing to optimize, then the inputs should be returned
    % unchanged
    prob.empty = prob.n_free == 0 || prob.M == 0;
    if prob.empty
        return;
    end

    % There are some asserts that we should check here, because having
    % duplicates would result in the Jacobian column being empty and the
    % normal matrix being singular
    assert(all(prob.ids >= 1 & prob.ids <= prob.N & prob.ids == round(prob.ids)), ...
        'Observation landmark IDs must index rows of LANDMARKS.');
    assert(all(ismember(prob.free_landmarks, 1:prob.N)) && ...
        numel(unique(prob.free_landmarks)) == numel(prob.free_landmarks), ...
        'Free landmarks must be unique landmark indices.');

    % The measurement directions: image residuals stay in pixels. A
    % common pixel-noise scale would only rescale the image cost against
    % the priors, which the prior weights already set, so there is none
    prob.wn = prob.nn;
    prob.wt = acfg.tangent_weight * [-prob.nn(:, 2), prob.nn(:, 1)];

    % The Cauchy scale, in the same (pixel) units as the residuals
    prob.cauchy_sq = acfg.cauchy_px^2;

    % Now we need to build the Jacobian, rememberin that '0' in the
    % parameter vector indicates a frozen parameter - we build the Jacobian
    % starting with the free motion paramters, followed by three columns
    % for each landmark
    prob.param_to_col = zeros(prob.n_traj + 3*prob.N, 1);
    prob.param_to_col(prob.free_parameters) = 1:prob.n_free_motion;
    for d = 1:3
        prob.param_to_col(prob.n_traj + 3 * (prob.free_landmarks - 1) + d) = ...
            prob.n_free_motion + 3 * (0:numel(prob.free_landmarks) - 1)' + d;
    end

    % The times for the knots don't change during an optimization run, only
    % the coefficients change - so we can calculate the spline indices and
    % weights once for each observation time
    prob.tau                   = prob.t - trajectory.t0;
    prob.velocity_weight = acfg.velocity_weight;
    % First differences are the derivative spline's control coefficients.
    % Adding V penalizes physical velocity, regardless of the V/m split.
    prob.D_velocity = spdiags([-ones(prob.K,1), ones(prob.K,1)], [0 1], prob.K, prob.K)/prob.h;
    prob.D_velocity(prob.K,:)=0;
    prob.b0_derivative = [-0.5 0 0.5 0]/prob.h;

    % The residual vector is now laid out in the following order for
    % computational efficiency
    %   2M      image rows, normal and tangent interleaved per observation
    %   K-2     angular curvature (second difference of k)
    %   3(K-2)  translation curvature (second difference of m)
    %   K       angular pull toward zero
    %   3K      total translation velocity control coefficients
    %   1       angular correction at t0 is zero (gauge)
    %   3       translation correction at t0 is zero (gauge)
    %   3       translation correction derivative at t0 is zero (gauge)
    %   1       landmark centroid along the rotation axis
    prob.n_img = 2*prob.M;

    % Finally we complete the structure by adding in the trajectory axis
    % and the camera intrinsics
    prob.reference_axis = trajectory.a(:);
    prob.focal          = cam.focal;
    prob.principal      = cam.principal;  

    % Camera model and depth limit used by the residuals
    prob.cam          = cam;
    prob.min_depth    = acfg.min_depth;
    prob.depth_weight = acfg.depth_weight;

    % Store the depth violation parameters
    prob.n_depth = prob.M;

    % Store the prior weights
    prob.lambda_rotation    = acfg.lambda_rotation;
    prob.lambda_translation = acfg.lambda_translation;
    prob.pull_fraction      = acfg.pull_fraction;
    prob.gauge_weight       = acfg.gauge_weight;
    prob.centroid_weight    = acfg.centroid_weight;
    prob.n_prior            = 4 * (prob.K - 2) + 4 * prob.K + 7 + 1;
    prob.n_res              = prob.n_img + prob.n_prior + prob.n_depth;

    %-----%
    % Block layout for the Schur solver (deployable.adjust.schur_setup): the spline
    % segment of every observation (its four knots are b_idx(:, 1:4), so
    % rows of one segment share the same motion columns) and the free-
    % landmark slot of every landmark (0 when the landmark is frozen)
    prob.seg              = prob.b_idx(:, 1);
    prob.lm_slot          = zeros(prob.N, 1);
    prob.lm_slot(prob.free_landmarks) = 1:numel(prob.free_landmarks);
    prob.n_free_landmarks = numel(prob.free_landmarks);
    %-----%




end
