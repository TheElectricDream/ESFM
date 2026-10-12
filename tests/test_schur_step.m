%-----%
function tests = test_schur_step
    %   The Schur-complement step (adjust.schur_setup + adjust.schur_solve)
    %   must equal the full sparse normal-equations step for every mix of
    %   free motion parameters and free landmarks, and for any damping.
    tests = functiontests(localfunctions);
end

function setupOnce(tc)
    tc.TestData.root = fileparts(fileparts(mfilename('fullpath')));
    addpath(tc.TestData.root);
end

function [tr, X, O, cam, cfg] = fixture()
    cfg = config();
    tr  = traj.create_trajectory(0, 36, 1);
    rng(47);
    a = [0.1; -1; 0.05];
    tr.a = a / norm(a);
    tr.omega = deg2rad(5);
    tr.c = [0.01 -0.02];
    tr.V = [1e-3 -2e-3 3e-3];
    tr.k = randn(tr.K, 1) * 1e-3;
    tr.m = randn(tr.K, 3) * 1e-3;
    n_pts = 40;
    X  = randn(n_pts, 3) * 0.2;
    t  = sort(30 * rand(n_pts * 15, 1));
    id = repmat((1:n_pts)', 15, 1);
    cam = struct('focal', [300 300], 'principal', [160 120]);
    [R, T] = traj.pose(tr, t);
    uv = geom.project(R, T, X(id, :), cam) + 0.5 * randn(numel(t), 2);
    nn = geom.unit_rows(randn(numel(t), 2));
    O  = [t, id, uv, nn];
    tr.omega = tr.omega * 1.05;
    X = X + 0.01 * randn(size(X));
end

function compare(tc, free_fn, free_lm, damping)
    [tr, X, O, cam, cfg] = fixture();
    free = free_fn(tr);
    prob = adjust.setup_problem(tr, X, O, free, free_lm, cam, cfg.adjust);
    r  = adjust.residuals(prob, tr, X);
    sw = ones(prob.n_res, 1);
    sw(1:prob.n_img) = 1 ./ sqrt(1 + r(1:prob.n_img).^2 / prob.cauchy_sq);
    J = adjust.jacobian(prob, tr, X, sw);
    H = J' * J;
    g = J' * (sw .* r);
    D = spdiags(max(diag(H), 1e-9), 0, prob.n_free, prob.n_free);
    d_sparse = -(H + damping * D) \ g;
    sch = adjust.schur_setup(prob, tr, X, r, sw);
    d_schur = adjust.schur_solve(sch, damping);
    tc.verifyEqual(numel(d_schur), numel(d_sparse));
    tc.verifyLessThan(norm(d_schur - d_sparse) / max(norm(d_sparse), eps), 1e-7);
end

function testAllFree(tc)
    compare(tc, @(tr) traj.select_free_parameters(tr, true, 30, [], true), (1:40)', 1e-3);
end

function testAllFreeLargeDamping(tc)
    compare(tc, @(tr) traj.select_free_parameters(tr, true, 30, [], true), (1:40)', 10);
end

function testMotionOnly(tc)
    compare(tc, @(tr) traj.select_free_parameters(tr, false, 20, 10, true), [], 1e-3);
end

function testLandmarksOnly(tc)
    compare(tc, @(tr) [], (1:40)', 1e-3);
end

function testSubsetLandmarks(tc)
    compare(tc, @(tr) traj.select_free_parameters(tr, true, 30, [], true), (1:2:40)', 1e-2);
end

function testMeanMotionOnlyAndSubset(tc)
    compare(tc, @(tr) traj.select_free_parameters(tr, true, [], [], true), (5:25)', 1e-3);
end
%-----%
