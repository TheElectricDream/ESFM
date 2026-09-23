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
    
    % Counts are relative to the requested window, whereas accepted_idx
    % also includes earlier events (in particular, the warm start).
    % Offset the positions by that prefix. Exclude the final edge because
    % histcounts otherwise includes it in its last bin.
    accepted_t = t(accepted_idx);
    prefix = nnz(accepted_t < edges(1));
    counts = histcounts(accepted_t(accepted_t < edges(end)), edges)';
    last   = prefix + cumsum(counts);
    first  = last - counts + 1;

end
