function [trajectory] = create_trajectory(t0, t1, h)
    %   The purpose of this function is to extend the current motion model
    %   using a time varying spline.
    %   
    %   Inputs:
    %       T0 -> Scalar, motion-model reference time [t]
    %       T1 -> Scalar, end of trajectory interval [t]
    %       H -> Scalar, spline spacing [s]
    %
    %   Outputs:
    %       TRAJECTORY -> Struct, contains the mean-motion parameters, any
    %       spline coefficnets, and time-indexing information

    trajectory.t0 = t0;
    trajectory.h  = h;
    trajectory.n_seg = ceil((t1-t0)/h) + 2;
    trajectory.K = trajectory.n_seg+3;
    trajectory.knot_t = t0 + h * ((0:trajectory.K - 1)' - 1);
    trajectory.a = [0; -1; 0];
    trajectory.omega = 0.1;
    trajectory.c = [0 0];
    trajectory.V = [0 0 0];
    trajectory.k = zeros(trajectory.K, 1);
    trajectory.m = zeros(trajectory.K, 3);

end