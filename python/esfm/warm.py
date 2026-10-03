"""+warm: constant-twist warm start (axis sweep, refinement, rate profile)."""
import numpy as np
from scipy.optimize import least_squares
from . import geom


def cauchy(r, scale):
    return np.sign(r) * scale * np.sqrt(np.log1p((r / scale) ** 2))


def initial_guess(obs, tau, cam):
    vis = np.isfinite(obs[:, :, 0])
    cnt = vis.sum(1)
    cen = np.full((obs.shape[0], 2), np.nan)
    ok = cnt > 0
    cen[ok, 0] = np.nansum(obs[ok, :, 0], 1) / cnt[ok]
    cen[ok, 1] = np.nansum(obs[ok, :, 1], 1) / cnt[ok]
    cen = (cen - cam.principal) / cam.focal
    okc = np.all(np.isfinite(cen), 1) & np.isfinite(tau)
    px = np.polyfit(tau[okc], cen[okc, 0], 1)
    py = np.polyfit(tau[okc], cen[okc, 1], 1)
    return np.array([px[1], py[1]]), np.array([px[0], py[0], 0.0])


def twist_structure(a, w, q, tau, fi, ii, uv, nn, ntracks, cam, wcfg):
    Rall = geom.rodrigues(a, w * tau)
    Tall = np.r_[q[0], q[1], 1.0] + tau[:, None] * (np.asarray(q[2:5]) * float(wcfg.free_mean_velocity))
    R, T = Rall[fi], Tall[fi]
    X = geom.triangulate(R, T, ii, uv, nn, ntracks, wcfg.tangent_weight, cam)
    return X, R, T


def twist_residual(a, w, q, tau, fi, ii, uv, nn, ntracks, cam, wcfg):
    X, R, T = twist_structure(a, w, q, tau, fi, ii, uv, nn, ntracks, cam, wcfg)
    pr, Y = geom.project(R, T, X[ii], cam)
    r = np.sum((uv - pr) * nn, 1)
    r[Y[:, 2] < wcfg.min_depth] = 10
    return r


def _lsq(fun, p0, lb, ub, wcfg):
    p0 = np.clip(np.asarray(p0, float), lb + 1e-12, ub - 1e-12)
    res = least_squares(fun, p0, bounds=(lb, ub), method='trf', ftol=1e-8, xtol=1e-8,
                        max_nfev=wcfg.max_function_evals)
    return res.x


def sweep_axes(resid, nll, c0, V0, wcfg, progress=None):
    dirs = geom.hemisphere_directions(wcfg.hemisphere_directions, wcfg.base_axis)
    dirs = np.r_[dirs, -dirs]
    mc, mv = wcfg.max_centre_offset, wcfg.max_velocity_per_s
    lb = np.array([-1, -mc, -mc, -mv, -mv, -mv])
    ub = -lb
    fits = []
    for s in wcfg.rate_seeds_deg_s:
        wh = np.deg2rad(s)
        for a in dirs:
            obj = lambda p, a=a: cauchy(resid(a, p[0], p[1:6]), wcfg.cauchy_px)
            p = _lsq(obj, np.r_[wh, c0, V0], lb, ub, wcfg)
            fits.append(dict(a=a.copy(), w=p[0], q=p[1:6], seed=wh, cost=nll(a, p[0], p[1:6])))
            if progress:
                progress(len(fits), fits[-1])
    return fits


def refine_fit(f0, resid, nll, wcfg):
    a0 = f0['a']
    t1, t2 = geom.axis_tangent(a0)
    ax = lambda p: (a0 + p[0] * t1 + p[1] * t2) / np.linalg.norm(a0 + p[0] * t1 + p[1] * t2)
    mc, mv = wcfg.max_centre_offset, wcfg.max_velocity_per_s
    lb = np.array([-1, -1, -1, -mc, -mc, -mv, -mv, -mv])
    ub = -lb
    obj = lambda p: cauchy(resid(ax(p), p[2], p[3:8]), wcfg.cauchy_px)
    p = _lsq(obj, np.r_[0, 0, f0['w'], f0['q']], lb, ub, wcfg)
    return dict(a=ax(p), w=p[2], q=p[3:8], seed=f0['seed'], cost=nll(ax(p), p[2], p[3:8]))


def rate_profile(best, resid, nll, wcfg, rates=None):
    if rates is None:
        rates = np.arange(1, 12.0001, 0.2)
    mc, mv = wcfg.max_centre_offset, wcfg.max_velocity_per_s
    lb = np.array([-mc, -mc, -mv, -mv, -mv])
    ub = -lb
    prof = np.full(len(rates), np.nan)
    for k, r in enumerate(rates):
        w = np.deg2rad(r)
        q = _lsq(lambda q: cauchy(resid(best['a'], w, q), wcfg.cauchy_px), best['q'], lb, ub, wcfg)
        prof[k] = nll(best['a'], w, q)
    return rates, prof
