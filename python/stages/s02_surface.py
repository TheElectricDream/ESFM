"""Stage 2 - local plane fits -> accept mask and normal flow (surface.compute)."""
import numpy as np
from types import SimpleNamespace as NS
from common import get_cfg, Timer, CACHE
from esfm import surface

cfg = get_cfg()
e = np.load(f'{CACHE}/events.npz')
ev = NS(t=e['t'], x=e['x'], y=e['y'], p=e['p'])
with Timer('surface'):
    accept, flow = surface.compute(ev, cfg.surface, [cfg.data.start_time_s, cfg.data.end_time_s], chunk_s=4.0)
print(f'accepted {accept.sum():,} / {accept.size:,} ({100 * accept.mean():.1f} %)')
np.savez(f'{CACHE}/surface.npz', accept=accept, flow=flow.astype(np.float64))
