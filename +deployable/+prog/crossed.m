function fire = crossed(t_prev, t_now, period, origin)
    %   Returns true when a multiple of PERIOD (counted from ORIGIN) lies
    %   in (T_PREV, T_NOW], i.e. on the first slice after each boundary.
    %   This expresses a cadence in seconds, independent of slice width.
    %
    %   Inputs:
    %       T_PREV -> Scalar, previous slice centre [s]
    %       T_NOW -> Scalar, current slice centre [s]
    %       PERIOD -> Scalar, cadence [s]
    %       ORIGIN -> Scalar, time the multiples are counted from [s]
    %
    %   Outputs:
    %       FIRE -> Logical
    
    fire = floor((t_now - origin) / period) > floor((t_prev - origin) / period);

end