"""Figures for the progressive loop and the final result."""
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Polygon, FancyArrowPatch
from style import *  # noqa
from esfm import config, data, geom, traj, adjust

cfg = config.config(start_time_s=float(os.environ.get('ESFM_T0', 60)), end_time_s=float(os.environ.get('ESFM_T1', 185)))
cam = data.read_calibration(cfg.camera.calibration_xml)
P = load('progressive')
Fn = load('final')
T0, T1 = cfg.data.start_time_s, cfg.data.end_time_s
W, H = cam.image_size
log = P['log']
fin = Fn['final']
det_t = sorted(P['details'].keys())
DT = det_t[len(det_t) // 2] if det_t else None


def detail():
    return P['details'][DT]


# ---------------------------------------------------------------- F19 slice cycle with real numbers
def f_cycle():
    d = detail()
    inf = d['info']
    p1, p2 = inf['detail']['pass1'], inf['detail'].get('pass2', inf['detail']['pass1'])
    E = len(d['slc']['t'])
    L = int(p1['pred']['inside'].sum())
    c1, c2 = len(p1['claims']['rows']), len(p2['claims']['rows'])
    steps = [('warp', f'{E:,} events\nto $t_c$'),
             ('predict', f'{L} landmarks\nin view'),
             ('associate', f'{c1} claims'),
             ('correct', f'{inf["correction_steps"]} LM steps\n(recent knots)'),
             ('re-associate', f'{c2} claims\n{100*inf["explained"]:.0f} % explained'),
             ('candidates', f'{inf["n_cand"]} 2-D tracks'),
             ('promote', f'{inf["n_new"]} new landmarks')]
    fig, ax = plt.subplots(figsize=(8.4, 2.6))
    fig.subplots_adjust(0, 0, 1, 1)
    ax.set_xlim(0, 8.4); ax.set_ylim(0, 2.6); ax.axis('off')
    n = len(steps)
    w, h, gap = 1.0, 1.05, 0.17
    x0 = (8.4 - (n * w + (n - 1) * gap)) / 2
    for i, (t, sub) in enumerate(steps):
        x = x0 + i * (w + gap)
        hl = t in ('associate', 're-associate', 'correct')
        ax.add_patch(FancyBboxPatch((x, 0.95), w, h, boxstyle='round,pad=0.02,rounding_size=0.08',
                                    fc=RED if hl else PALE, ec='none'))
        ax.text(x + w / 2, 0.95 + h - 0.2, t, ha='center', va='center', fontsize=9.5, fontweight='bold',
                color='white' if hl else BLACK)
        ax.text(x + w / 2, 0.95 + 0.38, sub, ha='center', va='center', fontsize=8, color='white' if hl else DARK, linespacing=1.2)
        if i < n - 1:
            ax.annotate('', xy=(x + w + gap - 0.02, 0.95 + h / 2), xytext=(x + w + 0.02, 0.95 + h / 2),
                        arrowprops=dict(arrowstyle='-|>', color=DARK, lw=0.9, mutation_scale=8))
    ax.annotate('', xy=(x0 + 0.5, 0.92), xytext=(x0 + n * (w + gap) - gap - 0.5, 0.92),
                arrowprops=dict(arrowstyle='-|>', color=GREY, lw=0.9, connectionstyle='arc3,rad=-0.12', mutation_scale=8))
    ax.text(4.2, 0.28, f'next slice  (Δt = {cfg.data.slice_s:.1f} s)        values: slice at t$_c$ = {DT:.2f} s',
            ha='center', fontsize=8, color=DARK)
    save(fig, 'F19_cycle')
    return dict(t=DT, E=E, L=L, c1=c1, c2=c2)


# ---------------------------------------------------------------- F20 prediction on a real slice
def f_predict():
    d = detail(); inf = d['info']; dd = inf['detail']
    p = dd.get('pass2', dd['pass1'])
    Wp, used = dd['W'], dd['used']
    pred = p['pred']
    ins = pred['inside']
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.1, right=0.98, bottom=0.14, top=0.95)
    ax.scatter(Wp[~used, 0], Wp[~used, 1], s=0.8, c=LIGHT, linewidths=0, label='unclaimed events')
    ax.scatter(Wp[used, 0], Wp[used, 1], s=0.8, c=RED, linewidths=0, label='claimed events')
    ax.scatter(pred['uv'][ins, 0], pred['uv'][ins, 1], s=10, facecolors='none', edgecolors=BLACK, linewidths=0.6,
               label='predicted landmarks')
    fl = pred['flow'][ins]
    ax.quiver(pred['uv'][ins, 0], pred['uv'][ins, 1], fl[:, 0], fl[:, 1], color=DARK, angles='xy', scale_units='xy',
              scale=1.0, width=0.0025, headwidth=3, headlength=3.5)
    ax.set_xlim(0, W); ax.set_ylim(H, 0); ax.set_aspect('equal')
    ax.set_xlabel('x [px]'); ax.set_ylabel('y [px]')
    ax.legend(loc='lower left', markerscale=4, fontsize=7.5, ncol=3, bbox_to_anchor=(0, -0.01))
    ax.text(0.0, 1.01, f't$_c$ = {DT:.2f} s   ·   {ins.sum()} landmarks in view   ·   arrows = predicted motion over 1 s',
            transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F20_predict')
    return dict(t=DT, n_in=int(ins.sum()))


# ---------------------------------------------------------------- F21 the four gates around one landmark
def f_gates():
    d = detail(); dd = d['info']['detail']
    p = dd.get('pass2', dd['pass1'])
    det = p['claims']['detail']
    Wp, D = dd['W'], dd['D']
    # landmark with a decent mix of accepted / rejected neighbours
    score = [(int(q['ok'].sum()), int((~q['ok']).sum())) for q in det]
    j = int(np.argmax([min(a, b) * 3 + a for a, b in score]))
    q = det[j]
    k = q['k']
    u = p['pred']['uv'][k]
    nrm = d['X'] is not None and P['map']['nrm'][p['pred']['ids'][k]]
    nrm = geom.unit_rows(np.asarray(dd['pass1']['pred']['flow'][k]))[0] if nrm is None else nrm
    # the gate frame uses each event's own direction; draw the box along the mean event direction
    dm = geom.unit_rows(D[q['cand']][q['ok']].mean(0) if q['ok'].any() else D[q['cand']].mean(0))[0]
    tg = np.r_[-dm[1], dm[0]]
    gn, gt = cfg.prog.gate_normal_px, cfg.prog.gate_tangent_px
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.12, right=0.7, bottom=0.14, top=0.95)
    circ = plt.Circle(u, gt, fc='none', ec=GREY, ls=':', lw=0.8)
    ax.add_patch(circ)
    box = np.array([u + a * gn * dm + b * gt * tg for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1))])
    ax.add_patch(Polygon(box, closed=True, fc=PINK, ec=RED, lw=0.9, alpha=0.6))
    near = np.flatnonzero(np.linalg.norm(Wp - u, axis=1) < gt * 1.6)
    ax.scatter(Wp[near, 0], Wp[near, 1], s=6, c=LIGHT, linewidths=0, zorder=2)
    c = q['cand']
    ax.scatter(Wp[c[~q['ok']], 0], Wp[c[~q['ok']], 1], s=16, marker='x', c=DARK, linewidths=0.9, zorder=3, label='rejected by a gate')
    ax.scatter(Wp[c[q['ok']], 0], Wp[c[q['ok']], 1], s=14, c=RED, linewidths=0, zorder=4, label='claimed')
    ax.quiver(Wp[c, 0], Wp[c, 1], D[c, 0], D[c, 1], color=GREY, angles='xy', scale_units='xy', scale=0.6, width=0.004, zorder=3)
    ax.plot(*u, marker='o', ms=7, mfc='white', mec=BLACK, mew=1.2, zorder=5, label='prediction $\\hat{\\mathbf{u}}$')
    f = p['pred']['flow'][k]; f = f / max(np.linalg.norm(f), 1e-9)
    ax.annotate('', xy=u + 6 * f, xytext=u, arrowprops=dict(arrowstyle='-|>', color=BLACK, lw=1.2))
    ax.set_xlim(u[0] - 1.7 * gt, u[0] + 1.7 * gt); ax.set_ylim(u[1] + 1.7 * gt, u[1] - 1.7 * gt); ax.set_aspect('equal')
    ax.set_xlabel('x [px]'); ax.set_ylabel('y [px]')
    ax.legend(loc='upper left', bbox_to_anchor=(1.02, 1.0), fontsize=8)
    fig.text(0.72, 0.42, f'gates (shaded box):\n|normal| < {gn:g} px\n|tangent| < {gt:g} px\nsame motion sign\n|cos| to last normal > {cfg.prog.min_normal_cos}\n\n'
             f'{q["ok"].sum()} claimed / {len(c)} nearby', fontsize=8, color=DARK, va='top', linespacing=1.4)
    save(fig, 'F21_gates')
    return dict(ok=int(q['ok'].sum()), cand=int(len(c)))


# ---------------------------------------------------------------- F22 motion correction (window + effect)
def f_correction():
    d = detail(); dd = d['info']['detail']
    tr = dd['pass1']['traj']
    tc = DT
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(5.4, 3.0), gridspec_kw=dict(width_ratios=[1.35, 1]))
    fig.subplots_adjust(left=0.1, right=0.97, bottom=0.18, top=0.86, wspace=0.35)
    tt = np.linspace(tc - 5, tc + 2, 600)
    idx, val = traj.spline_basis(tr, tt)
    act = traj.spline_active(tr, tc - cfg.prog.local_window_s, tc)
    for j in range(idx.min(), idx.max() + 1):
        y = np.where(idx == j, val, 0).sum(1)
        a1.plot(tt - tc, y, color=RED if j in act else LIGHT, lw=1.5 if j in act else 0.9)
    a1.axvspan(-cfg.prog.local_window_s, 0, color=PINK, alpha=0.5, lw=0)
    a1.axvline(0, color=BLACK, lw=0.8)
    a1.set_xlabel('t − t$_c$ [s]'); a1.set_ylabel('$B_j(t)$'); a1.set_ylim(0, 0.75)
    a1.set_title(f'{len(act)} free coefficients (red)', loc='left', fontsize=9, fontweight='normal')
    if 'pass2' in dd:
        u1, u2 = dd['pass1']['pred']['uv'], dd['pass2']['pred']['uv']
        m = dd['pass1']['pred']['inside']
        sh = np.linalg.norm(u2[m] - u1[m], axis=1)
        a2.hist(sh, bins=25, color=RED, edgecolor='white', linewidth=0.3)
        a2.set_xlabel('prediction shift [px]'); a2.set_ylabel('landmarks')
        n1, n2 = len(dd['pass1']['claims']['rows']), len(dd['pass2']['claims']['rows'])
        a2.set_title(f'claims {n1} → {n2}', loc='left', fontsize=9, fontweight='normal')
    fig.text(0.1, 0.94, f'slice t$_c$ = {tc:.2f} s: motion-only LM, {cfg.prog.correction_iterations} iterations, landmarks fixed',
             fontsize=7.5, color=DARK)
    save(fig, 'F22_correction')
    return dict(n_free=int(len(act)))


# ---------------------------------------------------------------- F23 map growth and promotions
def f_growth():
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.12, right=0.88, bottom=0.15, top=0.92)
    t = log[:, 0] - T0
    ax.plot(t, log[:, 2], color=RED, lw=1.6, label='landmarks in map')
    ax.plot(t, log[:, 4], color=DARK, lw=0.6, alpha=0.8, label='landmarks matched per slice')
    ax.set_xlabel('t − t$_0$ [s]'); ax.set_ylabel('count')
    ax2 = ax.twinx()
    prom = np.convolve(np.nan_to_num(log[:, 5]), np.ones(50), 'same') / 5.0
    prom[:25] = np.nan; prom[-25:] = np.nan
    ax2.fill_between(t, np.nan_to_num(prom), where=np.isfinite(prom), color=PINK, alpha=0.8, lw=0)
    ax2.set_ylabel('promotions per s (5 s mean)', color=RED); ax2.tick_params(axis='y', colors=RED)
    ax2.spines['right'].set_visible(True); ax2.spines['right'].set_color(RED)
    ax.set_zorder(ax2.get_zorder() + 1); ax.patch.set_visible(False)
    ax.legend(loc='upper left', fontsize=8)
    ax.text(0.0, 1.02, f'promotion: ≥ {cfg.prog.cand_min_samples} samples, ≥ {cfg.prog.cand_min_turn_deg:g}° turn, depth > {cfg.prog.cand_min_depth}, RMS < {cfg.prog.cand_max_rms_px:g} px   ·   total promoted {int(np.nansum(log[:,5]))}',
            transform=ax.transAxes, fontsize=7.3, color=DARK)
    save(fig, 'F23_growth')
    return dict(final_map=int(log[-1, 2]), promoted=int(np.nansum(log[:, 5])))


# ---------------------------------------------------------------- F24 local / global schedule
def f_schedule():
    gl, ll = P['global_log'], P['local_log']
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(5.4, 3.35), sharex=True, gridspec_kw=dict(height_ratios=[1.3, 1]))
    fig.subplots_adjust(left=0.13, right=0.97, bottom=0.14, top=0.93, hspace=0.12)
    if len(gl):
        a1.step(gl[:, 0] - T0, gl[:, 1], where='post', color=RED, lw=1.4)
        a1.plot(gl[:, 0] - T0, gl[:, 1], 'o', color=RED, ms=3.5)
    a1.set_ylabel('points in\nglobal BA')
    a1.text(0.0, 1.03, f'{len(gl)} global adjustments (observations grew ×{cfg.prog.global_growth})  ·  {len(ll)} local adjustments (every {cfg.prog.local_every_s:g} s)',
            transform=a1.transAxes, fontsize=7.5, color=DARK)
    if len(ll):
        a2.plot(ll[:, 0] - T0, ll[:, 1], '.', color=DARK, ms=2.5, label='local BA')
    if len(gl):
        a2.plot(gl[:, 0] - T0, gl[:, 3], 'o', color=RED, ms=3.5, label='global BA')
    a2.set_ylabel('normal RMS\n[px]'); a2.set_xlabel('t − t$_0$ [s]')
    a2.legend(fontsize=7.5, loc='upper right', ncol=2)
    save(fig, 'F24_schedule')
    return dict(n_global=int(len(gl)), n_local=int(len(ll)))


# ---------------------------------------------------------------- F25 online vs refined
def f_online():
    on = P['online']
    tr = fin['traj']
    th_ref = traj.angle(tr, on['t'])
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(5.4, 3.35), sharex=True)
    fig.subplots_adjust(left=0.13, right=0.97, bottom=0.14, top=0.93, hspace=0.12)
    a1.plot(on['t'] - T0, log[:, 1], color=GREY, lw=0.8, label='online (causal)')
    a1.plot(on['t'] - T0, traj.rate_deg_s(tr, on['t']), color=RED, lw=1.4, label='final (offline)')
    a1.set_ylabel('spin rate\n[°/s]'); a1.legend(fontsize=7.5, loc='lower right', ncol=2)
    err = np.rad2deg(on['theta'] - th_ref)
    a2.plot(on['t'] - T0, err, color=DARK, lw=1.0)
    a2.axhline(0, color=GREY, lw=0.6)
    a2.set_ylabel('angle difference\nonline − final [°]'); a2.set_xlabel('t − t$_0$ [s]')
    a1.text(0.0, 1.03, f'online angle within {np.nanpercentile(np.abs(err), 95):.2f}° of the final estimate (95th pct.)',
            transform=a1.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F25_online')
    return dict(err95=float(np.nanpercentile(np.abs(err), 95)))


# ---------------------------------------------------------------- F26 final filtering
def f_filter():
    pr = fin['point_rms_pass1']
    m = P['map']
    cand = np.flatnonzero(m['nobs'] >= cfg.final.min_obs)
    v = pr[cand]
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.12, right=0.97, bottom=0.15, top=0.92)
    b = np.linspace(0, max(4.5, np.percentile(v, 99)), 60)
    thr = cfg.final.max_point_rms_px
    ax.hist(v[v < thr], bins=b, color=RED, edgecolor='white', linewidth=0.3, label=f'kept  {np.sum(v < thr)}')
    ax.hist(v[v >= thr], bins=b, color=GREY, edgecolor='white', linewidth=0.3, label=f'dropped  {np.sum(v >= thr)}')
    ax.axvline(thr, color=BLACK, lw=0.9, ls='--')
    ax.set_xlabel('per-landmark normal RMS after pass 1 [px]'); ax.set_ylabel('landmarks')
    ax.legend(fontsize=8)
    ax.text(0.0, 1.02, f'{len(m["X"])} landmarks total  ·  {len(cand)} with ≥ {cfg.final.min_obs} observations  ·  threshold {thr:g} px',
            transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F26_filter')
    return dict(kept=int(np.sum(v < thr)), dropped=int(np.sum(v >= thr)), total=int(len(m['X'])), eligible=int(len(cand)))


def axis_frame(a):
    """Rotation whose z-axis is the spin axis (for views)."""
    a = a / np.linalg.norm(a)
    t1, t2 = geom.axis_tangent(a)
    return np.c_[t1, t2, a].T


# ---------------------------------------------------------------- F27 point cloud
def f_cloud():
    Xm = Fn['X_m']
    Rf = axis_frame(fin['traj']['a'])
    Q = (Xm - Xm.mean(0)) @ Rf.T
    nob = Fn['nobs']
    fig, axs = plt.subplots(1, 3, figsize=(8.4, 3.0))
    fig.subplots_adjust(left=0.07, right=0.9, bottom=0.17, top=0.88, wspace=0.28)
    views = [((0, 1), 'down the spin axis', 'u [m]', 'v [m]'), ((0, 2), 'side view 1', 'u [m]', 'along axis [m]'),
             ((1, 2), 'side view 2', 'v [m]', 'along axis [m]')]
    lim = np.percentile(np.abs(Q), 99.5) * 1.08
    for ax, ((i, j), ttl, xl, yl) in zip(axs, views):
        sc = ax.scatter(Q[:, i], Q[:, j], s=5, c=np.log10(nob), cmap=CMAP_GREYRED, linewidths=0)
        ax.set_xlim(-lim, lim); ax.set_ylim(-lim, lim); ax.set_aspect('equal')
        ax.set_title(ttl, loc='left', fontsize=9, fontweight='normal', color=DARK)
        ax.set_xlabel(xl); ax.set_ylabel(yl)
    cax = fig.add_axes([0.92, 0.2, 0.012, 0.6])
    cb = fig.colorbar(sc, cax=cax); cb.set_label('observations'); cb.outline.set_visible(False)
    tk = [20, 50, 100, 200, 500, 1000]
    cb.set_ticks(np.log10(tk)); cb.set_ticklabels([str(v) for v in tk])
    fig.text(0.07, 0.95, f'{len(Xm)} landmarks · scale {Fn["scale"]["m_per_unit"]:.3f} m per model unit (1–99 % span = {cfg.output.known_width_m} m, provisional)',
             fontsize=8, color=DARK)
    save(fig, 'F27_cloud')
    return dict(n=int(len(Xm)), scale=float(Fn['scale']['m_per_unit']))


# ---------------------------------------------------------------- F28 residuals over time
def f_residuals():
    O, dn = fin['O'], fin['dn']
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.12, right=0.9, bottom=0.15, top=0.92)
    tb = np.arange(T0, T1 + 1, 1.0)
    rb = np.linspace(-5, 5, 81)
    Hh, _, _ = np.histogram2d(O[:, 0], np.clip(dn, -5, 5), [tb, rb])
    im = ax.imshow(Hh.T, origin='lower', aspect='auto', extent=(0, T1 - T0, -5, 5), cmap=CMAP_RED,
                   norm=matplotlib.colors.PowerNorm(0.5))
    k = np.digitize(O[:, 0], tb) - 1
    rms = np.sqrt(np.bincount(k, dn ** 2, len(tb) - 1) / np.maximum(np.bincount(k, minlength=len(tb) - 1), 1))
    ax.plot(tb[:-1] + 0.5 - T0, rms, color=BLACK, lw=1.0, label='RMS per second')
    ax.plot(tb[:-1] + 0.5 - T0, -rms, color=BLACK, lw=1.0)
    ax.set_xlabel('t − t$_0$ [s]'); ax.set_ylabel('normal residual [px]')
    cb = fig.colorbar(im, ax=ax, fraction=0.04, pad=0.02); cb.set_label('observations'); cb.outline.set_visible(False)
    ax.legend(loc='upper right', fontsize=7.5)
    ax.text(0.0, 1.02, f'{len(O):,} observations  ·  overall RMS {np.sqrt(np.mean(dn**2)):.3f} px  ·  median |r| {np.median(np.abs(dn)):.2f} px',
            transform=ax.transAxes, fontsize=7.5, color=DARK)
    save(fig, 'F28_residuals')
    return dict(rms=float(np.sqrt(np.mean(dn ** 2))), n=int(len(O)))


# ---------------------------------------------------------------- F29 explained fraction
def f_explained():
    t = log[:, 0] - T0
    fig, ax = plt.subplots(figsize=(5.4, 3.35))
    fig.subplots_adjust(left=0.12, right=0.97, bottom=0.15, top=0.92)
    e = log[:, 3] * 100
    ax.plot(t, e, color=LIGHT, lw=0.6)
    ok = np.isfinite(e).astype(float)
    sm = np.convolve(np.nan_to_num(e), np.ones(20), 'same') / np.maximum(np.convolve(ok, np.ones(20), 'same'), 1)
    sm[:10] = np.nan; sm[-10:] = np.nan
    ax.plot(t, sm, color=RED, lw=1.6, label='2 s moving mean')
    ax.set_ylim(0, 100); ax.set_xlabel('t − t$_0$ [s]'); ax.set_ylabel('accepted events claimed by the map [%]')
    ax.legend(fontsize=8, loc='lower right')
    ax.text(0.0, 1.02, f'median {np.nanmedian(e):.0f} % of each slice is explained by existing landmarks', transform=ax.transAxes,
            fontsize=7.5, color=DARK)
    save(fig, 'F29_explained')
    return dict(median=float(np.nanmedian(e)))


if __name__ == '__main__':
    import json
    out = {}
    for f in (f_cycle, f_predict, f_gates, f_correction, f_growth, f_schedule, f_online, f_filter, f_cloud,
              f_residuals, f_explained):
        out[f.__name__] = f()
    json.dump(out, open(os.path.join(OUT, 'facts_back.json'), 'w'), indent=1, default=float)
