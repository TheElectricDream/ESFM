function tests = test_surface_overlap
    tests = functiontests(localfunctions);
end

function setupOnce(testCase)
    project_dir = fileparts(fileparts(mfilename('fullpath')));
    testCase.applyFixture(matlab.unittest.fixtures.PathFixture(project_dir));
end

function testDefaultConfiguration(testCase)
    cfg = config();
    verifyEqual(testCase, cfg.surface.cell_px, 8);
    verifyEqual(testCase, cfg.surface.stride_px, 4);
    verifyEqual(testCase, cfg.surface.sigma_s, cfg.surface.cell_s * 0.0375);
end

function testOverlapRecoversBoundaryEdge(testCase)
    [ev, scfg] = boundary_edge();
    legacy = rmfield(scfg, 'stride_px');
    [original_accept, original_flow] = surface.compute(ev, legacy);
    verifyFalse(testCase, any(original_accept));
    verifyEqual(testCase, original_flow, zeros(numel(ev.t), 2));

    % The edge crosses x=8 in the original grid and y=4 in its diagonal
    % offset. Only a mixed x/y offset supplies all 24 supporting events.
    for stride = [4 2]
        scfg.stride_px = stride;
        [accept, flow] = surface.compute(ev, scfg);
        verifyTrue(testCase, all(accept));
        verifyEqual(testCase, flow, repmat([2 0], numel(ev.t), 1), ...
            'AbsTol', 1e-9);
    end
end

function testOriginalModeIsBackwardCompatible(testCase)
    [ev, scfg] = boundary_edge();
    scfg.min_events_per_cell = 6;
    for two_grids = [false true]
        scfg.two_offset_grids = two_grids;
        legacy = rmfield(scfg, 'stride_px');
        [expected_accept, expected_flow] = surface.compute(ev, legacy);
        verifyTrue(testCase, any(expected_accept));
        scfg.stride_px = scfg.cell_px;
        [accept, flow] = surface.compute(ev, scfg);
        verifyEqual(testCase, accept, expected_accept);
        verifyEqual(testCase, flow, expected_flow);
    end
end

function testTimeRangeUsesOutsideSupport(testCase)
    [ev, scfg] = boundary_edge();
    time_range = [0.22 0.58];
    requested = ev.t >= time_range(1) & ev.t < time_range(2);
    [accept, flow] = surface.compute(ev, scfg, time_range);
    verifyEqual(testCase, accept, requested);
    verifyEqual(testCase, flow(requested, :), ...
        repmat([2 0], nnz(requested), 1), 'AbsTol', 1e-9);
    verifyEqual(testCase, flow(~requested, :), zeros(nnz(~requested), 2));

    % Requested events alone cannot meet the 15-event fit threshold.
    cropped = struct('t', ev.t(requested), 'x', ev.x(requested), ...
        'y', ev.y(requested), 'p', ev.p(requested));
    verifyFalse(testCase, any(surface.compute(cropped, scfg)));
end

function testTemporalOffsetRecoversTimeBoundary(testCase)
    [ev, scfg] = boundary_edge();
    ev.t = ev.t + 0.4;
    scfg.two_offset_grids = false;
    verifyFalse(testCase, any(surface.compute(ev, scfg)));
    scfg.two_offset_grids = true;
    [accept, flow] = surface.compute(ev, scfg);
    verifyTrue(testCase, all(accept));
    verifyEqual(testCase, flow, repmat([2 0], numel(ev.t), 1), ...
        'AbsTol', 1e-9);
end

function testPolarityGroupsRemainSeparate(testCase)
    [ev, scfg] = boundary_edge();
    ev.p(1:2:end) = -1;
    verifyFalse(testCase, any(surface.compute(ev, scfg)));
    scfg.split_polarities = false;
    verifyTrue(testCase, all(surface.compute(ev, scfg)));
end

function testRejectionChecksRemainActive(testCase)
    [ev, scfg] = boundary_edge();
    scfg.min_warped_support = numel(ev.t) + 1;
    [accept, flow] = surface.compute(ev, scfg);
    verifyFalse(testCase, any(accept));
    verifyEqual(testCase, flow, zeros(numel(ev.t), 2));

    [ev, scfg] = boundary_edge();
    ev.x(:) = 8;  % Static edge: its plane contains the time axis.
    verifyFalse(testCase, any(surface.compute(ev, scfg)));
end

function testEventOrderAndNegativeCoordinates(testCase)
    [ev, scfg] = boundary_edge();
    count = numel(ev.t);
    % Two separate edges have opposite velocities and polarities.
    ev.x = [ev.x - 16; 24 - 2 * (ev.t - 0.4)];
    ev.y = [ev.y - 8; ev.y];
    ev.t = [ev.t; ev.t];
    ev.p = [ev.p; -ev.p];
    [expected_accept, expected_flow] = surface.compute(ev, scfg);
    verifyTrue(testCase, all(expected_accept));
    verifyEqual(testCase, expected_flow, ...
        [repmat([2 0], count, 1); repmat([-2 0], count, 1)], 'AbsTol', 1e-9);
    order = numel(ev.t):-1:1;
    shuffled = struct('t', ev.t(order), 'x', ev.x(order), ...
        'y', ev.y(order), 'p', ev.p(order));
    [accept, flow] = surface.compute(shuffled, scfg);
    verifyEqual(testCase, accept, expected_accept(order));
    verifyEqual(testCase, flow, expected_flow(order, :), 'AbsTol', 1e-9);
end

function testBaselineIgnoresStride(testCase)
    [ev, scfg] = boundary_edge();
    scfg.min_events_per_cell = 6;
    [expected_accept, expected_flow] = surface.compute_baseline(ev, scfg);
    scfg.stride_px = 2;
    [accept, flow] = surface.compute_baseline(ev, scfg);
    verifyEqual(testCase, accept, expected_accept);
    verifyEqual(testCase, flow, expected_flow);
end

function testInvalidStride(testCase)
    [ev, scfg] = boundary_edge();
    scfg.stride_px = 3;
    verifyError(testCase, @() surface.compute(ev, scfg), ...
        'surface:InvalidStride');
end

function [ev, scfg] = boundary_edge()
    [t, y] = ndgrid([0.1 0.22 0.34 0.46 0.58 0.7], ...
        [3.1 3.7 4.3 4.9]);
    ev = struct('t', t(:), 'x', 8 + 2 * (t(:) - 0.4), ...
        'y', y(:), 'p', ones(numel(t), 1));
    cfg = config();
    scfg = cfg.surface;
end
