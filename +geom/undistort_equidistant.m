function [xy] = undistort_equidistant(xy_dist, cam)
    %   Uses the XML calibration parameters to undistort all of the event
    %   data -> a fisheye camera is assumed, and this function outputs the
    %   ideal pinhole image equivalent using Newton's method. The specific
    %   implementation here is based on the Kannala-Brandt fisheye model.
    %   This model uses: theta_d = theta*(1 + k1*theta^2 + k2*theta^4)
    %
    %   Inputs: 
    %       XY_DIST -> [N, 2], contains distorted pixel coordinates.
    %       CAM -> Struct, contains imported intrinsics.
    %
    %   Outputs:
    %       XY -> [N, 2], contains undistorted pixel coordinates.

    % First step is to normalize the pixel coordinates
    xd = (xy_dist(:, 1) - cam.principal(1)) / cam.focal(1);
    yd = (xy_dist(:, 2) - cam.principal(2)) / cam.focal(2);
    
    % Calculate the distorted radial distance on the normalized plane
    theta_d = sqrt(xd.^2 + yd.^2);

    % Initial guess for undistorted radial distance
    theta = theta_d;
    
    % Iterate; the model is a 5th order polynomial so we cannot simply
    % extract theta from the equation -- so we use numerical approximation
    for iter = 1:8

        % Calculate the square of the pinhole radial distance
        t2 = theta.^2;

        % Calculate the function value and its derivative -- if f_val is 
        % zero, this means we have a value of theta that gives us the
        % original theta_d
        f_val = theta .* (1 + cam.k1 * t2 + cam.k2 * t2.^2) - theta_d;
        f_der = 1 + 3 * cam.k1 * t2 + 5 * cam.k2 * t2.^2;

        % Apply Newton's method to iterate on theta
        theta = theta - f_val ./ f_der;
    end

    % Now we need to reproject using a perfect pinhole model (nz is used to
    % ensure no non-zero divisors)
    scale       = ones(size(theta_d));
    nz          = theta_d > 1e-9;
    scale(nz)   = tan(theta(nz)) ./ theta_d(nz);

    % Finally we apply the scaling factor to the original intrinsics to get
    % the undistorted image
    xy = [cam.focal(1) * xd .* scale + cam.principal(1), ...
            cam.focal(2) * yd .* scale + cam.principal(2)];

end