"""+traj: constant-rate spin about a fixed axis + uniform cubic B-spline corrections.

theta(t) = omega*(t - t0) + sum_j k_j B_j(t)
T(t)     = [cx, cy, 1] + (t - t0) V + sum_j m_j B_j(t)
Parameter vector (8 + 4K, 0-based):
  0:2 axis tangent step, 2 omega, 3:5 c, 5:8 V, 8:8+K k, 8+K: m (x,y,z per coefficient)
"""
import copy
import numpy as np
from . import geom


def create_trajectory(t0, t1, h):
    n_seg = int(np.ceil((t1 - t0) / h)) + 2
    K = n_seg + 3
    return dict(t0=t0, h=h, n_seg=n_seg, K=K, knot_t=t0 + h * (np.arange(K) - 1),
                a=np.array([0.0, -1.0, 0.0]), omega=0.1, c=np.zeros(2), V=np.zeros(3),
                k=np.zeros(K), m=np.zeros((K, 3)))


def copy_traj(tr):
    return copy.deepcopy(tr)


def spline_basis(tr, t):
    u = (np.atleast_1d(np.asarray(t, float)) - tr['t0']) / tr['h']
    j = np.minimum(np.maximum(np.floor(u), 0), tr['n_seg'] - 1)
    s = np.minimum(np.maximum(u - j, -0.5), 1.5)
    val = np.c_[(1 - s) ** 3, 3 * s ** 3 - 6 * s ** 2 + 4, -3 * s ** 3 + 3 * s ** 2 + 3 * s + 1, s ** 3] / 6
    idx = j.astype(int)[:, None] + np.arange(4)
    return idx, val


def spline_eval(tr, t, coef):
    idx, val = spline_basis(tr, t)
    coef = np.asarray(coef)
    if coef.ndim == 1:
        return np.sum(val * coef[idx], 1)
    return np.einsum('mq,mqd->md', val, coef[idx])


def spline_active(tr, ta, tb):
    ia, _ = spline_basis(tr, ta)
    ib, _ = spline_basis(tr, tb)
    return np.arange(ia[0, 0], ib[0, 3] + 1)


def angle(tr, t):
    t = np.atleast_1d(np.asarray(t, float))
    return tr['omega'] * (t - tr['t0']) + spline_eval(tr, t, tr['k'])


def translation(tr, t):
    t = np.atleast_1d(np.asarray(t, float))
    return np.r_[tr['c'], 1.0] + (t - tr['t0'])[:, None] * tr['V'] + spline_eval(tr, t, tr['m'])


def pose(tr, t):
    return geom.rodrigues(tr['a'], angle(tr, t)), translation(tr, t)


def rate_deg_s(tr, t, d=0.05):
    t = np.atleast_1d(np.asarray(t, float))
    return np.rad2deg(angle(tr, t + d) - angle(tr, t - d)) / (2 * d)


def increment_trajectory(tr, p):
    K = tr['K']
    assert p.size == 8 + 4 * K
    tr = copy_traj(tr)
    t1, t2 = geom.axis_tangent(tr['a'])
    a = tr['a'] + p[0] * t1 + p[1] * t2
    tr['a'] = a / np.linalg.norm(a)
    tr['omega'] = tr['omega'] + p[2]
    tr['c'] = tr['c'] + p[3:5]
    tr['V'] = tr['V'] + p[5:8]
    tr['k'] = tr['k'] + p[8:8 + K]
    tr['m'] = tr['m'] + p[8 + K:].reshape(K, 3)
    return tr


def select_free_parameters(tr, mean_free, knots_upto=None, knots_from=None, free_V=False):
    cols = list(range(8) if free_V else range(5)) if mean_free else []
    if knots_upto is not None:
        if knots_from is None:
            knots_from = tr['t0']
        j = spline_active(tr, knots_from, knots_upto)
        cols += list(8 + j)
        cols += list((8 + tr['K'] + 3 * j[:, None] + np.arange(3)).ravel())
    return np.array(cols, int)


def sample_refined_trajectory(tr, time_s, m_per_unit):
    R, T = pose(tr, time_s)
    return dict(time_s=time_s, R=R, T_model=T, T_m=m_per_unit * T,
                angle_rad=angle(tr, time_s), rate_deg_s=rate_deg_s(tr, time_s))
