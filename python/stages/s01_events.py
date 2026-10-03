"""Stage 1 - load events in [T0, T1) and undistort them (io.load_events, geom.undistort_equidistant)."""
import numpy as np
from common import get_cfg, get_cam, save, Timer, CACHE
from esfm import data, geom

cfg = get_cfg()
cam = get_cam(cfg)
with Timer('load'):
    ev = data.load_events(cfg.data.hdf5_path, cfg.data.start_time_s, cfg.data.end_time_s)
print(f'{ev.t.size:,} events, {ev.t[0]:.3f} .. {ev.t[-1]:.3f} s')
with Timer('undistort'):
    xy = geom.undistort_equidistant(np.c_[ev.x, ev.y], cam)
np.savez(f'{CACHE}/events.npz', t=ev.t, x=xy[:, 0], y=xy[:, 1], p=ev.p,
         x_raw=ev.x.astype(np.float32), y_raw=ev.y.astype(np.float32))
