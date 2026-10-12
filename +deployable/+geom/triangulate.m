function [xobj, cov] = triangulate(R, T, ii, uv, n, npts, eps_w, cam)
    %   This function is a straightforward implementation of DLT algorithm
    %   with a slight modification. In brief, the code takes the 2D pixel
    %   locations of landmarks (features) and triangulates them to find
    %   their 3D location. To do so, it takes in where the camera was
    %   located (T) and how it was rotated (R) and a list of 2D pixel
    %   locations (UV) which are landmarks. A landmark is a distinct
    %   physical point in the real world (such as a table corner). The
    %   algorithm draws a ray from the camera center through the 2D pixel
    %   out into the 3D world and finds where different rays intersect.
    %   That intersection point is the 3D location of the feature.
    %
    %   Inputs:
    %       R -> Struct, fields r11 to r33 of size [M, 1] representing R
    %       T -> [M, 3], translation of the object origin, camera frame
    %       II -> [M, 1], landmark index of each observed point
    %       UV -> [M, 2], observed pixel locations [px]
    %       N -> [M, 2], unit edge normal at each observation
    %       NPTS -> Scalar, number of features/landmarks
    %       EPS_W -> Scalar, weight of the tangential row 
    %       CAM -> Struct, camera model with focal and principal lengths
    %
    %   Outputs:
    %       XOBJ -> [NPTS, 3], 3D coordinates for the landmarks in object
    %       frame
    %       COV -> [NPTS, 3, 3], covariance of each feature but scaled
    %       using residual variance - the biggest eigenvalue is used to
    %       assess confidence

    % A reminder about theory here: the standard projection equation for a
    % pinhole camera is x = K(RX+T). 

    % First, we reverse the focal-length scaling and principal-point offset
    % This produces an [M, 2] array containing mX and mY
    m  = (uv - cam.principal) ./ cam.focal;
    mX = m(:, 1);
    mY = m(:, 2);

    % Now we generated the equations that we can use to solve for the pixel
    % locations -- we have two linear equations for three unknown
    % coordinates, so one single observation results in a ray of possible
    % solutions
    A1 = [mX.*R.r31 - R.r11, ...
          mX.*R.r32 - R.r12, ...
          mX.*R.r33 - R.r13];

    A2 = [mY.*R.r31 - R.r21, ...
          mY.*R.r32 - R.r22, ...
          mY.*R.r33 - R.r23];

    b1 = T(:,1) - mX.*T(:,3);
    b2 = T(:,2) - mY.*T(:,3); 
    
    % Let's define some empty cells and arrays for speed, we will store the
    % linear equations in them
    AtA     = zeros(npts, 3, 3); 
    Atb     = zeros(npts, 3); 

    % Now, an edge will give a strong position constraint across the edge
    % compared to along the edge -- so we need to change the direction in
    % which the image error is penalized.
    nX = n(:,1);
    nY = n(:,2);

    % We already have the normal define by 'n' but we also need to define
    % the tangential -- just rotate the normal vector by 90 degrees
    R_tangent   = [cosd(90), -sind(90); sind(90), cosd(90)];
    tangent = n * R_tangent';

    % Calculate the NORMAL direction equations - weighted normally
    A_norm  = 1.0 * (nX .* A1 + nY .* A2);
    b_norm  = 1.0 * (nX .* b1 + nY .* b2);

    % Calculate the TANGENTIAL direction equations - weighted lower
    A_tang = eps_w * (tangent(:,1) .* A1 + tangent(:,2) .* A2);
    b_tang = eps_w * (tangent(:,1) .* b1 + tangent(:,2) .* b2);

    % Store the equations in the respective cells (rhs is
    % 'right-hand-side')
    rows = {A_norm, A_tang};
    rhs  = {b_norm, b_tang};

    % Now we loop through all the 3D coordinates (X, Y, Z) and calculate
    % the two sides of the DLT equation (A^T Ax = A^T b). Note that this
    % code is pretty weird and is hard to wrap my brain around. Basically, 
    % the array 'ii' contains the list of IDs for each observation. If we
    % had 3 features but 6 observations, 'ii' might be [1 3 3 2 1 2]. The
    % 'accumarray' function takes whatever you put into 'values' and runs
    % that for each ID
    for cRHS = 1:3
        
        % Combine the NORMAL and TANGENTIAL equations for the RHS of the
        % equation
        Atb(:, cRHS) = Atb(:, cRHS) ...
            + accumarray(ii, A_norm(:, cRHS) .* b_norm, [npts 1]) ...
            + accumarray(ii, A_tang(:, cRHS) .* b_tang, [npts 1]); 

        for cLHS = 1:3
            
            % Combine the NORMAL and TANGENTIAL equations for the LHS of
            % the equation
            AtA(:, cRHS, cLHS) = AtA(:, cRHS, cLHS)...
                + accumarray(ii, A_norm(:, cRHS) .* A_norm(:, cLHS), [npts 1]) ...
                + accumarray(ii, A_tang(:, cRHS) .* A_tang(:, cLHS), [npts 1]); 

        end

    end
    
    % Initialize the solution vector X
    xobj = zeros(npts, 3);
   
    % Loop through all points and solve Ax=b to find 'x' -- the 1e-9 *
    % eye(3,3) is intended to prevent dividing by zero
    for i = 1:npts
        xobj(i, :) = ((squeeze(AtA(i, :, :)) + 1e-9 * eye(3)) \ Atb(i, :)')';
    end
    
    % Calculate the residuals and covariance
    if nargout > 1

        % Calculate the residuals by taking the 'x' solution and
        % calculating Ax-b -- if the 'x' is correct then the residuals
        % should be close to zero
        res = [sum(rows{1} .* xobj(ii, :), 2) - rhs{1}; 
               sum(rows{2} .* xobj(ii, :), 2) - rhs{2}];

        % Calculate the variance by taking the average squared error across
        % all observations and dividing by the 'degrees of freedom', which
        % is # of equations minus # of unknown 3D variables
        variance = (res' * res) / max(numel(res) - 3 * npts, 1);
        
        % Finally, calculate the covariance, which is defined as
        % sigma^2 * inv(A^T A)
        cov = zeros(npts, 3, 3);
        for i = 1:npts
            cov(i, :, :) = variance * inv(squeeze(AtA(i, :, :))...
                + 1e-9 * eye(3)); %#ok<MINV>
        end
    end

end