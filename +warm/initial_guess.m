function [c0, V0] = initial_guess(obs, tau, cam)
    %   This function is used to calculate an initial guess for the
    %   spacecrafts centre position and translational drift. We make the
    %   assumption that the mean pixel positions of the observed features
    %   in each slice is a sufficient starting point for the optimization
    %   down the road.
    %
    %   Inputs:
    %       OBS -> [F, N, 4], observations from build_observations
    %       TAU -> [F, 1], frame times relative to the window start [s]
    %       CAM -> Struct, parameters for the camera 
    %
    %   Outputs:
    %       C0 -> [1, 2], initial centre offset at unit depth
    %       V0 -> [1, 3], initial centre drift [range/s]
    
    % First, pre-allocate some arrays for speed
    F = size(obs, 1);
    cen = nan(F, 2);

    % Now we loop through all of the observations and we calculate the
    % average pixel position for each set of observations (a 'set' here is
    % defined as a time slice -- so for example we calculate the mean for
    % all observations at 60.0125 [s])
    for f = 1:F
        
        % Extract all tracks at time slice 'f'
        vis = isfinite(obs(f, :, 1));

        % If there are observations at that time slice, calculate the
        % geometric centre of those observations
        if any(vis)
            cen(f, :) = [mean(obs(f, vis, 1)), mean(obs(f, vis, 2))]; 
        end
    end

    % Use the camera parameters to convert pixel coordinates to normalized
    % image coordinates -- these assume a 'depth' of '1'
    cen = (cen - cam.principal) ./ cam.focal;

    % Identify chunks that have a valid time and spatial coordinates
    tau = tau(:);
    okc = all(isfinite(cen), 2) & isfinite(tau);

    assert(numel(unique(tau(okc))) >= 2, ...
        'Initial drift estimation requires at least two distinct valid times.');

    % Fit the horizontal and vertical normalized centroid coordinates as
    % linear functions of time
    px = polyfit(tau(okc), cen(okc, 1), 1);
    py = polyfit(tau(okc), cen(okc, 2), 1);

    % The intercept can be used to estimate the center offset at tau = 0
    c0 = [px(2), py(2)];

    % The first coefficient of 'polyfit' is the slope of the linear fit,
    % which is the time derivative in this case
    V0 = [px(1) py(1) 0];
end