function [idx] = find_slice_starts(t, edges)
    %
    %   Inputs:
    %       T -> [N, 1], sorted event timestamps
    %       EDGES -> [1, K], slice boundary times [s]
    %
    %   Outputs:
    %       IDX -> [1, K], first event index at or after each edge; N+1 if none

    % Create boundary bins from -infinity, through our edges, to +infinity
    bins = [-inf, edges, inf];

    % Count how many events fall into each bin
    counts = histcounts(t, bins);

    % Calculate the starting index for each slice
    idx = cumsum(counts(1:end-1)) + 1;

end