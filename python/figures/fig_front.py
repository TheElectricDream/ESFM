"""Figures for the front end: events, undistortion, plane fits, normal flow, warping."""
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
from types import SimpleNamespace as NS
from style import *  # noqa
from esfm import config, data, geom, surface

cfg = config.config(start_time_s=float(os.environ.get('ESFM_T0', 60)), end_time_s=float(os.environ.get('ESFM_T1', 185)))
cam = data.read_calibration(cfg.camera.calibration_xml)
E = npz('events')
S = npz('surface')
t, x, y, p = E['t'], E['x'], E['y'], E['p']
acc, flow = S['accept'], S['flow']
T0 = cfg.data.start_time_s
W, H = cam.image_size


def busiest(width, t_lo, t_hi, mask=None):
    """Start time of the busiest window of `width` seconds in [t_lo, t_hi)."""
    sel = (t >= t_lo) & (t < t_hi) if mask is None else mask & (t >= t_lo) & (t < t_hi)
    edges = np.arange(t_lo, t_hi, width / 4)
    c, _ = np.histogram(t[sel], edges)
    k = np.convolve(c, np.ones(4), 'valid')
    return edges[int(np.argmax(k))]


# ---------------------------------------------------------------- F02 event stream
def f_event_stream():
    ta = busiest(0.3, T0, T0 + 6)
    sel = np.flatnonzero((t >= ta) & (t < ta + 0.3))
    rng = np.random.default_rng(0)
    sel = np.sort(rng.choice(sel, min(9000, sel.size), replace=False))
    fig = plt.figure(figsize=(5.4, 3.35))
    ax = fig.add_axes([-0.06, -0.06, 1.1, 1.14], projection='3d')
    ms = (t[sel] - ta) * 1e3
    for pol, col in ((1, POS), (-1, NEG)):
        k = p[sel] == pol
        ax.scatter(x[sel][k], ms[k], y[sel][k], s=0.6, c=col, alpha=0.75, linewidths=0, depthshade=False)
    ax.set_xlim(0, W); ax.set_zlim(H, 0); ax.set_ylim(0, 300)
    ax.set_xlabel('x [px]', labelpad=-4); ax.set_ylabel('time [ms]', labelpad=-2); ax.set_zlabel('y [px]', labelpad=-6)
    ax.tick_params(labelsize=7, pad=-2)
    ax.view_init(elev=14, azim=-58)
    ax.set_box_aspect((1.2, 1.6, 0.9))
    for a in (ax.xaxis, ax.yaxis, ax.zaxis):
        a.pane.set_facecolor((1, 1, 1, 0)); a.pane.set_edgecolor(LIGHT); a._axinfo['grid']['color'] = PALE
    n_per_s = ((t >= ta) & (t < ta + 0.3)).sum() / 0.3
    fig.text(0.03, 0.93, f'{sel.size:,} of {n_per_s*0.3:,.0f} events shown  ·  t = {ta:.2f}–{ta+0.3:.2f} s', fontsize=8, color=DARK)
    fig.text(0.03, 0.87, '● ON (+1)', color=POS, fontsize=8.5); fig.text(0.17, 0.87, '● OFF (−1)', color=NEG, fontsize=8.5)
    save(fig, 'F02_event_stream')
    return dict(t_window=ta, rate=n_per_s)


# ---------------------------------------------------------------- F03 undistortion
def f_undistort():
    gx, gy = np.meshgrid(np.arange(0, W + 1, 4.0), np.arange(0, H + 1, 4.0))
    und = geom.undistort_equidistant(np.c_[gx.ravel(), gy.ravel()], cam)
    d = np.linalg.norm(und - np.c_[gx.ravel(), gy.ravel()], axis=1).reshape(gx.shape)
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.1, right=0.86, bottom=0.14, top=0.95)
    from matplotlib.colors import PowerNorm
    im = ax.imshow(d, extent=(0, W, H, 0), cmap=CMAP_RED, norm=PowerNorm(0.5, vmin=0, vmax=d.max()))
    cs = ax.contour(gx, gy, d, levels=[1, 5, 15, 40, 80, 120], colors=DARK, linewidths=0.5)
    ax.clabel(cs, fmt='%g px', fontsize=7)
    qx, qy = np.meshgrid(np.arange(20, W, 48.0), np.arange(20, H, 48.0))
    qu = geom.undistort_equidistant(np.c_[qx.ravel(), qy.ravel()], cam) - np.c_[qx.ravel(), qy.ravel()]
    ax.quiver(qx.ravel(), qy.ravel(), qu[:, 0], qu[:, 1], color=BLACK, angles='xy', scale_units='xy', scale=1/0.3, width=0.0035)
    ax.plot(*cam.principal, marker='+', color=BLACK, ms=9, mew=1.2)
    ax.set_xlabel('x [px]'); ax.set_ylabel('y [px]')
    cb = fig.colorbar(im, ax=ax, fraction=0.04, pad=0.02); cb.set_label('shift [px]'); cb.outline.set_visible(False)
    ax.text(0.01, 1.01, 'arrows ×0.3', transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F03_undistortion')
    return dict(max_shift_px=float(d.max()), k1=cam.k1, focal=cam.focal.tolist(), principal=cam.principal.tolist())


# ---------------------------------------------------------------- F04 plane fit of one cell
def pick_cell(t_lo):
    s = cfg.surface
    sel = np.flatnonzero((t >= t_lo) & (t < t_lo + 2 * s.cell_s) & (p > 0))
    f = surface.fit_cells(t[sel], x[sel], y[sel], s, np.zeros(3), debug=True)
    d = f.dbg
    good = np.flatnonzero(d.ok & (d.planarity < 0.08) & (d.n > 40) & (d.n < 160)
                          & (np.hypot(d.vel[:, 0], d.vel[:, 1]) > 3))
    if good.size == 0:
        good = np.flatnonzero(d.ok)
    c = good[np.argmax(d.n[good])]
    return sel, d, c


def f_plane_fit():
    s = cfg.surface
    t_lo = np.floor((T0 + 1.6) / s.cell_s) * s.cell_s
    sel, d, c = pick_cell(t_lo)
    k = sel[d.inv == c]
    tt = (t[k] - t[k].min()) * 1e3
    fig = plt.figure(figsize=(5.4, 3.35))
    ax = fig.add_axes([-0.08, -0.05, 0.72, 1.1], projection='3d')
    ax.scatter(x[k], y[k], tt, c=tt, cmap=CMAP_TIME, s=9, depthshade=False, edgecolors='none')
    # plane through the centroid with normal (in x, y, tau = t/sigma) -> back to ms
    nrm = d.nrm[c]
    mx, my, mt = d.mx[c], d.my[c], d.mt[c]
    gx, gy = np.meshgrid(np.linspace(x[k].min(), x[k].max(), 8), np.linspace(y[k].min(), y[k].max(), 8))
    tau = mt / s.sigma_s - (nrm[0] * (gx - mx) + nrm[1] * (gy - my)) / nrm[2]
    gz = (tau * s.sigma_s - t[k].min()) * 1e3
    m = (gz > -50) & (gz < tt.max() + 50)
    gz = np.where(m, gz, np.nan)
    ax.plot_surface(gx, gy, gz, color=RED, alpha=0.18, linewidth=0, shade=False)
    ax.plot_wireframe(gx, gy, gz, color=RED, linewidth=0.4, alpha=0.6)
    ax.set_xlabel('x [px]', labelpad=-3); ax.set_ylabel('y [px]', labelpad=-3); ax.set_zlabel('t [ms]', labelpad=-4)
    ax.tick_params(labelsize=7, pad=-2)
    ax.view_init(elev=18, azim=-40)
    for a in (ax.xaxis, ax.yaxis, ax.zaxis):
        a.pane.set_facecolor((1, 1, 1, 0)); a.pane.set_edgecolor(LIGHT); a._axinfo['grid']['color'] = PALE
    ev = np.linalg.eigvalsh(d.cov[c])
    v = d.vel[c]
    txt = (f'cell: {s.cell_px}×{s.cell_px} px × {s.cell_s:.1f} s\n'
           f'events: {int(d.n[c])}\n\n'
           f'$\\lambda_1$ = {ev[0]:.2f}\n$\\lambda_2$ = {ev[1]:.2f}\n$\\lambda_3$ = {ev[2]:.2f}\n\n'
           f'planarity $\\lambda_1/\\lambda_2$ = {ev[0]/ev[1]:.3f}\n'
           f'$|n_t|$ = {abs(nrm[2]):.2f}\n\n'
           f'flow = ({v[0]:.1f}, {v[1]:.1f}) px/s')
    fig.text(0.70, 0.5, txt, fontsize=8.5, color=DARK, va='center', linespacing=1.35)
    save(fig, 'F04_plane_fit')
    return dict(cell_events=int(d.n[c]), eig=ev.tolist(), vel=v.tolist(), t_lo=t_lo)


# ---------------------------------------------------------------- F05 normal-flow field
def f_normal_flow():
    ta = busiest(0.1, T0 + 1, T0 + 6, acc)
    sel = (t >= ta) & (t < ta + 0.1)
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.1, right=0.98, bottom=0.14, top=0.95)
    ax.scatter(x[sel & ~acc], y[sel & ~acc], s=0.3, c=LIGHT, linewidths=0, rasterized=False)
    a = np.flatnonzero(sel & acc)
    ax.scatter(x[a], y[a], s=0.5, c=DARK, linewidths=0)
    # one arrow per 8 px block (mean flow) to keep it legible
    key = (np.floor(y[a] / 8) * 1000 + np.floor(x[a] / 8)).astype(int)
    u, inv, cnt = np.unique(key, return_inverse=True, return_counts=True)
    fx = np.bincount(inv, flow[a, 0]) / cnt; fy = np.bincount(inv, flow[a, 1]) / cnt
    cx = np.bincount(inv, x[a]) / cnt; cy = np.bincount(inv, y[a]) / cnt
    k = cnt >= 6
    ang = np.arctan2(fy[k], fx[k])
    ax.quiver(cx[k], cy[k], fx[k], fy[k], ang, cmap='twilight', angles='xy', scale_units='xy', scale=1.0,
              width=0.0035, headwidth=3.5, headlength=4)
    ax.set_xlim(0, W); ax.set_ylim(H, 0); ax.set_aspect('equal')
    ax.set_xlabel('x [px]'); ax.set_ylabel('y [px]')
    sp = np.hypot(flow[a, 0], flow[a, 1])
    ax.text(0.01, 1.01, f't = {ta:.2f}–{ta+0.1:.2f} s   arrows = 1 s of motion   median |v| = {np.median(sp):.1f} px/s',
            transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F05_normal_flow')
    return dict(t=ta, median_speed=float(np.median(sp)), n_acc=int(a.size), n_all=int(sel.sum()))


# ---------------------------------------------------------------- F06 acceptance tests
def f_accept():
    s = cfg.surface
    t_lo = np.floor((T0 + 2.0) / s.cell_s) * s.cell_s
    sel = np.flatnonzero((t >= t_lo) & (t < t_lo + 4 * s.cell_s) & (p > 0))
    f = surface.fit_cells(t[sel], x[sel], y[sel], s, np.zeros(3), debug=True)
    d = f.dbg
    big = d.n >= s.min_events_per_cell
    sup = np.zeros(d.n.size)
    np.maximum.at(sup, d.inv, f.support)  # best warped support per cell
    pl, nt = d.planarity[big], np.abs(d.nrm[big, 2])
    ok = (pl <= s.max_planarity_ratio) & (nt > s.min_time_normal) & (sup[big] >= s.min_warped_support)
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.12, right=0.97, bottom=0.15, top=0.93)
    ax.scatter(pl[~ok], nt[~ok], s=7, c=GREY, alpha=0.55, linewidths=0, label='rejected')
    ax.scatter(pl[ok], nt[ok], s=7, c=RED, alpha=0.75, linewidths=0, label='accepted')
    ax.axvline(s.max_planarity_ratio, color=BLACK, lw=0.8, ls='--')
    ax.axhline(s.min_time_normal, color=BLACK, lw=0.8, ls='--')
    ax.set_yscale('log'); ax.set_xlim(0, 1.0); ax.set_ylim(1e-3, 1.05)
    ax.set_xlabel('planarity  $\\lambda_1/\\lambda_2$'); ax.set_ylabel('time component of normal  $|n_t|$')
    ax.text(s.max_planarity_ratio + 0.01, 1.2e-3, f'{s.max_planarity_ratio}', fontsize=8)
    ax.text(0.92, s.min_time_normal * 1.12, f'{s.min_time_normal}', fontsize=8)
    ax.legend(loc='lower right', markerscale=2.5, bbox_to_anchor=(1.0, 0.08))
    tot = (t >= T0) & (t < cfg.data.end_time_s)
    ax.text(0.01, 1.02, f'{big.sum():,} cells (ON events, {4*s.cell_s:.1f} s)   ·   whole run: {100*acc[tot].mean():.1f} % of events accepted',
            transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F06_accept')
    return dict(cells=int(big.sum()), cells_ok=int(ok.sum()), frac_events=float(acc[tot].mean()))


# ---------------------------------------------------------------- F07 warping sharpens edges
def f_warp():
    ta = busiest(0.1, T0 + 1, T0 + 6, acc)
    tc = ta + 0.05
    a = np.flatnonzero(acc & (t >= ta) & (t < ta + 0.1))
    wx = x[a] - flow[a, 0] * (t[a] - tc)
    wy = y[a] - flow[a, 1] * (t[a] - tc)
    # zoom on the densest 120x90 px window
    img = event_image(x[a], y[a], None, signed=False)
    from scipy.ndimage import uniform_filter
    sm = uniform_filter(img, (90, 120))
    cy, cx = np.unravel_index(np.argmax(sm), sm.shape)
    x0, y0 = np.clip(cx - 60, 0, W - 120), np.clip(cy - 45, 0, H - 90)
    def contrast(px, py):
        im = event_image(px, py, None, signed=False)[y0:y0 + 90, x0:x0 + 120]
        return im.var()
    c0, c1 = contrast(x[a], y[a]), contrast(wx, wy)
    fig, axs = plt.subplots(1, 2, figsize=(5.4, 3.0), sharey=True)
    fig.subplots_adjust(left=0.1, right=0.98, bottom=0.16, top=0.86, wspace=0.06)
    for ax, (px, py), ttl, c in ((axs[0], (x[a], y[a]), 'raw positions', c0), (axs[1], (wx, wy), 'warped to $t_c$', c1)):
        m = (px >= x0) & (px < x0 + 120) & (py >= y0) & (py < y0 + 90)
        ax.scatter(px[m], py[m], s=1.2, c=(t[a][m] - ta) * 1e3, cmap=CMAP_TIME, vmin=0, vmax=100, linewidths=0)
        ax.set_xlim(x0, x0 + 120); ax.set_ylim(y0 + 90, y0); ax.set_aspect('equal')
        ax.set_title(f'{ttl}\nimage variance {c:.2f}', fontsize=9, fontweight='normal', color=DARK)
        ax.set_xlabel('x [px]')
    axs[0].set_ylabel('y [px]')
    fig.text(0.1, 0.02, f'0.1 s slice at t = {ta:.2f} s, colour = event time (0–100 ms)', fontsize=7.5, color=DARK)
    save(fig, 'F07_warp')
    return dict(t=ta, var_raw=float(c0), var_warp=float(c1), n=int(a.size))


if __name__ == '__main__':
    import json
    out = {}
    for f in (f_event_stream, f_undistort, f_plane_fit, f_normal_flow, f_accept, f_warp):
        out[f.__name__] = f()
    json.dump(out, open(os.path.join(OUT, 'facts_front.json'), 'w'), indent=1, default=float)
