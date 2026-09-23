function [tr, X] = apply_step(prob, tr, X, d)
    %   This function is used to apply a single step to the trajectory and
    %   landmarks (obtained from the optimizer). The 'step' only contains
    %   the parameters that have been labelled as 'free', and everything
    %   else is left constant.
    %
    %   Inputs:
    %       PROB -> Struct, as defined in 'adjust.setup_problem'
    %       TR -> Struct, the trajectory we are evaluating
    %       X -> [N, 3], the landmark coordinates we are evaluating
    %       D -> [n_free, 1], solver step, with free motion parameters first
    %              (in prob.free_parameters order), then [x y z] for each
    %              free landmark (in prob.free_landmarks order)
    %
    %   Outputs:
    %       TR -> Struct, the updated trajectory
    %       X -> [N, 3], the updated landmarks

    % We can do a couple sanity checks first, because it's good practice
    assert(numel(d) == prob.n_free, 'Step length must equal the free column count.');
    d = d(:);

    % First we create a vector of zeros 'p' of the same length as the
    % number of trajectories
    p = zeros(prob.n_traj, 1);

    % Then we store the actual increments from the optimizer 'd' into the
    % vector 'p', and we call the 'increment_trajectory' function to step
    % the motion forward
    p(prob.free_parameters) = d(1:prob.n_free_motion);
    tr = traj.increment_trajectory(tr, p);

    % Finally, we increment the [x, y, z] for all free landmarks
    X(prob.free_landmarks, :) = X(prob.free_landmarks, :) ...
        + reshape(d(prob.n_free_motion + 1:end), 3, [])';
    
end