"""Stage 4 - constant-twist warm start: initial guess, axis sweep, refinement, rate profile."""
import numpy as np
from common import get_cfg, get_cam, save, load, Timer
from esfm import warm

cfg = get_cfg()
cam = get_cam(cfg)
W = load('warm_tracks')
obs, fi, ii, uv, nn = W['obs'], W['fi'], W['ii'], W['uv'], W['nn']
tau = W['slice_times'] - cfg.data.start_time_s
ntracks = obs.shape[1]
c0, V0 = warm.initial_guess(obs, tau, cam)
resid = lambda a, w, q: warm.twist_residual(a, w, q, tau, fi, ii, uv, nn, ntracks, cam, cfg.warm)
nll = lambda a, w, q: np.sum(warm.cauchy(resid(a, w, q), cfg.warm.cauchy_px) ** 2)
with Timer('sweep'):
    fits = warm.sweep_axes(resid, nll, c0, V0, cfg.warm)
costs = np.array([f['cost'] for f in fits])
best = fits[int(np.nanargmin(costs))]
with Timer('refine'):
    refined = warm.refine_fit(best, resid, nll, cfg.warm)
print('coarse', np.rad2deg(best['w']), best['a'], best['cost'])
print('refined', np.rad2deg(refined['w']), refined['a'], refined['cost'])
with Timer('rate profile'):
    rates, prof = warm.rate_profile(refined, resid, nll, cfg.warm)
save('warm_fit', dict(c0=c0, V0=V0, fits=fits, best=best, refined=refined, rates=rates, profile=prof, tau=tau))
