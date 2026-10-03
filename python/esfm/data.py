"""+io: event loading, calibration, export."""
import re
import numpy as np
import h5py
from types import SimpleNamespace as NS


def _find(f, names):
    hits = []
    f.visititems(lambda k, v: hits.append(k) if isinstance(v, h5py.Dataset) else None)
    for n in names:
        for k in hits:
            if k.split('/')[-1].lower() == n:
                return k
    raise KeyError(f'none of {names} in {hits}')


def load_events(path, start_time_s, end_time_s):
    """io.load_events: timestamps [us] -> [s] from the first event, window, p in {-1,+1}."""
    with h5py.File(path, 'r') as f:
        kt = _find(f, ['timestamp', 't', 'ts', 'timestamps'])
        t = f[kt][:].astype(np.float64)
        t = (t - t[0]) / 1e6
        sel = np.flatnonzero((t >= start_time_s) & (t < end_time_s))
        a, b = sel[0], sel[-1] + 1
        x = f[_find(f, ['x'])][a:b].astype(np.float64)
        y = f[_find(f, ['y'])][a:b].astype(np.float64)
        p = f[_find(f, ['polarity', 'p', 'pol'])][a:b].astype(np.int8)
    t = t[a:b]
    p = np.where(p <= 0, -1, 1).astype(np.int8)
    return NS(t=t, x=x, y=y, p=p)


def read_calibration(xml_path):
    text = open(xml_path).read()
    K = np.array(re.search(r'<camera_matrix.*?<data>(.*?)</data>', text, re.S).group(1).split(), float)
    d = np.array(re.search(r'<distortion_coefficients.*?<data>(.*?)</data>', text, re.S).group(1).split(), float)
    w = int(re.search(r'<image_width>\s*(\d+)', text).group(1))
    h = int(re.search(r'<image_height>\s*(\d+)', text).group(1))
    return NS(focal=np.array([K[0], K[4]]), principal=np.array([K[2], K[5]]),
              k1=d[0], k2=d[1] if d.size > 1 else 0.0, image_size=np.array([w, h]))


def write_ply(path, P):
    with open(path, 'w') as fh:
        fh.write(f'ply\nformat ascii 1.0\nelement vertex {len(P)}\n'
                 'property double x\nproperty double y\nproperty double z\nend_header\n')
        np.savetxt(fh, P, fmt='%.17g')
