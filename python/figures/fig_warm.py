"""Figures for the warm start (tracks, twist model, triangulation, residuals, sweep) and the seed BA."""
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from style import *  # noqa
from esfm import config, data, geom, warm, traj, adjust

cfg = config.config(start_time_s=float(os.environ.get('ESFM_T0', 60)), end_time_s=float(os.environ.get('ESFM_T1', 185)))
cam = data.read_calibration(cfg.camera.calibration_xml)
Wt = load('warm_tracks')
Fw = load('warm_fit')
Sm = load('seed_map')
T0 = cfg.data.start_time_s
W, H = cam.image_size
obs, fi, ii, uv, nn, st = Wt['obs'], Wt['fi'], Wt['ii'], Wt['uv'], Wt['nn'], Wt['slice_times']
tau = st - T0
ntr = obs.shape[1]
best = Fw['refined']


def pane3d(ax):
    for a in (ax.xaxis, ax.yaxis, ax.zaxis):
        a.pane.set_facecolor((1, 1, 1, 0)); a.pane.set_edgecolor(LIGHT); a._axinfo['grid']['color'] = PALE
    ax.tick_params(labelsize=7, pad=-2)


# ---------------------------------------------------------------- F08 tracks
def f_tracks():
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.1, right=0.9, bottom=0.14, top=0.95)
    from matplotlib.collections import LineCollection
    segs, cols = [], []
    for k in range(ntr):
        f = np.flatnonzero(np.isfinite(obs[:, k, 0]))
        P = obs[f, k, :2]
        segs += [P[i:i + 2] for i in range(len(P) - 1)]
        cols += list(tau[f[:-1]])
    lc = LineCollection(segs, array=np.array(cols), cmap=CMAP_TIME, linewidths=0.9)
    ax.add_collection(lc)
    ax.set_xlim(0, W); ax.set_ylim(H, 0); ax.set_aspect('equal')
    ax.set_xlabel('x [px]'); ax.set_ylabel('y [px]')
    cb = fig.colorbar(lc, ax=ax, fraction=0.035, pad=0.02); cb.set_label('time since $t_0$ [s]'); cb.outline.set_visible(False)
    lens = np.isfinite(obs[:, :, 0]).sum(0)
    ax.text(0.01, 1.01, f'{ntr} tracks ≥ {cfg.track.min_length} samples  ·  median length {np.median(lens):.0f} slices  ·  warm window {cfg.warm.duration_s:.0f} s',
            transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F08_tracks')
    return dict(n_tracks=int(ntr), median_len=float(np.median(lens)), n_obs=int(fi.size))


# ---------------------------------------------------------------- F09 observation matrix
def f_obs_matrix():
    occ = np.isfinite(obs[:, :, 0])
    first = np.argmax(occ, 0)
    order = np.argsort(first, kind='stable')
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.12, right=0.97, bottom=0.15, top=0.92)
    img = np.where(occ[:, order].T, 1.0, np.nan)
    ax.imshow(img, aspect='auto', cmap=LinearSegmentedColormap.from_list('r', [RED, RED]), interpolation='nearest',
              extent=(tau[0] - 0.05, tau[-1] + 0.05, ntr, 0))
    ax.set_xlabel('slice time  $t - t_0$ [s]'); ax.set_ylabel('track (sorted by first sample)')
    ax.text(0.0, 1.02, f'{occ.sum():,} observations (filled)  ·  {occ.mean()*100:.0f} % of the {occ.size:,} slots',
            transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F09_obs_matrix')
    return dict(fill=float(occ.mean()))


# ---------------------------------------------------------------- F10 twist model
def f_twist():
    a = best['a']; c = best['q'][:2]
    X = Sm['X0']
    C = np.r_[c, 1.0]
    fig = plt.figure(figsize=(5.4, 3.35))
    ax = fig.add_axes([-0.12, -0.12, 1.2, 1.25], projection='3d')
    # camera frustum at the origin (camera frame: x right, y down, z forward)
    s = 0.25
    corners = np.array([[(0 - cam.principal[0]) / cam.focal[0], (0 - cam.principal[1]) / cam.focal[1], 1],
                        [(W - cam.principal[0]) / cam.focal[0], (0 - cam.principal[1]) / cam.focal[1], 1],
                        [(W - cam.principal[0]) / cam.focal[0], (H - cam.principal[1]) / cam.focal[1], 1],
                        [(0 - cam.principal[0]) / cam.focal[0], (H - cam.principal[1]) / cam.focal[1], 1]]) * s
    for q in corners:
        ax.plot([0, q[0]], [0, q[2]], [0, -q[1]], color=DARK, lw=0.8)
    cc = np.r_[corners, corners[:1]]
    ax.plot(cc[:, 0], cc[:, 2], -cc[:, 1], color=DARK, lw=0.8)
    # landmarks at t0 (R = I): Y = X + T
    Y = X + C
    ax.scatter(Y[:, 0], Y[:, 2], -Y[:, 1], s=3, c=DARK, depthshade=False, linewidths=0)
    # spin axis through the centre
    L = 0.45
    ax.plot([C[0] - L * a[0], C[0] + L * a[0]], [C[2] - L * a[2], C[2] + L * a[2]], [-(C[1] - L * a[1]), -(C[1] + L * a[1])],
            color=RED, lw=2)
    # rotation circle
    t1, t2 = geom.axis_tangent(a)
    ph = np.linspace(0, 1.7 * np.pi, 100)
    r = 0.22
    circ = C + 0.25 * L * a + r * (np.cos(ph)[:, None] * t1 + np.sin(ph)[:, None] * t2)
    ax.plot(circ[:, 0], circ[:, 2], -circ[:, 1], color=RED, lw=1.2)
    tip, prev = circ[-1], circ[-6]
    ax.quiver(prev[0], prev[2], -prev[1], *(tip - prev)[[0, 2]], -(tip - prev)[1], color=RED, arrow_length_ratio=2.5, lw=1.2)
    ax.plot([0, C[0]], [0, C[2]], [0, -C[1]], color=GREY, lw=0.8, ls='--')
    ax.text(C[0] + L * a[0], C[2] + L * a[2], -(C[1] + L * a[1]) + 0.05, r'$\mathbf{a}$', color=RED, fontsize=12)
    ax.text(*(C[[0, 2]] * 0.5), -C[1] * 0.5 + 0.04, r'$\mathbf{T}_0=[c_x, c_y, 1]^\top$', color=DARK, fontsize=9)
    ax.text(0, 0, 0.06, 'camera', fontsize=8, color=DARK)
    ax.set_xlabel('x', labelpad=-8); ax.set_ylabel('z (depth)', labelpad=-6); ax.set_zlabel('−y', labelpad=-8)
    P = np.vstack([Y, np.zeros(3), C + L * a, C - L * a])
    lo, hi = P.min(0) - 0.05, P.max(0) + 0.05
    span = (hi - lo).max() / 2
    mid = (hi + lo) / 2
    ax.set_xlim(mid[0] - span, mid[0] + span); ax.set_ylim(lo[2], hi[2]); ax.set_zlim(-mid[1] - span, -mid[1] + span)
    ax.set_box_aspect((1, (hi[2] - lo[2]) / (2 * span), 1))
    ax.view_init(elev=16, azim=-62)
    pane3d(ax)
    ax.set_xticklabels([]); ax.set_yticklabels([]); ax.set_zticklabels([])
    fig.text(0.03, 0.92, f'fitted:  |ω| = {abs(np.rad2deg(best["w"])):.2f} °/s,  a = [{a[0]:.3f}, {a[1]:.3f}, {a[2]:.3f}]', fontsize=8.5, color=DARK)
    save(fig, 'F10_twist')
    return dict(a=a.tolist(), w_deg=float(np.rad2deg(best['w'])), c=c.tolist())


# ---------------------------------------------------------------- F11 triangulation rays
def f_rays():
    tr = Sm['traj0']
    R, T = traj.pose(tr, st)
    lens = np.isfinite(obs[:, :, 0]).sum(0)
    k = int(np.argmax(lens))
    f = np.flatnonzero(np.isfinite(obs[:, k, 0]))
    X = Sm['X0'][k]
    Rk, Tk = R[f], T[f]
    Cobj = -np.einsum('mji,mj->mi', Rk, Tk)                     # camera centre in object frame
    m = np.c_[(obs[f, k, :2] - cam.principal) / cam.focal, np.ones(len(f))]
    dobj = np.einsum('mji,mj->mi', Rk, m)
    dobj /= np.linalg.norm(dobj, axis=1, keepdims=True)
    fig = plt.figure(figsize=(5.4, 3.35))
    ax = fig.add_axes([-0.1, -0.1, 1.2, 1.2], projection='3d')
    tt = tau[f]
    cmap = CMAP_TIME
    rng = np.linalg.norm(X - Cobj, axis=1)
    for j in range(0, len(f), max(1, len(f) // 25)):
        e = Cobj[j] + dobj[j] * rng[j] * 1.12
        col = cmap((tt[j] - tt[0]) / max(tt[-1] - tt[0], 1e-9))
        ax.plot([Cobj[j, 0], e[0]], [Cobj[j, 1], e[1]], [Cobj[j, 2], e[2]], color=col, lw=0.7)
    ax.scatter(Cobj[:, 0], Cobj[:, 1], Cobj[:, 2], c=tt, cmap=cmap, s=6, depthshade=False)
    ax.scatter(*X, s=60, c=RED, marker='*', depthshade=False, zorder=10)
    Xall = Sm['X0']
    ax.scatter(Xall[:, 0], Xall[:, 1], Xall[:, 2], s=1.5, c=GREY, depthshade=False, linewidths=0)
    pane3d(ax)
    ax.set_xticklabels([]); ax.set_yticklabels([]); ax.set_zticklabels([])
    ax.set_xlabel('object x', labelpad=-8); ax.set_ylabel('object y', labelpad=-8); ax.set_zlabel('object z', labelpad=-8)
    ax.view_init(elev=22, azim=-50)
    ang = np.rad2deg(abs(traj.angle(tr, st[f[-1]]) - traj.angle(tr, st[f[0]])))[0]
    fig.text(0.03, 0.92, f'track {k}: {len(f)} rays over {tt[-1]-tt[0]:.1f} s ({ang:.0f}° of rotation)   (red star = triangulated point)', fontsize=8, color=DARK)
    save(fig, 'F11_rays')
    return dict(track=k, n_rays=int(len(f)), turn_deg=float(ang))


# ---------------------------------------------------------------- F12 normal residual on one track
def f_normal_residual():
    tr = Sm['traj0']
    R, T = traj.pose(tr, st)
    lens = np.isfinite(obs[:, :, 0]).sum(0)
    k = int(np.argsort(lens)[-2])
    f = np.flatnonzero(np.isfinite(obs[:, k, 0]))
    X = Sm['X0'][k]
    pr, _ = geom.project(R[f], T[f], np.repeat(X[None], len(f), 0), cam)
    o = obs[f, k, :2]
    n = geom.unit_rows(obs[f, k, 2:4])
    r = np.sum((o - pr) * n, 1)
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.12, right=0.97, bottom=0.14, top=0.93)
    tg = np.c_[-n[:, 1], n[:, 0]]
    for j in range(0, len(f), 2):
        e = np.r_[[o[j] - 2.2 * tg[j], o[j] + 2.2 * tg[j]]]
        ax.plot(e[:, 0], e[:, 1], color=LIGHT, lw=2.2, solid_capstyle='butt', zorder=1)
        foot = pr[j] + r[j] * n[j]
        ax.plot([pr[j, 0], foot[0]], [pr[j, 1], foot[1]], color=RED, lw=1.0, zorder=3)
    ax.plot(o[:, 0], o[:, 1], 'o', ms=3.2, color=DARK, label='observed $\\mathbf{u}_{ij}$ (edge in grey)', zorder=4)
    ax.plot(pr[:, 0], pr[:, 1], 'o', ms=3.2, mfc='white', mec=RED, mew=0.9, label='projected $\\pi(\\mathbf{R}_j\\mathbf{X}_i+\\mathbf{T}_j)$', zorder=4)
    ax.plot([], [], color=RED, lw=1, label='normal residual $r_{ij}$')
    ax.set_aspect('equal'); ax.invert_yaxis()
    ax.set_xlabel('x [px]'); ax.set_ylabel('y [px]')
    ax.legend(loc='best', fontsize=8)
    ax.text(0.0, 1.02, f'track {k}, {len(f)} samples   RMS normal residual {np.sqrt(np.mean(r**2)):.2f} px', transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F12_normal_residual')
    return dict(track=k, rms=float(np.sqrt(np.mean(r ** 2))))


# ---------------------------------------------------------------- F13 Cauchy loss
def f_cauchy():
    c = cfg.adjust.cauchy_px
    r = adjust.normal_residuals(Sm['traj0'], Sm['X0'], Sm['O'], cam)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(5.4, 3.0))
    fig.subplots_adjust(left=0.1, right=0.9, bottom=0.21, top=0.92, wspace=0.5)
    xs = np.linspace(-15, 15, 400)
    a1.plot(xs, xs ** 2, color=GREY, lw=1.2, label='squared  $r^2$')
    a1.plot(xs, c ** 2 * np.log1p(xs ** 2 / c ** 2), color=RED, lw=1.8, label='Cauchy  $\\rho(r)$')
    a1.set_ylim(0, 60); a1.set_xlabel('residual $r$ [px]'); a1.set_ylabel('cost')
    a1.legend(loc='upper center', fontsize=8)
    a1.set_title('loss', loc='left', fontsize=9.5)
    a2.hist(np.clip(r, -15, 15), bins=np.linspace(-15, 15, 61), color=LIGHT, edgecolor='white', linewidth=0.3)
    a2.set_xlabel('seed normal residual [px]'); a2.set_ylabel('observations')
    a3 = a2.twinx()
    a3.plot(xs, 1 / (1 + xs ** 2 / c ** 2), color=RED, lw=1.6)
    a3.set_ylim(0, 1.05); a3.set_ylabel('weight $w(r)$', color=RED); a3.tick_params(axis='y', colors=RED)
    a3.spines['right'].set_visible(True); a3.spines['right'].set_color(RED)
    a2.set_title('weight vs data', loc='left', fontsize=9.5)
    frac = np.mean(np.abs(r) > 2 * c)
    fig.text(0.1, 0.01, f'c = {c:g} px  ·  {100*frac:.1f} % of seed residuals beyond 2c get weight < 0.2', fontsize=7.5, color=DARK)
    save(fig, 'F13_cauchy')
    return dict(c=c, frac_out=float(frac))


# ---------------------------------------------------------------- F14 axis sweep
def f_sweep():
    fits = Fw['fits']
    A = np.array([f['a'] for f in fits])
    cost = np.array([f['cost'] for f in fits])
    nd = 2 * cfg.warm.hemisphere_directions
    A0 = A[:nd]
    cmin = np.array([np.nanmin(cost[j::nd]) for j in range(nd)])
    fig = plt.figure(figsize=(5.4, 3.35))
    ax = fig.add_axes([-0.12, -0.1, 0.95, 1.2], projection='3d')
    u, v = np.mgrid[0:2 * np.pi:40j, 0:np.pi:20j]
    ax.plot_wireframe(np.cos(u) * np.sin(v), np.sin(u) * np.sin(v), np.cos(v), color=PALE, lw=0.4)
    rank = np.argsort(np.argsort(cmin))
    norm_c = (np.log(cmin) - np.log(cmin).min()) / max(np.ptp(np.log(cmin)), 1e-9)
    sc = ax.scatter(A0[:, 0], A0[:, 2], -A0[:, 1], c=norm_c, cmap=CMAP_GREYRED.reversed(), s=36, depthshade=False,
                    edgecolors='white', linewidths=0.5)
    b = best['a']
    ax.quiver(0, 0, 0, 1.25 * b[0], 1.25 * b[2], -1.25 * b[1], color=RED, lw=2, arrow_length_ratio=0.12)
    ax.text(1.32 * b[0], 1.32 * b[2], -1.32 * b[1], 'refined $\\mathbf{a}$', color=RED, fontsize=9)
    ax.set_xlim(-1, 1); ax.set_ylim(-1, 1); ax.set_zlim(-1, 1); ax.set_box_aspect((1, 1, 1))
    pane3d(ax)
    ax.set_xticklabels([]); ax.set_yticklabels([]); ax.set_zticklabels([])
    ax.set_xlabel('x', labelpad=-10); ax.set_ylabel('z', labelpad=-10); ax.set_zlabel('−y', labelpad=-10)
    ax.view_init(elev=20, azim=-60)
    # right: cost per axis, best over seeds
    ax2 = fig.add_axes([0.72, 0.18, 0.25, 0.68])
    o = np.argsort(cmin)
    ax2.barh(np.arange(nd), cmin[o] / cmin.min(), color=[RED if i == 0 else LIGHT for i in range(nd)], height=0.75)
    ax2.set_xscale('log'); ax2.invert_yaxis(); ax2.set_yticks([])
    from matplotlib.ticker import LogLocator, NullFormatter
    ax2.xaxis.set_minor_formatter(NullFormatter())
    ax2.xaxis.set_major_locator(LogLocator(base=10, numticks=4))
    fig.text(0.03, 0.03, 'colour: red = lowest robust cost (best over rate seeds)', fontsize=7.5, color=DARK)
    ax2.set_xlabel('cost / best', fontsize=8); ax2.tick_params(labelsize=7)
    ax2.set_title(f'{nd} axes × {len(cfg.warm.rate_seeds_deg_s)} seeds', fontsize=8, loc='left', fontweight='normal')
    save(fig, 'F14_sweep')
    return dict(n_fits=len(fits), best_coarse_axis=Fw['best']['a'].tolist(), best_coarse_w=float(np.rad2deg(Fw['best']['w'])))


# ---------------------------------------------------------------- F15 rate profile
def f_rate_profile():
    rates, prof = Fw['rates'], Fw['profile']
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.13, right=0.97, bottom=0.15, top=0.92)
    ax.plot(rates, prof, color=DARK, lw=1.4)
    j = int(np.nanargmin(prof))
    inside = rates[prof <= np.nanmin(prof) + 2]
    ax.axvspan(inside.min(), inside.max(), color=PINK, alpha=0.7, lw=0)
    ax.axvline(abs(np.rad2deg(best['w'])), color=RED, lw=1.2, ls='--')
    ax.plot(rates[j], prof[j], 'o', color=RED, ms=5)
    ax.set_xlabel('fixed spin rate  |ω| [°/s]'); ax.set_ylabel('robust cost  (other parameters re-fit)')
    ax.text(0.0, 1.02, f'refined |ω| = {abs(np.rad2deg(best["w"])):.2f} °/s   ·   Δcost ≤ 2 band: {inside.min():.1f}–{inside.max():.1f} °/s',
            transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F15_rate_profile')
    return dict(band=[float(inside.min()), float(inside.max())], w=float(abs(np.rad2deg(best['w']))))


# ---------------------------------------------------------------- F16 spline basis
def f_spline():
    tr = load('final')['final']['traj'] if os.path.exists(os.path.join(CACHE, 'final.pkl')) else Sm['traj']
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(5.4, 3.35), gridspec_kw=dict(height_ratios=[1, 1.25]))
    fig.subplots_adjust(left=0.13, right=0.97, bottom=0.14, top=0.95, hspace=0.32)
    tt = np.linspace(T0, T0 + 8, 800)
    idx, val = traj.spline_basis(tr, tt)
    for j in range(0, 12):
        y = np.where(idx == j, val, 0).sum(1)
        if y.max() > 0:
            a1.plot(tt - T0, y, color=RED if j == 5 else GREY, lw=1.6 if j == 5 else 0.9)
    for kt in tr['knot_t']:
        if T0 <= kt <= T0 + 8:
            a1.axvline(kt - T0, color=PALE, lw=0.6, zorder=0)
    a1.set_ylabel('$B_j(t)$'); a1.set_ylim(0, 0.75)
    tt2 = np.linspace(T0, cfg.data.end_time_s, 2000)
    corr = np.rad2deg(traj.spline_eval(tr, tt2, tr['k']))
    a2.plot(tt2 - T0, corr, color=RED, lw=1.3)
    a2.axhline(0, color=GREY, lw=0.6)
    a2.set_ylabel('correction [°]')
    a2.set_xlabel('t − t$_0$ [s]')
    a2.set_xlim(0, cfg.data.end_time_s - T0)
    a1.set_xlim(0, cfg.data.end_time_s - T0)
    a1.set_xlim(0, 8)
    a1.text(0.99, 0.92, 'uniform cubic basis, h = 1 s (first 8 s)', transform=a1.transAxes, ha='right', fontsize=7.5, color=DARK)
    a2.text(0.0, 1.03, f'$\\sum_j k_j B_j(t)$ over the whole run   (|ω| = {np.rad2deg(abs(tr["omega"])):.3f} °/s carries the rest)',
            transform=a2.transAxes, fontsize=7.5, color=DARK, va='bottom')
    a2.set_xlim(0, cfg.data.end_time_s - T0)
    save(fig, 'F16_spline')
    return dict(K=int(tr['K']))


# ---------------------------------------------------------------- F17 Jacobian sparsity
def f_jacobian():
    tr, X, O = Sm['traj0'], Sm['X0'], Sm['O']
    free = traj.select_free_parameters(tr, True, cfg.data.start_time_s + cfg.warm.duration_s, None, False)
    lm = np.arange(min(X.shape[0], 60))
    sel = np.isin(O[:, 1].astype(int), lm)
    Osub = O[sel]
    Osub = Osub[np.lexsort((Osub[:, 0], Osub[:, 1]))]
    p = adjust.setup_problem(tr, X, Osub, free, lm, cam, cfg.adjust)
    J = adjust.jacobian(p, tr, X).tocoo()
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.12, right=0.97, bottom=0.08, top=0.9)
    ax.scatter(J.col, J.row, s=0.25, c=DARK, marker='s', linewidths=0)
    nm = p.n_free_motion
    ax.axvline(nm - 0.5, color=RED, lw=0.8)
    ax.axhline(p.n_img - 0.5, color=RED, lw=0.8)
    ax.set_xlim(-0.5, p.n_free - 0.5); ax.set_ylim(p.n_img + p.n_prior - 0.5, -0.5)
    ax.xaxis.set_ticks_position('top'); ax.xaxis.set_label_position('top')
    ax.set_xlabel('free parameters'); ax.set_ylabel('residual rows')
    ax.text(nm / 2, p.n_img * 0.97, 'motion\nω, a, c, spline', ha='center', va='bottom', fontsize=8, color=RED,
            bbox=dict(fc='white', ec='none', pad=1))
    ax.text(nm + (p.n_free - nm) * 0.6, p.n_img * 0.3, 'landmarks\n(3 columns each)', ha='center', fontsize=8, color=RED)
    ax.text(p.n_free * 0.98, p.n_img + p.n_prior * 0.5, 'priors', ha='right', fontsize=8, color=RED, va='center')
    ax.text(0.0, -0.08, f'{len(lm)} landmarks, {p.M} observations: {J.nnz:,} non-zeros = {100*J.nnz/(J.shape[0]*J.shape[1]):.1f} % fill',
            transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F17_jacobian')
    return dict(nnz=int(J.nnz), shape=list(J.shape))


# ---------------------------------------------------------------- F18 LM convergence
def f_lm():
    info = Sm['info']
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(5.4, 3.0))
    fig.subplots_adjust(left=0.12, right=0.97, bottom=0.17, top=0.88, wspace=0.38)
    c = np.array(info['costs'])
    a1.plot(np.arange(len(c)), c / c[0], 'o-', color=RED, ms=3.5)
    a1.set_xlabel('LM iteration'); a1.set_ylabel('cost / initial cost')
    a1.set_title('robust cost', loc='left', fontsize=9.5)
    b = np.linspace(-6, 6, 61)
    a2.hist(np.clip(Sm['dn0'], -6, 6), bins=b, color=LIGHT, label=f'triangulated  {np.sqrt(np.mean(Sm["dn0"]**2)):.2f} px')
    a2.hist(np.clip(Sm['dn1'], -6, 6), bins=b, histtype='step', color=RED, lw=1.4, label=f'after BA  {np.sqrt(np.mean(Sm["dn1"]**2)):.2f} px')
    a2.set_xlabel('normal residual [px]'); a2.set_ylabel('observations')
    a2.legend(fontsize=7.5, loc='upper left')
    a2.set_title('residuals (RMS)', loc='left', fontsize=9.5)
    save(fig, 'F18_lm')
    return dict(costs=c.tolist(), steps=info['accepted_steps'])


if __name__ == '__main__':
    import json
    out = {}
    for f in (f_tracks, f_obs_matrix, f_twist, f_rays, f_normal_residual, f_cauchy, f_sweep, f_rate_profile,
              f_spline, f_jacobian, f_lm):
        out[f.__name__] = f()
    json.dump(out, open(os.path.join(OUT, 'facts_warm.json'), 'w'), indent=1, default=float)
