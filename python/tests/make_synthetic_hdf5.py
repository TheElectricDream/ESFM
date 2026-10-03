"""SMOKE TEST ONLY - synthesise an event stream from result.mat (real trajectory and
landmarks) so the Python stages can be exercised without the dataset. Never used for figures."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import numpy as np, h5py
from esfm import matresult, traj, geom, data, config

out = sys.argv[1]
t_a, t_b = float(sys.argv[2]), float(sys.argv[3])
r = matresult.load(os.path.join(os.path.dirname(__file__), '../../output_current/result.mat'))
tr, X = r['traj_py'], r['X']
cam = data.read_calibration(config.config().camera.calibration_xml)
rng = np.random.default_rng(1)
dt = 0.002
ts, xs, ys, ps = [np.zeros(1)], [np.zeros(1)], [np.zeros(1)], [np.ones(1)]
for t in np.arange(t_a, t_b, dt):
    R, T = traj.pose(tr, [t]); R2, T2 = traj.pose(tr, [t + 1e-3])
    n = len(X)
    uv, Y = geom.project(np.repeat(R, n, 0), np.repeat(T, n, 0), X, cam)
    uv2, _ = geom.project(np.repeat(R2, n, 0), np.repeat(T2, n, 0), X, cam)
    v = (uv2 - uv) / 1e-3
    sp = np.linalg.norm(v, axis=1)
    vis = (Y[:, 2] > 0.2) & (uv[:, 0] > 0) & (uv[:, 0] < 640) & (uv[:, 1] > 0) & (uv[:, 1] < 480) & (sp > 1)
    k = np.flatnonzero(vis & (rng.random(n) < np.clip(sp * dt * 5, 0, 1)))
    nrm = v[k] / sp[k, None]; tan = np.c_[-nrm[:, 1], nrm[:, 0]]
    m = 4
    kk = np.repeat(np.arange(k.size), m)
    s = rng.uniform(-4, 4, kk.size)
    p = uv[k][kk] + s[:, None] * tan[kk] + rng.normal(0, 0.35, (kk.size, 2))
    ts.append(t + rng.uniform(0, dt, kk.size)); xs.append(p[:, 0]); ys.append(p[:, 1])
    ps.append(np.where(k[kk] % 2 == 0, 1, 0))
    nb = rng.poisson(40)
    ts.append(t + rng.uniform(0, dt, nb)); xs.append(rng.uniform(0, 640, nb)); ys.append(rng.uniform(0, 480, nb)); ps.append(rng.integers(0, 2, nb))
t = np.concatenate(ts); x = np.concatenate(xs); y = np.concatenate(ys); pol = np.concatenate(ps)
# forward Kannala-Brandt distortion, integer pixels
xn = (x - cam.principal[0]) / cam.focal[0]; yn = (y - cam.principal[1]) / cam.focal[1]
rr = np.sqrt(xn ** 2 + yn ** 2); th = np.arctan(rr); thd = th * (1 + cam.k1 * th ** 2 + cam.k2 * th ** 4)
sc = np.where(rr > 1e-9, thd / np.maximum(rr, 1e-12), 1)
xd = np.round(cam.focal[0] * xn * sc + cam.principal[0]); yd = np.round(cam.focal[1] * yn * sc + cam.principal[1])
o = np.argsort(t, kind='stable')
ok = (xd[o] >= 0) & (xd[o] < 640) & (yd[o] >= 0) & (yd[o] < 480)
o = o[ok]
with h5py.File(out, 'w') as f:
    f['timestamp'] = np.round(t[o] * 1e6).astype(np.int64)
    f['x'] = xd[o].astype(np.uint16); f['y'] = yd[o].astype(np.uint16); f['polarity'] = pol[o].astype(np.uint8)
print(len(o), 'synthetic events')
