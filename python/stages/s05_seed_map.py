"""Stage 5 - trajectory init, seed triangulation and first joint refinement (geom.triangulate, adjust.refine)."""
import numpy as np
from common import get_cfg, get_cam, save, load, Timer
from esfm import traj, geom, adjust

cfg = get_cfg()
cam = get_cam(cfg)
W = load('warm_tracks')
F = load('warm_fit')
b = F['refined']
fi, ii, uv, nn = W['fi'], W['ii'], W['uv'], W['nn']
st = W['slice_times']
ntracks = W['obs'].shape[1]
tr = traj.create_trajectory(cfg.data.start_time_s, cfg.data.end_time_s, cfg.traj.knot_spacing_s)
tr['a'] = b['a'].copy()
tr['omega'] = b['w']
tr['c'] = b['q'][:2].copy()
tr['V'] = b['q'][2:5] * float(cfg.warm.free_mean_velocity)
R, T = traj.pose(tr, st)
X0, cov0 = geom.triangulate(R[fi], T[fi], ii, uv, nn, ntracks, cfg.warm.tangent_weight, cam, return_cov=True)
O = np.c_[st[fi], ii, uv, nn]
free = traj.select_free_parameters(tr, True, None, None, cfg.warm.free_mean_velocity)
hist = []
with Timer('seed refine'):
    tr1, X1, info = adjust.refine(tr, X0, O, free, np.arange(ntracks), cfg.warm.adjust_iterations, cam, cfg.adjust, history=hist)
dn0 = adjust.normal_residuals(tr, X0, O, cam)
dn1 = adjust.normal_residuals(tr1, X1, O, cam)
print(f'seed: {ntracks} landmarks, {len(O)} obs, RMS {np.sqrt(np.mean(dn0**2)):.3f} -> {np.sqrt(np.mean(dn1**2)):.3f} px')
save('seed_map', dict(traj0=tr, X0=X0, cov0=cov0, O=O, traj=tr1, X=X1, info=info, history=hist, dn0=dn0, dn1=dn1))
