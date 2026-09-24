function [f, dbg] = fit_cells(t, x, y, scfg, offset)
    %   Creates a 3D volume of events, identifies planes, and fits to these
    %   plane. Edges at any given time step draw a line in X-Y -- as time
    %   progresses, these lines draw plane. This algorithm tries to
    %   estimate the velocity of those edges based on the tilt of the
    %   plane.
    %
    %   Inputs: 
    %       T -> [N, 1], timestamps for all events
    %       X -> [N, 1], x-pixel location for all events
    %       Y -> [N, 1], y-pixel location for all events
    %       SCFG -> Struct, contains parameters for surface estimation
    %       OFFSET -> [3, 1], offsets for shifting grid
    %
    %   Outputs:
    %       F -> Struct, outputs of velocity estimation algorithm
    %       DGB -> Struct, contains intermediate debug variables
    
    % Find the index bounds for the spatiotemporal kernel
    ix = floor((x + offset(1)) / scfg.cell_px);
    iy = floor((y + offset(2)) / scfg.cell_px);
    it = floor((t + offset(3)) / scfg.cell_s);

    % Group all events that are in the same spatiotemporal kernel and
    % assign those events a unique identifier 
    inv = findgroups(it, iy, ix); 
    C   = max(inv);

    % Convert the time into pixel-equivalent units -- this basically
    % defines the speeds that the algorithm will pick up best
    tau = t / scfg.sigma_s;

    % Calculate the covariance for each kernel (box) of events
    % Create a [C x 1] vector where the jth element is the sum of w over
    % all events -- we define an anonymous function to accomplish this
    % calculation
    S = @(w) accumarray(inv, w, [C 1]);

    % We can then use the anonymous function to calculate the histogram of
    % "inv" -- setting w = 1 basically means we add one to each cell for
    % every event
    n = S(1);

    % Then we calculate a safe historgram that contains no zeros -- we
    % don't want to divide by zero
    n_safe = max(n, 1);

    % Calculate the means
    mx = S(x) ./ n_safe;  
    my = S(y) ./ n_safe; 
    mt = S(tau) ./ n_safe;

    % Calculate the deviation from the means
    dx = x - mx(inv);  
    dy = y - my(inv);  
    dtt = tau - mt(inv);

    % Calculate the second moments -- for a set of n points, the covariance
    % between coordinates a & b is (1/n)*sum(a_i - a_mean)*(b_i - b_mean).
    % Recall that the diagonal entries are variances (spread) -- sqrt(cxx)
    % is basically RMS distance of events from the x-centroid of the box
    cxx = S(dx.*dx) ./ n_safe;  
    cyy = S(dy.*dy) ./ n_safe;  
    ctt = S(dtt.*dtt) ./ n_safe;

    % Calculate the off-diagonal entries, i.e. the covariances -- cxy
    % positive means there is an edge, zero means it's either a blob or an
    % edge aligned with an axis
    cxy = S(dx.*dy) ./ n_safe;  
    
    % The cxt and cyt values indicate if x or y increases as time
    % increases -- for example, an edge moving in +x creates events that
    % grow with time
    cxt = S(dx.*dtt) ./ n_safe;  
    cyt = S(dy.*dtt) ./ n_safe;

    % Because the covariance is symmetric, the eigenvalues would return the
    % principal directions of the ellipsoids own axes and the variance of
    % the cloud along those axis

    % Start by initializing matrices
    nrm   = repmat([0 0 1], C, 1); 
    w_mid = zeros(C,1); 
    w_min = ones(C,1);

    % Then, we loop over boxes that have sufficient events -- we need
    % enough events to fit a plane reliably.
    for c = find(n >= scfg.min_events_per_cell)'
        
        % Create the covariance matrix for the current cell which contains
        % sufficient events
        covar = [cxx(c), cxy(c), cxt(c);
                 cxy(c), cyy(c), cyt(c);
                 cxt(c), cyt(c), ctt(c)];

        % Then use the built-in eig function to extract the principle
        % direction and the variances
        [V, D] = eig((covar + covar') / 2);

        % Extract the diagonals
        d = diag(D);

        % Store the normals for the principle axis
        nrm(c,:) = V(:,1)';

        % Store the thickness of the plane -- if it's close to zero, it is
        % a clean edge, if it is a large number it is a blob
        w_min(c) = d(1);

        % Store the spread along the planes edge -- if this is small, it
        % means the events form a line and not a plane, which could be a
        % single pixel flickering or a corner
        w_mid(c) = d(2);

    end

    % Now that we have the results for all the valid cells, we can set some
    % constraints on what is acceptable
    planarity = w_min ./ max(w_mid, 1e-12);  % If ratio is >>, it's not a sheet

    % A hot pixel spreads only in time, so its normal lies in the image
    % plane and the time-normal test below already rejects it
    ok        = (n >= scfg.min_events_per_cell) & ...
                (abs(nrm(:, 3)) > scfg.min_time_normal);

    % Now we can calculate the velocity along the planes that we have
    % identified -- first we protect against a zero division
    nz = nrm(:, 3);  
    nz(abs(nz) <= 1e-9) = 1e-9;

    % Now we want to calculate the gradient in seconds per pixel
    g  = -nrm(:, 1:2) * scfg.sigma_s ./ nz;       % [s/px]

    % Properly convert the inverse speed into a velocity
    g2 = sum(g.^2, 2);
    vel = g ./ max(g2, 1e-12);                    % [px/s]

    % Finally, we can validate that our velocities are correct by applying
    % motion compensation theory -- basically, if we take a pixel and move
    % it back in time with the calculate velocity, all the events from the
    % same edges should land on the same pixel. If there is smearing, then
    % the velocity is wrong or it's not an edge. We basically want a sharp
    % output 
    
    % Calculate the mean kernel velocity (v_ev) and the mean kernel time
    % (tc)
    v_ev = vel(inv, :);  
    tc = mt(inv) * scfg.sigma_s;
    
    % Using the velocity of the kenerl, apply a linear state warp that
    % basically calculates where the current kernel would have been if the
    % velocity is correct
    xw = round(x - v_ev(:,1) .* (t - tc));  
    yw = round(y - v_ev(:,2) .* (t - tc));
    
    % Assign a unique identifier for each kernel
    wkey = inv * 1e7 + (yw + 1000) * 3000 + (xw + 1000);

    % Then, label each distinct group, and sum up however many events
    % landed in each group
    [~, ~, winv] = unique(wkey);
    wcnt = accumarray(winv, 1);

    % Return results 
    f.ok = ok(inv);  
    f.vel = v_ev;  
    f.planarity = planarity(inv);  
    f.support = wcnt(winv);

    % (Optional) Return debug variables 
    if nargout > 1
        dbg = struct('inv',inv,'n',n,'mx',mx,'my',my,'mt',mt*scfg.sigma_s, ...
            'nrm',nrm,'w_min',w_min,'w_mid',w_mid,'planarity',planarity, ...
            'ok',ok,'vel',vel,'xw',xw,'yw',yw,'wcnt',wcnt,'winv',winv);
    end


end