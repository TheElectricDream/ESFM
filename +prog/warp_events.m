function [warped, direction] = warp_events(slice, tc)
    %   This function moves every event to where its edge would be at the
    %   slice centre TC, using the event's normal flow. The slice's smear
    %   collapses into sharp edges at a single instant. Normal flow only
    %   describes motion across the edge, so the warp sharpens edges
    %   across their width, not along them.
    %
    %   Inputs:
    %       SLICE -> Struct with fields t, x, y [E, 1] and flow [E, 2]
    %       TC -> Scalar, slice centre time [s]
    %
    %   Outputs:
    %       WARPED -> [E, 2], event positions moved to time TC [px]
    %       DIRECTION -> [E, 2], unit normal-flow direction of each event
    
    % Time of each event relative to the slice centre
    dt_ev = slice.t - tc;
    
    % Move each event along its normal flow to the centre time
    warped = [slice.x - slice.flow(:, 1) .* dt_ev, ...
        slice.y - slice.flow(:, 2) .* dt_ev];
    
    % Direction of motion across the edge -- used to gate claims by edge
    % orientation and by the sign of the motion
    direction = geom.unit_rows(slice.flow);

end