"""Stage 3 - warm-start 2D tracks and observations (track.track_events, build/flatten_observations)."""
import numpy as np
from common import get_cfg, save, Timer, CACHE
from esfm import track

cfg = get_cfg()
e = np.load(f'{CACHE}/events.npz')
s = np.load(f'{CACHE}/surface.npz')
t0 = cfg.data.start_time_s
t1 = t0 + cfg.warm.duration_s
a = s['accept'] & (e['t'] >= t0) & (e['t'] < t1)
rec = {}
with Timer('track'):
    tracks, slice_times = track.track_events(e['t'][a], e['x'][a], e['y'][a], s['flow'][a],
                                             cfg.data.slice_s, cfg.track, record=rec)
obs, track_ids = track.build_observations(tracks, slice_times)
fi, ii, uv, nn = track.flatten_observations(obs)
print(f'{len(tracks)} tracks, {obs.shape[1]} kept, {fi.size} observations')
save('warm_tracks', dict(tracks=tracks, slice_times=slice_times, obs=obs, track_ids=track_ids,
                         fi=fi, ii=ii, uv=uv, nn=nn, record=rec))
