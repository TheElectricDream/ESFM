function [t1, t2] = axis_tangent(a)
    %   Given a unit axis, this function creates the other two tangent
    %   dirtections to complete the reference frame.
    %
    %   Inputs:
    %       A -> [3, 1] or [1, 3], unit axis
    %
    %   Outputs:
    %       T1 -> [3, 1], first tangent direction
    %       T2 -> [3, 1], second tangent direction

    if abs(a(1)) < 0.9 
        t1 = cross(a(:), [1; 0; 0]); 
    else
        t1 = cross(a(:), [0; 1; 0]); 
    end
    t1 = t1 / norm(t1);
    t2 = cross(a(:), t1);

end