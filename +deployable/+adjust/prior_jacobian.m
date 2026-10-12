function [rows, cols, vals] = prior_jacobian(prob, tr, X)
    %   This functions purpose is to construct the Jacobian of the prior
    %   residuals - every prior except the centroid is linear and thus the
    %   derivatives are the coefficients of the residual equations. The
    %   centroid derivatives use the current axis so we have to rebuild
    %   this for every iterations.
    %
    %   Inputs:
    %       PROB -> Struct, as described in 'deployable.adjust.setup_problem'
    %       TR -> Struct, the trajectory where we linearize
    %       X -> [N, 3], the landmark coordinates where we linearize
    %
    %   Outputs:
    %       ROWS -> [Q, 1], the rows in the FULL residual vector
    %       COLS -> [Q, 1], the GLOBAL parameter indices, obtained before
    %           mapping to the free columns using 'prob.param_to_col'
    %       VALS -> [Q, 1], the derivatives
    
    % First we extract some parameters and setup some empty cell arrays
    K = prob.K;
    N = prob.N;
    h = prob.h;
    w_rot = prob.lambda_rotation * (180 /pi);
    w_trans = prob.lambda_translation * 1000;
    
    rows = {};
    cols = {};
    vals = {};

    % Curvature rows - stencil [1 -2 1] on knots j, j+1, j+2
    row     = prob.n_img;
    j       = (1:K-2)';
    stencil = [1 -2 1];
    for q = 1:3
        rows{end+1} = row + j;                                          %#ok<AGROW>
        cols{end+1} = 8 + j + q - 1;                                    %#ok<AGROW>
        vals{end+1} = repmat(stencil(q) * w_rot / h^2, K-2, 1);         %#ok<AGROW>
        for d = 1:3
            rows{end+1} = row + (K-2) + 3 * (j - 1) + d;                %#ok<AGROW>
            cols{end+1} = 8 + K + 3 * (j + q - 2) + d;                  %#ok<AGROW>
            vals{end+1} = (j+2 <= prob.support_end) * stencil(q) * w_trans / h^2;   %#ok<AGROW>
        end
    end

    % Angular pull rows, then total velocity rows (V plus first differences).
    row = row + 4 * (K - 2);
    j   = (1:K)';
    rows{end+1} = row + j;                                              
    cols{end+1} = 8 + j;                                                
    vals{end+1} = repmat(prob.pull_fraction * w_rot, K, 1);             
    [vr,vc,vv]=find(prob.D_velocity);
    sel=vr<prob.support_end; vr=vr(sel); vc=vc(sel); vv=vv(sel);
    for d=1:3
        rows{end+1}=row+K+3*(vr-1)+d;
        cols{end+1}=8+K+3*(vc-1)+d;
        vals{end+1}=prob.velocity_weight*vv;
        active=(1:prob.support_end-1)';
        rows{end+1}=row+K+3*(active-1)+d;
        cols{end+1}=repmat(5+d,prob.support_end-1,1);
        vals{end+1}=repmat(prob.velocity_weight,prob.support_end-1,1);
    end

    % Gauge rows - the spline weights at t0 on the four active knots
    row = row + 4 * K;
    rows{end+1} = repmat(row + 1, 4, 1);                                
    cols{end+1} = 8 + prob.b0_idx';                                     
    vals{end+1} = prob.gauge_weight * prob.b0_val';                     
    for d = 1:3
        rows{end+1} = repmat(row + 1 + d, 4, 1);                        %#ok<AGROW>
        cols{end+1} = 8 + K + 3 * (prob.b0_idx' - 1) + d;               %#ok<AGROW>
        vals{end+1} = prob.gauge_weight * prob.b0_val';                 %#ok<AGROW>
    end

    % Initial correction-velocity gauge: derivative of the cubic basis.
    for d=1:3
        rows{end+1}=repmat(row+4+d,4,1);
        cols{end+1}=8+K+3*(prob.b0_idx'-1)+d;
        vals{end+1}=prob.gauge_weight*prob.b0_derivative';
    end
    row  = row + 7;
    a    = tr.a(:);
    Xbar = mean(X, 1)';
    % Centroid row: derivative with respect to each landmark is c*a/N.
    for d = 1:3
        rows{end+1} = repmat(row + 1, N, 1);                            %#ok<AGROW>
        cols{end+1} = prob.n_traj + 3 * (0:N-1)' + d;                   %#ok<AGROW>
        vals{end+1} = repmat(prob.centroid_weight * a(d) / N, N, 1);    %#ok<AGROW>
    end

    % Centroid row - derivative with respect to the two axis tangent
    % parameters. For unit a and tangent t, d/dp normalize(a + p t) at
    % p = 0 is exactly t, so the derivative is c * (t . Xbar)
    [t1, t2]    = deployable.geom.axis_tangent(a);
    rows{end+1} = [row + 1; row + 1];                                   
    cols{end+1} = [1; 2];                                               
    vals{end+1} = prob.centroid_weight * [t1' * Xbar; t2' * Xbar];      

    rows = vertcat(rows{:});
    cols = vertcat(cols{:});
    vals = vertcat(vals{:});

end
