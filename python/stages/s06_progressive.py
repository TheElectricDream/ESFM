"""Stage 6 - progressive loop over 0.1 s slices (prog.step, local/global adjustment)."""
import time
import numpy as np
from common import get_cfg, get_cam, save, load, CACHE
from esfm import prog, traj

cfg = get_cfg()
cam = get_cam(cfg)
e = np.load(f'{CACHE}/events.npz')
s = np.load(f'{CACHE}/surface.npz')
S = load('seed_map')
t, x, y, flow, accept = e['t'], e['x'], e['y'], s['flow'], s['accept']
warm_end = cfg.data.start_time_s + cfg.warm.duration_s
m = prog.create_map(S['traj'], S['X'], S['O'])
dt = cfg.data.slice_s
n_c = int(round((cfg.data.end_time_s - dt / 2 - (warm_end + dt / 2)) / dt)) + 1
centers = warm_end + dt / 2 + dt * np.arange(n_c)
acc, first, last = prog.slice_events(t, accept, centers, dt)
m['knots_free'] = True
n_at_global = len(m['O'])
log = np.full((n_c, 6), np.nan)
online = dict(t=centers, theta=np.full(n_c, np.nan), T=np.full((n_c, 3), np.nan),
              a=np.full((n_c, 3), np.nan), omega=np.full(n_c, np.nan))
snap_every = int(round(1.0 / dt))
snaps, details, events_log, local_log, global_log = [], {}, [], [], []
DETAIL_T = [float(v) for v in __import__('os').environ.get('ESFM_DETAIL_T', '80.05,120.05').split(',')]
t_prev = warm_end
tic = time.time()
for f, tc in enumerate(centers):
    sl = acc[first[f]:last[f]]
    slc = dict(t=t[sl], x=x[sl], y=y[sl], flow=flow[sl])
    keep = any(abs(tc - d) < dt / 2 for d in DETAIL_T)
    m, info = prog.step(m, slc, tc, cfg, cam, keep_detail=keep)
    if keep:
        details[round(tc, 3)] = dict(info=info, slc=slc, X=m['X'].copy(), traj=traj.copy_traj(m['traj']))
    if prog.crossed(t_prev, tc, cfg.prog.local_every_s, m['traj']['t0']):
        m, li = prog.local_adjust(m, tc, cam, cfg)
        local_log.append((tc, li['rms'], li['accepted_steps']))
    if len(m['O']) >= cfg.prog.global_growth * n_at_global:
        t_g = time.time()
        m, gi = prog.global_adjust(m, tc, cam, cfg)
        n_at_global = len(m['O'])
        global_log.append((tc, int(m['alive'].sum()), gi['accepted_steps'], gi['rms'], time.time() - t_g))
        print(f'  global at {tc:.1f} s: {m["alive"].sum()} pts, {gi["accepted_steps"]} steps, RMS {gi["rms"]:.3f} px', flush=True)
    online['theta'][f] = traj.angle(m['traj'], tc)[0]
    online['T'][f] = traj.translation(m['traj'], tc)[0]
    online['a'][f] = m['traj']['a']
    online['omega'][f] = m['traj']['omega']
    rate = traj.rate_deg_s(m['traj'], tc)[0]
    log[f] = [tc, rate, m['alive'].sum(), info['explained'], info['matched'], info['n_new']]
    events_log.append((len(sl), info.get('n_cand', 0), info['promo']['attempted'], info['correction_steps']))
    if f % snap_every == 0:
        snaps.append(dict(tc=tc, X=m['X'].copy(), nobs=m['nobs'].copy(), traj=traj.copy_traj(m['traj']),
                          n_obs=len(m['O'])))
    if prog.crossed(t_prev, tc, 10, m['traj']['t0']):
        print(f't = {tc:.1f} s: map {m["alive"].sum()}, matched {info["matched"]}, explained {100*info["explained"]:.0f} %, '
              f'rate {rate:.3f} deg/s, rows {len(m["O"])} ({time.time()-tic:.0f} s)', flush=True)
    t_prev = tc
save('progressive', dict(map=m, log=log, online=online, snaps=snaps, details=details, centers=centers,
                         events_log=np.array(events_log), local_log=np.array(local_log),
                         global_log=np.array(global_log)))
