"""+adjust: robust bundle adjustment (Levenberg-Marquardt, sparse normal equations).

Residual vector layout:
  2M      image rows, normal/tangent interleaved
  n_prior K-2 ang. curvature | 3(K-2) trans. curvature | K ang. pull | 3K trans. pull |
          1 ang. gauge | 3 trans. gauge | 1 centroid-along-axis gauge
  M       depth hinge
"""
import numpy as np
import scipy.sparse as sp
import scipy.sparse.linalg as spla
from types import SimpleNamespace as NS
from . import geom, traj


def setup_problem(tr, X, O, free_parameters, free_landmarks, cam, acfg):
    p = NS()
    p.t = O[:, 0]
    p.ids = O[:, 1].astype(int)
    p.uv = O[:, 2:4]
    p.nn = geom.unit_rows(O[:, 4:6])
    p.M, p.N, p.K, p.h = O.shape[0], X.shape[0], tr['K'], tr['h']
    p.n_traj = 8 + 4 * p.K
    p.free_parameters = np.asarray(free_parameters, int).ravel()
    p.free_landmarks = np.asarray(free_landmarks, int).ravel()
    p.n_free_motion = p.free_parameters.size
    p.n_free = p.n_free_motion + 3 * p.free_landmarks.size
    p.empty = p.n_free == 0 or p.M == 0
    if p.empty:
        return p
    p.wn = p.nn
    p.wt = acfg.tangent_weight * np.c_[-p.nn[:, 1], p.nn[:, 0]]
    p.cauchy_sq = acfg.cauchy_px ** 2
    p.param_to_col = np.full(p.n_traj + 3 * p.N, -1, int)
    p.param_to_col[p.free_parameters] = np.arange(p.n_free_motion)
    L = p.free_landmarks
    p.param_to_col[(p.n_traj + 3 * L[:, None] + np.arange(3)).ravel()] = \
        p.n_free_motion + np.arange(3 * L.size)
    p.b0_idx, p.b0_val = traj.spline_basis(tr, tr['t0'])
    p.b0_idx, p.b0_val = p.b0_idx[0], p.b0_val[0]
    p.b_idx, p.b_val = traj.spline_basis(tr, p.t)
    p.tau = p.t - tr['t0']
    p.cam = cam
    p.min_depth = acfg.min_depth
    p.depth_weight = acfg.depth_weight
    p.lambda_rotation = acfg.lambda_rotation
    p.lambda_translation = acfg.lambda_translation
    p.pull_fraction = acfg.pull_fraction
    p.gauge_weight = acfg.gauge_weight
    p.centroid_weight = acfg.centroid_weight
    p.n_img = 2 * p.M
    p.n_prior = 4 * (p.K - 2) + 4 * p.K + 4 + 1
    p.n_res = p.n_img + p.n_prior + p.M
    return p


def observation_pose(p, tr):
    theta = tr['omega'] * p.tau + np.sum(p.b_val * tr['k'][p.b_idx], 1)
    corr = np.einsum('mq,mqd->md', p.b_val, tr['m'][p.b_idx])
    T = np.r_[tr['c'], 1.0] + p.tau[:, None] * tr['V'] + corr
    return geom.rodrigues(tr['a'], theta), T, theta


def image_residuals(p, tr, X):
    R, T, _ = observation_pose(p, tr)
    Y = geom.apply_pose(R, T, X[p.ids])
    z = np.maximum(Y[:, 2], p.min_depth)
    pr = p.cam.focal * Y[:, :2] / z[:, None] + p.cam.principal
    dd = p.uv - pr
    rn = np.sum(p.wn * dd, 1)
    rt = np.sum(p.wt * dd, 1)
    r_img = np.c_[rn, rt].ravel()
    r_depth = p.depth_weight * np.maximum(0, p.min_depth - Y[:, 2])
    return r_img, r_depth, Y


def prior_residuals(p, tr, X):
    k, m, h = tr['k'], tr['m'], p.h
    w_rot = p.lambda_rotation * 180 / np.pi
    w_tr = p.lambda_translation * 1000
    return np.r_[w_rot * np.diff(k, 2) / h ** 2,
                 w_tr * np.diff(m, 2, axis=0).ravel() / h ** 2,
                 p.pull_fraction * w_rot * k,
                 p.pull_fraction * w_tr * m.ravel(),
                 p.gauge_weight * (p.b0_val @ k[p.b0_idx]),
                 p.gauge_weight * (p.b0_val @ m[p.b0_idx]),
                 p.centroid_weight * (tr['a'] @ X.mean(0))]


def residuals(p, tr, X):
    r_img, r_depth, _ = image_residuals(p, tr, X)
    return np.r_[r_img, prior_residuals(p, tr, X), r_depth]


def robust_cost(p, r):
    ri = r[:p.n_img]
    return np.sum(p.cauchy_sq * np.log1p(ri ** 2 / p.cauchy_sq)) + np.sum(r[p.n_img:] ** 2)


def image_jacobian(p, tr, X):
    M, K = p.M, p.K
    R, T, theta = observation_pose(p, tr)
    Xo = X[p.ids]
    Y = geom.apply_pose(R, T, Xo)
    RX = Y - T
    valid = Y[:, 2] >= p.min_depth
    z = np.maximum(Y[:, 2], p.min_depth)
    fx, fy = p.cam.focal
    def G_of(w):
        return np.c_[w[:, 0] * fx / z, w[:, 1] * fy / z,
                     -(w[:, 0] * fx * Y[:, 0] + w[:, 1] * fy * Y[:, 1]) / z ** 2 * valid]
    G_n, G_t = G_of(p.wn), G_of(p.wt)
    G_d = np.c_[np.zeros((M, 2)), p.depth_weight * (~valid)]
    a = tr['a']
    dY_dth = np.cross(a, RX)
    t1, t2 = geom.axis_tangent(a)
    c, s = np.cos(theta)[:, None], np.sin(theta)[:, None]
    aX = Xo @ a
    dY_dax = [s * np.cross(t, Xo) + (1 - c) * (aX[:, None] * t + (Xo @ t)[:, None] * a) for t in (t1, t2)]
    Rcol = [R[:, :, d] for d in range(3)]
    obs = np.arange(M)
    rows, cols, vals = [], [], []
    for G_all, rq_all, sel in ((G_n, 2 * obs, None), (G_t, 2 * obs + 1, None),
                               (G_d, p.n_img + p.n_prior + obs, ~valid)):
        if sel is None:
            sel = slice(None)
        elif not sel.any():
            continue
        G = G_all[sel]
        rq = rq_all[sel]
        n = rq.size
        tau = p.tau[sel]
        B = p.b_val[sel]
        bI = p.b_idx[sel]
        ids = p.ids[sel]
        g_th = -np.sum(G * dY_dth[sel], 1)
        for i in range(2):
            rows.append(rq); cols.append(np.full(n, i)); vals.append(-np.sum(G * dY_dax[i][sel], 1))
        rows.append(rq); cols.append(np.full(n, 2)); vals.append(g_th * tau)
        for d in range(3):
            if d < 2:
                rows.append(rq); cols.append(np.full(n, 3 + d)); vals.append(-G[:, d])
            rows.append(rq); cols.append(np.full(n, 5 + d)); vals.append(-G[:, d] * tau)
            rows.append(rq); cols.append(p.n_traj + 3 * ids + d); vals.append(-np.sum(G * Rcol[d][sel], 1))
        for b in range(4):
            rows.append(rq); cols.append(8 + bI[:, b]); vals.append(g_th * B[:, b])
            for d in range(3):
                rows.append(rq); cols.append(8 + K + 3 * bI[:, b] + d); vals.append(-G[:, d] * B[:, b])
    return np.concatenate(rows), np.concatenate(cols), np.concatenate(vals)


def prior_jacobian(p, tr, X):
    K, N, h = p.K, p.N, p.h
    w_rot = p.lambda_rotation * 180 / np.pi
    w_tr = p.lambda_translation * 1000
    rows, cols, vals = [], [], []
    row = p.n_img
    j = np.arange(K - 2)
    for q, st in enumerate((1, -2, 1)):
        rows.append(row + j); cols.append(8 + j + q); vals.append(np.full(K - 2, st * w_rot / h ** 2))
        for d in range(3):
            rows.append(row + (K - 2) + 3 * j + d); cols.append(8 + K + 3 * (j + q) + d)
            vals.append(np.full(K - 2, st * w_tr / h ** 2))
    row += 4 * (K - 2)
    j = np.arange(K)
    rows.append(row + j); cols.append(8 + j); vals.append(np.full(K, p.pull_fraction * w_rot))
    for d in range(3):
        rows.append(row + K + 3 * j + d); cols.append(8 + K + 3 * j + d); vals.append(np.full(K, p.pull_fraction * w_tr))
    row += 4 * K
    rows.append(np.full(4, row)); cols.append(8 + p.b0_idx); vals.append(p.gauge_weight * p.b0_val)
    for d in range(3):
        rows.append(np.full(4, row + 1 + d)); cols.append(8 + K + 3 * p.b0_idx + d); vals.append(p.gauge_weight * p.b0_val)
    row += 4
    a = tr['a']
    Xbar = X.mean(0)
    for d in range(3):
        rows.append(np.full(N, row)); cols.append(p.n_traj + 3 * np.arange(N) + d)
        vals.append(np.full(N, p.centroid_weight * a[d] / N))
    t1, t2 = geom.axis_tangent(a)
    rows.append(np.array([row, row])); cols.append(np.array([0, 1]))
    vals.append(p.centroid_weight * np.array([t1 @ Xbar, t2 @ Xbar]))
    return np.concatenate(rows), np.concatenate(cols), np.concatenate(vals)


def jacobian(p, tr, X):
    ri, ci, vi = image_jacobian(p, tr, X)
    rp, cp, vp = prior_jacobian(p, tr, X)
    rows, cols, vals = np.r_[ri, rp], np.r_[ci, cp], np.r_[vi, vp]
    col = p.param_to_col[cols]
    keep = col >= 0
    return sp.csr_matrix((vals[keep], (rows[keep], col[keep])), shape=(p.n_res, p.n_free))


def apply_step(p, tr, X, d):
    full = np.zeros(p.n_traj)
    full[p.free_parameters] = d[:p.n_free_motion]
    tr = traj.increment_trajectory(tr, full)
    X = X.copy()
    X[p.free_landmarks] += d[p.n_free_motion:].reshape(-1, 3)
    return tr, X


def refine(tr, X, O, free_parameters, free_landmarks, max_iterations, cam, acfg, history=None):
    info = dict(cost=np.nan, rms=np.nan, accepted_steps=0, active_hinges=np.nan, costs=[])
    p = setup_problem(tr, X, O, free_parameters, free_landmarks, cam, acfg)
    if p.empty:
        return tr, X, info
    r = residuals(p, tr, X)
    cost = robust_cost(p, r)
    info['costs'].append(cost)
    damping = acfg.damping0
    for _ in range(max_iterations):
        J = jacobian(p, tr, X)
        sw = np.ones(p.n_res)
        sw[:p.n_img] = 1 / np.sqrt(1 + r[:p.n_img] ** 2 / p.cauchy_sq)
        Jw = sp.diags(sw) @ J
        H = (Jw.T @ Jw).tocsc()
        g = Jw.T @ (sw * r)
        Dg = np.maximum(H.diagonal(), 1e-9)
        accepted = False
        for _a in range(acfg.max_attempts):
            A = (H + sp.diags(damping * Dg)).tocsc()
            d = -spla.spsolve(A, g)
            tr_t, X_t = apply_step(p, tr, X, d)
            r_t = residuals(p, tr_t, X_t)
            c_t = robust_cost(p, r_t)
            if c_t < cost:
                tr, X, r, cost = tr_t, X_t, r_t, c_t
                damping /= acfg.damping_down
                accepted = True
                info['accepted_steps'] += 1
                break
            damping *= acfg.damping_up
        info['costs'].append(cost)
        if history is not None:
            history.append(dict(tr=traj.copy_traj(tr), X=X.copy(), cost=cost))
        if not accepted or np.linalg.norm(d) < acfg.step_tol:
            break
    info['cost'] = cost
    info['rms'] = np.sqrt(np.mean(r[0:p.n_img:2] ** 2))
    info['active_hinges'] = int(np.count_nonzero(r[p.n_img + p.n_prior:]))
    return tr, X, info


def normal_residuals(tr, X, O, cam):
    R, T = traj.pose(tr, O[:, 0])
    pr, _ = geom.project(R, T, X[O[:, 1].astype(int)], cam)
    return np.sum((O[:, 2:4] - pr) * O[:, 4:6], 1)
