function test_progressive_slices()
% Every returned slice must contain exactly its accepted, half-open window.
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);

% Include warm events, rejected events, an empty slice, exact boundaries,
% and events after the requested window. Binary-exact times avoid rounding
% ambiguity in the boundary assertions.
t = [60; 61; 66; 66.03125; 66.0625; 66.125; 66.375; 66.5; 67];
accept = true(size(t));
accept(4) = false;
centers = (66.0625:0.125:66.4375)';
check_slices(t, accept, centers, 0.125);
check_slices(t, false(size(t)), centers, 0.125);
check_slices(t, accept & t < 66, centers, 0.125);
check_slices(t, accept & t >= 66, centers, 0.125);

% Reproduce the production warm-end and slice duration.
t = [60; 61; 66.01; 66.04; 66.11; 66.14];
check_slices(t, true(size(t)), [66.05; 66.15], 0.1);
fprintf('PASS progressive slice indices match direct timestamp selection.\n');
end

function check_slices(t, accept, centers, dt)
[idx, first, last] = prog.slice_events(t, accept, centers, dt);
for f = 1:numel(centers)
    actual = idx(first(f):last(f));
    expected = find(accept & t >= centers(f)-dt/2 & t < centers(f)+dt/2);
    assert(isequal(actual(:), expected(:)), ...
        'Slice %d does not contain its requested timestamps.', f);
end
end
