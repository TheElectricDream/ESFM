"""Event frames and colours, shared by recordings and the live view.

Frames are RGBA bytes (row-major, width x height) the browser puts straight
into a canvas. Colours follow the app's palette: ON events blue, OFF events
red, on the app's dark background.
"""
import numpy as np

BG = np.array([11, 13, 17], np.float32)
ON = np.array([76, 141, 255], np.float32)
OFF = np.array([240, 84, 90], np.float32)

_VIRIDIS = np.array([[68, 1, 84], [72, 40, 120], [62, 74, 137], [49, 104, 142], [38, 130, 142],
                     [31, 158, 137], [53, 183, 121], [110, 206, 88], [181, 222, 43], [253, 231, 37]], np.float32)
_INFERNO = np.array([[0, 0, 4], [31, 12, 72], [85, 15, 109], [136, 34, 106], [186, 54, 85],
                     [227, 89, 51], [249, 140, 10], [249, 201, 50], [252, 255, 164]], np.float32)


def colormap(v, name="viridis"):
    """Values in [0, 1] -> uint8 RGB."""
    lut = _VIRIDIS if name == "viridis" else _INFERNO
    v = np.clip(np.nan_to_num(v), 0, 1) * (len(lut) - 1)
    i = np.minimum(v.astype(np.int32), len(lut) - 2)
    f = (v - i)[..., None]
    return (lut[i] * (1 - f) + lut[i + 1] * f).astype(np.uint8)


def _rgba(rgb, w, h):
    out = np.empty((h * w, 4), np.uint8)
    out[:, :3] = np.clip(rgb.reshape(-1, 3), 0, 255)
    out[:, 3] = 255
    return out.tobytes()


def pixel_index(x, y, w, h):
    xi = np.asarray(x).astype(np.int64)
    yi = np.asarray(y).astype(np.int64)
    ok = (xi >= 0) & (xi < w) & (yi >= 0) & (yi < h)
    return yi[ok] * w + xi[ok], ok


def _norm(c, pct=99.0):
    nz = c[c > 0]
    if nz.size == 0:
        return c.astype(np.float32)
    s = max(float(np.percentile(nz, pct)), 1.0)
    return np.sqrt(np.clip(c / s, 0, 1)).astype(np.float32)


def frame(x, y, p, t, w, h, mode="polarity", t_ref=None, tau=0.03):
    """RGBA bytes of one frame from events (x, y in pixels, p in {0,1}, t in s)."""
    n = w * h
    idx, ok = pixel_index(x, y, w, h)
    p = np.asarray(p)[ok]
    if mode == "polarity":
        on = np.bincount(idx[p > 0], minlength=n)
        off = np.bincount(idx[p == 0], minlength=n)
        a_on, a_off = _norm(on)[:, None], _norm(off)[:, None]
        rgb = BG + a_on * (ON - BG) + a_off * (OFF - BG)
        return _rgba(rgb, w, h)
    if mode == "count":
        c = np.bincount(idx, minlength=n).astype(np.float32)
        v = np.log1p(c) / max(np.log1p(np.percentile(c[c > 0], 99.5)) if (c > 0).any() else 1, 1e-6)
        rgb = colormap(v, "inferno").astype(np.float32)
        rgb[c == 0] = BG
        return _rgba(rgb, w, h)
    if mode == "timesurface":
        t = np.asarray(t)[ok]
        t_ref = float(t.max()) if t_ref is None and t.size else (t_ref or 0.0)
        last_on = np.full(n, -np.inf)
        last_off = np.full(n, -np.inf)
        last_on[idx[p > 0]] = t[p > 0]
        last_off[idx[p == 0]] = t[p == 0]
        s_on = np.exp(-(t_ref - last_on) / max(tau, 1e-6))[:, None]
        s_off = np.exp(-(t_ref - last_off) / max(tau, 1e-6))[:, None]
        rgb = BG + s_on * (ON - BG) + s_off * (OFF - BG)
        return _rgba(rgb, w, h)
    raise ValueError(f"unknown frame mode {mode}")


def heat(counts, w, h):
    c = np.asarray(counts, np.float32)
    top = np.percentile(c[c > 0], 99.9) if (c > 0).any() else 1
    v = np.log1p(c) / np.log1p(max(top, 1))
    rgb = colormap(v, "inferno").astype(np.float32)
    rgb[c == 0] = BG
    return _rgba(rgb, w, h)


def undistort(x, y, cam):
    """Kannala-Brandt (equidistant) undistortion, as geom.undistort_equidistant."""
    fx, fy = cam["fx"], cam["fy"]
    cx, cy = cam["cx"], cam["cy"]
    k1, k2 = cam.get("k1", 0.0), cam.get("k2", 0.0)
    xd = (np.asarray(x, np.float64) - cx) / fx
    yd = (np.asarray(y, np.float64) - cy) / fy
    td = np.sqrt(xd ** 2 + yd ** 2)
    th = td.copy()
    for _ in range(8):
        t2 = th ** 2
        th = th - (th * (1 + k1 * t2 + k2 * t2 ** 2) - td) / (1 + 3 * k1 * t2 + 5 * k2 * t2 ** 2)
    scale = np.ones_like(td)
    nz = td > 1e-9
    scale[nz] = np.tan(th[nz]) / td[nz]
    return fx * xd * scale + cx, fy * yd * scale + cy
