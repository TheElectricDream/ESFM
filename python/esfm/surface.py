"""+surface: local plane fits in (x, y, t) -> accept mask + normal flow."""
import numpy as np
from types import SimpleNamespace as NS


def _group(*cols):
    """findgroups over integer columns, lexicographic order (first column slowest)."""
    key = np.zeros(cols[0].shape, np.int64)
    for c in cols:
        c = c.astype(np.int64)
        lo = c.min()
        key = key * (int(c.max() - lo) + 1) + (c - lo)
    _, inv = np.unique(key, return_inverse=True)
    return inv


def fit_cells(t, x, y, scfg, offset, debug=False):
    ix = np.floor((x + offset[0]) / scfg.cell_px)
    iy = np.floor((y + offset[1]) / scfg.cell_px)
    it = np.floor((t + offset[2]) / scfg.cell_s)
    inv = _group(it, iy, ix)
    C = inv.max() + 1
    tau = t / scfg.sigma_s
    S = lambda w: np.bincount(inv, w, C)
    n = np.bincount(inv, minlength=C).astype(float)
    ns = np.maximum(n, 1)
    mx, my, mt = S(x) / ns, S(y) / ns, S(tau) / ns
    dx, dy, dt = x - mx[inv], y - my[inv], tau - mt[inv]
    cov = np.empty((C, 3, 3))
    cov[:, 0, 0] = S(dx * dx) / ns
    cov[:, 1, 1] = S(dy * dy) / ns
    cov[:, 2, 2] = S(dt * dt) / ns
    cov[:, 0, 1] = cov[:, 1, 0] = S(dx * dy) / ns
    cov[:, 0, 2] = cov[:, 2, 0] = S(dx * dt) / ns
    cov[:, 1, 2] = cov[:, 2, 1] = S(dy * dt) / ns
    del dx, dy, dt

    nrm = np.tile([0.0, 0.0, 1.0], (C, 1))
    w_mid = np.zeros(C)
    w_min = np.ones(C)
    v = np.flatnonzero(n >= scfg.min_events_per_cell)
    if v.size:
        d, V = np.linalg.eigh(cov[v])
        nrm[v] = V[:, :, 0]
        w_min[v] = d[:, 0]
        w_mid[v] = d[:, 1]
    planarity = w_min / np.maximum(w_mid, 1e-12)
    ok = (n >= scfg.min_events_per_cell) & (np.abs(nrm[:, 2]) > scfg.min_time_normal)

    nz = nrm[:, 2].copy()
    nz[np.abs(nz) <= 1e-9] = 1e-9
    g = -nrm[:, :2] * scfg.sigma_s / nz[:, None]
    vel = g / np.maximum(np.sum(g ** 2, 1), 1e-12)[:, None]

    v_ev = vel[inv]
    tc = mt[inv] * scfg.sigma_s
    xw = np.round(x - v_ev[:, 0] * (t - tc))
    yw = np.round(y - v_ev[:, 1] * (t - tc))
    wkey = inv.astype(np.int64) * 10_000_000 + ((yw + 1000) * 3000 + (xw + 1000)).astype(np.int64)
    _, winv, wcnt = np.unique(wkey, return_inverse=True, return_counts=True)

    f = NS(ok=ok[inv], vel=v_ev, planarity=planarity[inv], support=wcnt[winv])
    if debug:
        f.dbg = NS(inv=inv, n=n, mx=mx, my=my, mt=mt * scfg.sigma_s, nrm=nrm, w_min=w_min,
                   w_mid=w_mid, planarity=planarity, ok=ok, vel=vel, xw=xw, yw=yw,
                   wcnt=wcnt, winv=winv, cov=cov)
    return f


def compute(ev, scfg, time_range=None, chunk_s=None):
    """surface.compute. chunk_s optionally processes the recording in time
    chunks aligned to the coarse cell grid (identical result, less memory)."""
    N = ev.t.size
    accept = np.zeros(N, bool)
    flow = np.zeros((N, 2))
    target = np.ones(N, bool)
    support = np.ones(N, bool)
    if time_range is not None:
        target = (ev.t >= time_range[0]) & (ev.t < time_range[1])
        support = (ev.t >= time_range[0] - scfg.cell_s) & (ev.t < time_range[1] + scfg.cell_s)
    if not target.any():
        return accept, flow
    groups = [ev.p > 0, ev.p <= 0] if scfg.split_polarities else [np.ones(N, bool)]
    offsets = [np.zeros(3)]
    if scfg.two_offset_grids:
        offsets.append(np.array([scfg.cell_px / 2, scfg.cell_px / 2, scfg.cell_s / 2]))

    if chunk_s is None:
        windows = [(-np.inf, np.inf)]
    else:
        # chunk boundaries on multiples of cell_s; each chunk is fitted with
        # one cell of padding so both grids see complete cells
        c = scfg.cell_s * max(1, round(chunk_s / scfg.cell_s))
        t0 = np.floor(ev.t.min() / c) * c
        edges = np.arange(t0, ev.t.max() + c, c)
        windows = list(zip(edges[:-1], edges[1:]))

    for gmask in groups:
        gsel = gmask & support
        for (w0, w1) in windows:
            pad = scfg.cell_s if np.isfinite(w0) else 0
            fit_sel = gsel & (ev.t >= w0 - pad) & (ev.t < w1 + pad)
            idx = np.flatnonzero(fit_sel)
            if idx.size == 0:
                continue
            best_ok = np.zeros(idx.size, bool)
            best_pl = np.full(idx.size, np.inf)
            best_v = np.zeros((idx.size, 2))
            for off in offsets:
                f = fit_cells(ev.t[idx], ev.x[idx], ev.y[idx], scfg, off)
                ok = f.ok & (f.planarity <= scfg.max_planarity_ratio) & (f.support >= scfg.min_warped_support)
                better = ok & (f.planarity < best_pl)
                best_ok[better] = True
                best_pl[better] = f.planarity[better]
                best_v[better] = f.vel[better]
            own = target[idx] & (ev.t[idx] >= w0) & (ev.t[idx] < w1)
            accept[idx[own]] = best_ok[own]
            flow[idx[own]] = best_v[own]
    return accept, flow
