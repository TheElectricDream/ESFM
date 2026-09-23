function [accepted_idx, first, last] = slice_events(t, accept, centers, dt)
    %   This function groups the accepted events into consecutive slices,
    %   each covering [center - dt/2, center + dt/2). The events are
    %   time-sorted, so every slice is a contiguous run of the accepted
    %   events and can be found with two pointers instead of a search.
    %
    %   Inputs:
    %       T -> [E, 1], event timestamps [s], sorted
    %       ACCEPT -> [E, 1], logical, events with valid normal flow
    %       CENTERS -> [F, 1], slice centre times [s], evenly spaced
    %       DT -> Scalar, slice duration [s]
    %
    %   Outputs:
    %       ACCEPTED_IDX -> [A, 1], indices of the accepted events into T
    %       FIRST -> [F, 1], position in ACCEPTED_IDX of each slice's first
    %              event
    %       LAST -> [F, 1], position of each slice's last event
    %              (LAST < FIRST for an empty slice)
    %
    %   Slice f contains events accepted_idx(first(f):last(f)).
    
    assert(issorted(t), 'Event timestamps must be sorted.');
    
    accepted_idx = find(accept);
    edges        = [centers(:) - dt / 2; centers(end) + dt / 2];
    
    % Count the accepted events in every slice in one pass, then turn the
    % counts into start and end positions
    counts = histcounts(t(accepted_idx), edges)';
    last   = cumsum(counts);
    first  = last - counts + 1;

end