"""MP4 animations (H.264, 1280x720) + poster frames, all from the pipeline cache."""
import sys
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation, FFMpegWriter
from style import *  # noqa
from esfm import config, data, geom, traj

cfg = config.config(start_time_s=float(os.environ.get('ESFM_T0', 60)), end_time_s=float(os.environ.get('ESFM_T1', 185)))
cam = data.read_calibration(cfg.camera.calibration_xml)
T0, T1 = cfg.data.start_time_s, cfg.data.end_time_s
W, H = cam.image_size
DPI = 200
FIG = (6.4, 3.6)


def writer(fps):
    return FFMpegWriter(fps=fps, codec='libx264', bitrate=4000,
                        extra_args=['-pix_fmt', 'yuv420p', '-profile:v', 'main', '-movflags', '+faststart'])


def finish(fig, anim, name, fps, poster_frame):
    path = os.path.join(OUT, name + '.mp4')
    anim.save(path, writer=writer(fps), dpi=DPI, savefig_kwargs=dict(facecolor='white'))
    anim._func(poster_frame)
    fig.savefig(os.path.join(OUT, name + '_poster.png'), dpi=DPI, facecolor='white')
    plt.close(fig)
    print('wrote', name)


def frame_axes():
    fig = plt.figure(figsize=FIG, facecolor='white')
    ax = fig.add_axes([0.08, 0.1, 0.62, 0.84])
    ax.set_xlim(0, W); ax.set_ylim(H, 0); ax.set_aspect('equal')
    ax.set_xlabel('x [px]'); ax.set_ylabel('y [px]')
    return fig, ax


# ---------------------------------------------------------------- A1 raw event stream
def a_events():
    E = npz('events')
    t, x, y, p = E['t'], E['x'], E['y'], E['p']
    fps, dt = 30, 1 / 30
    ts = np.arange(T0, T0 + 6, dt)
    lo = np.searchsorted(t, ts); hi = np.searchsorted(t, ts + dt)
    fig, ax = frame_axes()
    img = ax.imshow(np.ones((H, W, 3)), extent=(0, W, H, 0), interpolation='nearest')
    txt = fig.text(0.73, 0.82, '', fontsize=9, color=DARK, va='top', linespacing=1.6)
    fig.text(0.73, 0.4, '● ON  (+1)', color=POS, fontsize=9); fig.text(0.73, 0.33, '● OFF (−1)', color=NEG, fontsize=9)
    fig.text(0.73, 0.2, '33 ms of events per frame\nplayed in real time', fontsize=8, color=DARK)
    pos = np.array([0xE9, 0x1C, 0x24]) / 255; neg = np.array([0x11, 0x66, 0xAA]) / 255

    def upd(i):
        s = slice(lo[i], hi[i])
        im = np.ones((H, W, 3))
        xi = np.clip(np.round(x[s]).astype(int), 0, W - 1); yi = np.clip(np.round(y[s]).astype(int), 0, H - 1)
        im[yi[p[s] > 0], xi[p[s] > 0]] = pos
        im[yi[p[s] <= 0], xi[p[s] <= 0]] = neg
        img.set_data(im)
        txt.set_text(f't = {ts[i]:.2f} s\n{hi[i]-lo[i]:,} events')
        return img, txt
    anim = FuncAnimation(fig, upd, frames=len(ts), blit=False)
    finish(fig, anim, 'A1_events', fps, len(ts) // 2)


# ---------------------------------------------------------------- A2 warm-start tracking
def a_tracks():
    E = npz('events'); S = npz('surface'); Wt = load('warm_tracks')
    t, x, y = E['t'], E['x'], E['y']
    acc, flow = S['accept'], S['flow']
    st, obs = Wt['slice_times'], Wt['obs']
    fig, ax = frame_axes()
    bg = ax.scatter([], [], s=0.4, c=GREY, linewidths=0)
    from matplotlib.collections import LineCollection
    lc = LineCollection([], colors=RED, linewidths=1.0)
    ax.add_collection(lc)
    heads = ax.scatter([], [], s=6, c=BLACK, linewidths=0)
    txt = fig.text(0.73, 0.82, '', fontsize=9, color=DARK, va='top', linespacing=1.6)
    fig.text(0.73, 0.35, 'grey: flow-warped accepted events\nred: last 1 s of each track\nblack: current estimate', fontsize=8, color=DARK, linespacing=1.5)

    def upd(i):
        tc = st[i]
        m = acc & (t >= tc - 0.05) & (t < tc + 0.05)
        wx = x[m] - flow[m, 0] * (t[m] - tc); wy = y[m] - flow[m, 1] * (t[m] - tc)
        bg.set_offsets(np.c_[wx, wy])
        segs, hd = [], []
        for k in range(obs.shape[1]):
            f = np.flatnonzero(np.isfinite(obs[:i + 1, k, 0]))
            f = f[f >= i - 10]
            if len(f) and f[-1] == i:
                segs.append(obs[f, k, :2]); hd.append(obs[i, k, :2])
        lc.set_segments(segs)
        heads.set_offsets(np.array(hd).reshape(-1, 2))
        txt.set_text(f't = {tc:.2f} s\n{len(hd)} active tracks\n{m.sum():,} events in slice')
    anim = FuncAnimation(fig, upd, frames=len(st))
    finish(fig, anim, 'A2_tracks', 10, len(st) - 1)


def axis_frame(a):
    a = a / np.linalg.norm(a)
    t1, t2 = geom.axis_tangent(a)
    return np.c_[t1, t2, a].T


# ---------------------------------------------------------------- A3 map growth (3D)
def a_growth():
    P = load('progressive'); Fn = load('final')
    snaps = P['snaps']
    Rf = axis_frame(Fn['final']['traj']['a'])
    Xend = snaps[-1]['X']
    c = Xend.mean(0)
    lim = np.percentile(np.abs((Xend - c) @ Rf.T), 99) * 1.1
    fig = plt.figure(figsize=FIG, facecolor='white')
    ax = fig.add_axes([-0.05, -0.08, 0.75, 1.16], projection='3d')
    txt = fig.text(0.7, 0.8, '', fontsize=9, color=DARK, va='top', linespacing=1.6)
    fig.text(0.7, 0.35, 'red: promoted in the last second\ndark: existing landmarks\n(model units, spin axis vertical)', fontsize=8, color=DARK, linespacing=1.5)
    nf = len(snaps)

    def upd(i):
        ax.cla()
        s = snaps[i]
        Q = (s['X'] - c) @ Rf.T
        n_prev = len(snaps[i - 1]['X']) if i else 0
        ax.scatter(Q[:n_prev, 0], Q[:n_prev, 1], Q[:n_prev, 2], s=2, c=DARK, depthshade=False, linewidths=0)
        ax.scatter(Q[n_prev:, 0], Q[n_prev:, 1], Q[n_prev:, 2], s=7, c=RED, depthshade=False, linewidths=0)
        ax.set_xlim(-lim, lim); ax.set_ylim(-lim, lim); ax.set_zlim(-lim, lim); ax.set_box_aspect((1, 1, 1))
        ax.view_init(elev=18, azim=-60 + 360 * i / nf)
        ax.set_xticklabels([]); ax.set_yticklabels([]); ax.set_zticklabels([])
        for a in (ax.xaxis, ax.yaxis, ax.zaxis):
            a.pane.set_facecolor((1, 1, 1, 0)); a.pane.set_edgecolor(LIGHT); a._axinfo['grid']['color'] = PALE
        txt.set_text(f't = {s["tc"]:.1f} s\n{len(s["X"])} landmarks\n{s["n_obs"]:,} observations')
    anim = FuncAnimation(fig, upd, frames=nf)
    finish(fig, anim, 'A3_growth', 12, nf - 1)


# ---------------------------------------------------------------- A4 final cloud turntable
def a_cloud():
    Fn = load('final')
    Rf = axis_frame(Fn['final']['traj']['a'])
    Q = (Fn['X_m'] - Fn['X_m'].mean(0)) @ Rf.T
    lim = np.percentile(np.abs(Q), 99.5) * 1.05
    nob = np.log10(Fn['nobs'])
    fig = plt.figure(figsize=FIG, facecolor='white')
    ax = fig.add_axes([-0.05, -0.08, 0.75, 1.16], projection='3d')
    fig.text(0.7, 0.8, f'{len(Q)} landmarks\nmetres (provisional scale)\nspin axis vertical\ncolour: observation count', fontsize=9, color=DARK, va='top', linespacing=1.6)
    sc = ax.scatter(Q[:, 0], Q[:, 1], Q[:, 2], s=5, c=nob, cmap=CMAP_GREYRED, depthshade=False, linewidths=0)
    ax.set_xlim(-lim, lim); ax.set_ylim(-lim, lim); ax.set_zlim(-lim, lim); ax.set_box_aspect((1, 1, 1))
    ax.set_xlabel('u [m]', labelpad=-4); ax.set_ylabel('v [m]', labelpad=-4); ax.set_zlabel('axis [m]', labelpad=-4)
    ax.tick_params(labelsize=7, pad=-2)
    for a in (ax.xaxis, ax.yaxis, ax.zaxis):
        a.pane.set_facecolor((1, 1, 1, 0)); a.pane.set_edgecolor(LIGHT); a._axinfo['grid']['color'] = PALE

    def upd(i):
        ax.view_init(elev=15 + 10 * np.sin(2 * np.pi * i / 180), azim=-60 + 2 * i)
    anim = FuncAnimation(fig, upd, frames=180)
    finish(fig, anim, 'A4_cloud', 24, 0)


# ---------------------------------------------------------------- A5 map locked onto the events
def a_reprojection():
    E = npz('events'); S = npz('surface'); Fn = load('final')
    t, x, y = E['t'], E['x'], E['y']
    acc = S['accept']
    tr = Fn['final']['traj']; X = Fn['X']
    fps = 10
    a0 = T0 + min(20.0, max(cfg.warm.duration_s, (T1 - T0) / 2 - 6))
    ts = np.arange(a0 + 0.05, min(a0 + 12.05, T1 - 0.05), 0.1)
    fig, ax = frame_axes()
    ev = ax.scatter([], [], s=0.5, c=GREY, linewidths=0)
    lm = ax.scatter([], [], s=12, facecolors='none', edgecolors=RED, linewidths=0.7)
    txt = fig.text(0.73, 0.82, '', fontsize=9, color=DARK, va='top', linespacing=1.6)
    fig.text(0.73, 0.35, 'grey: accepted events (0.1 s)\nred: final landmarks projected\nthrough the refined trajectory', fontsize=8, color=DARK, linespacing=1.5)

    def upd(i):
        tc = ts[i]
        m = acc & (t >= tc - 0.05) & (t < tc + 0.05)
        ev.set_offsets(np.c_[x[m], y[m]])
        R, T = traj.pose(tr, tc)
        uv, Y = geom.project(np.repeat(R, len(X), 0), np.repeat(T, len(X), 0), X, cam)
        k = (Y[:, 2] > 0.2) & (uv[:, 0] > 0) & (uv[:, 0] < W) & (uv[:, 1] > 0) & (uv[:, 1] < H)
        lm.set_offsets(uv[k])
        txt.set_text(f't = {tc:.1f} s\nrotation {np.rad2deg(traj.angle(tr, tc)[0]):.1f}°\n{k.sum()} landmarks in view')
    anim = FuncAnimation(fig, upd, frames=len(ts))
    finish(fig, anim, 'A5_reprojection', fps, len(ts) // 2)


if __name__ == '__main__':
    which = sys.argv[1:] or ['events', 'tracks', 'growth', 'cloud', 'reprojection']
    for w in which:
        globals()['a_' + w]()
