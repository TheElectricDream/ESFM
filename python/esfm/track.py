"""+track: alpha-beta tracking of flow-warped events (warm start)."""
import numpy as np
from scipy.spatial import cKDTree


def _ball(points, queries, r):
    if len(points) == 0:
        return [np.zeros(0, int) for _ in range(len(queries))]
    out = cKDTree(points).query_ball_point(queries, r)
    return [np.asarray(o, int) for o in out]


def track_events(t, x, y, flow, slice_dt, tcfg, record=None):
    """track.track_events. If `record` is a dict, per-slice snapshots of the
    live tracks are appended to record['slices'] (for figures)."""
    o = np.argsort(t, kind='stable')
    T, X, Y, F = t[o], x[o], y[o], flow[o]
    # MATLAB colon: T(1):dt:T(end)+dt  (inclusive of the end when it lands on it)
    n_e = int(np.floor((T[-1] + slice_dt - T[0]) / slice_dt + 1e-10)) + 1
    edges = T[0] + slice_dt * np.arange(n_e)
    slice_times = edges[:-1] + slice_dt / 2
    bounds = np.r_[np.searchsorted(T, edges, 'left'), T.size]
    live, done = [], []
    for k in range(len(edges) - 1):
        lo, hi = bounds[k], bounds[k + 1]
        tc = slice_times[k]
        eX, eY, eF, eT = X[lo:hi], Y[lo:hi], F[lo:hi], T[lo:hi]
        wx = eX - eF[:, 0] * (eT - tc)
        wy = eY - eF[:, 1] * (eT - tc)
        W = np.c_[wx, wy]
        used = np.zeros(wx.size, bool)
        if live:
            dTp = tc - np.array([l['t'] for l in live])
            pX = np.array([l['x'] for l in live]) + np.array([l['vx'] for l in live]) * dTp
            pY = np.array([l['y'] for l in live]) + np.array([l['vy'] for l in live]) * dTp
            nbs = _ball(W, np.c_[pX, pY], tcfg.gate_px)
            for i, l in enumerate(live):
                nb = nbs[i]
                nb = nb[~used[nb]]
                if nb.size >= tcfg.min_events:
                    used[nb] = True
                    zX, zY = wx[nb].mean(), wy[nb].mean()
                    l['vx'] += tcfg.gain_velocity * (zX - pX[i]) / dTp[i]
                    l['vy'] += tcfg.gain_velocity * (zY - pY[i]) / dTp[i]
                    l['x'] = pX[i] + tcfg.gain_position * (zX - pX[i])
                    l['y'] = pY[i] + tcfg.gain_position * (zY - pY[i])
                    l['t'] = tc
                    nv = eF[nb].mean(0)
                    nv = nv / max(np.linalg.norm(nv), 1e-9)
                    l['hist'].append([tc, l['x'], l['y'], nv[0], nv[1]])
                    l['miss'] = 0
                else:
                    l['miss'] += 1
            done += [l for l in live if l['miss'] > tcfg.max_miss]
            live = [l for l in live if l['miss'] <= tcfg.max_miss]
        un = np.flatnonzero(~used)
        if un.size:
            key = (np.floor(wy[un] / tcfg.seed_cell_px) * 10000 + np.floor(wx[un] / tcfg.seed_cell_px))
            _, inv, cnt = np.unique(key, return_inverse=True, return_counts=True)
            for c in np.flatnonzero(cnt >= tcfg.min_events):
                e = un[inv == c]
                nv = eF[e].mean(0)
                nv = nv / max(np.linalg.norm(nv), 1e-9)
                mxw, myw = wx[e].mean(), wy[e].mean()
                live.append(dict(x=mxw, y=myw, vx=eF[e, 0].mean(), vy=eF[e, 1].mean(), t=tc,
                                 hist=[[tc, mxw, myw, nv[0], nv[1]]], miss=0))
        if record is not None:
            record.setdefault('slices', []).append(dict(
                tc=tc, n_events=wx.size, n_used=int(used.sum()), n_live=len(live)))
    done += live
    tracks = [np.array(l['hist']) for l in done if len(l['hist']) >= tcfg.min_length]
    return tracks, slice_times


def build_observations(tracks, slice_times):
    F, N = len(slice_times), len(tracks)
    obs = np.full((F, N, 4), np.nan)
    keep = np.zeros(N, bool)
    for k, h in enumerate(tracks):
        if h.shape[0] < 2:
            continue
        fi = np.searchsorted(slice_times, h[:, 0] - 1e-9)
        fi = np.clip(fi, 0, F - 1)
        assert np.allclose(slice_times[fi], h[:, 0], atol=1e-9)
        obs[fi, k, :] = h[:, 1:5]
        keep[k] = True
    return obs[:, keep], np.flatnonzero(keep)


def flatten_observations(obs):
    """MATLAB find() order: by track, then frame."""
    ii, fi = np.nonzero(np.isfinite(obs[:, :, 0]).T)
    uv = obs[fi, ii, 0:2]
    from .geom import unit_rows
    nn = unit_rows(obs[fi, ii, 2:4])
    return fi, ii, uv, nn
