"""Event recordings (AEDAT4 or the pipeline's HDF5) held in memory.

One recording is open at a time. Times are seconds from its first event,
the convention io.load_events uses, so a window chosen here is the window
cfg.data.start_time_s / end_time_s means in the pipeline.
"""
import base64
import hashlib
import json
import os
import threading
import time
from pathlib import Path

import numpy as np

from . import render
from .common import ApiError
from .hub import hub

try:
    import dv_processing as dv
except ImportError:          # the camera and AEDAT4 need it; HDF5 does not
    dv = None
import h5py

EXTS = (".aedat4", ".hdf5", ".h5")


def places():
    home = Path.home()
    cands = [("Pipeline HDF5", home / "esfm_work" / "hdf5"), ("Home", home)]
    pubs = home / "Dropbox" / "Graduate Documents" / "Doctor of Philosophy" / "Publications"
    for p in sorted(pubs.glob("**/Dataset Release 1"))[:2] if pubs.is_dir() else []:
        cands.insert(1, ("Dataset Release 1", p))
    from .common import root
    cands.append(("Project", root()))
    cands.append(("Recordings (Studio)", root() / "recordings"))
    return [{"name": n, "path": str(p)} for n, p in cands if p.is_dir()]


def browse(folder):
    p = Path(folder or Path.home()).expanduser()
    if not p.is_dir():
        raise ApiError(f"Not a folder: {p}")
    dirs, files = [], []
    try:
        for e in sorted(p.iterdir(), key=lambda e: e.name.lower()):
            if e.name.startswith("."):
                continue
            if e.is_dir():
                dirs.append(e.name)
            elif e.suffix.lower() in EXTS:
                st = e.stat()
                files.append({"name": e.name, "size": st.st_size, "mtime": st.st_mtime})
    except PermissionError:
        raise ApiError(f"No access to {p}")
    return {"path": str(p), "parent": str(p.parent) if p.parent != p else None, "dirs": dirs, "files": files}


class Recording:
    def __init__(self, path: Path):
        self.path = path
        self.t_abs = self.x = self.y = self.p = None
        self.width, self.height = 640, 480
        self.camera = ""
        self._hot = None

    @property
    def t(self):
        return self._t

    def load(self, progress):
        if self.path.suffix.lower() == ".aedat4":
            if dv is None:
                raise ApiError("dv_processing is not installed (pip install dv-processing)")
            r = dv.io.MonoCameraRecording(str(self.path))
            if not r.isEventStreamAvailable():
                raise ApiError("This recording has no event stream")
            self.width, self.height = r.getEventResolution()
            self.camera = r.getCameraName()
            t0, t1 = r.getTimeRange()
            chunks, n = [], 0
            last = time.time()
            while r.isRunning():
                b = r.getNextEventBatch()
                if b is None:
                    continue
                a = b.numpy()
                if len(a):
                    chunks.append(a)
                    n += len(a)
                    if time.time() - last > 0.3:
                        last = time.time()
                        progress(min(0.99, (int(a["timestamp"][-1]) - t0) / max(t1 - t0, 1)), n)
            if not chunks:
                raise ApiError("No events in this recording")
            a = np.concatenate(chunks)
            self.t_abs = a["timestamp"].astype(np.int64)
            self.x = a["x"].astype(np.uint16)
            self.y = a["y"].astype(np.uint16)
            self.p = (a["polarity"] > 0).astype(np.uint8)
        else:
            with h5py.File(self.path, "r") as f:
                need = ["timestamp", "x", "y", "polarity"]
                if not all(k in f for k in need):
                    raise ApiError(f"HDF5 needs datasets {need}; this one has {list(f.keys())}")
                n = f["timestamp"].shape[0]
                self.t_abs = np.empty(n, np.int64)
                self.x = np.empty(n, np.uint16)
                self.y = np.empty(n, np.uint16)
                self.p = np.empty(n, np.uint8)
                step = 5_000_000
                for i in range(0, n, step):
                    j = min(n, i + step)
                    self.t_abs[i:j] = f["timestamp"][i:j]
                    self.x[i:j] = f["x"][i:j]
                    self.y[i:j] = f["y"][i:j]
                    self.p[i:j] = (f["polarity"][i:j] > 0)
                    progress(j / n, j)
                self.width = int(f.attrs.get("width", max(640, int(self.x.max()) + 1)))
                self.height = int(f.attrs.get("height", max(480, int(self.y.max()) + 1)))
                self.camera = str(f.attrs.get("camera", "")) or Path(str(f.attrs.get("source_aedat4", ""))).stem
        if self.t_abs.size > 1 and np.any(np.diff(self.t_abs[:: max(1, self.t_abs.size // 100000)]) < 0):
            order = np.argsort(self.t_abs, kind="stable")
            self.t_abs, self.x, self.y, self.p = self.t_abs[order], self.x[order], self.y[order], self.p[order]
        self._t = (self.t_abs - self.t_abs[0]) / 1e6

    # ---------------- views ----------------
    def window(self, t0, dt):
        i = int(np.searchsorted(self._t, t0, "left"))
        j = int(np.searchsorted(self._t, t0 + dt, "left"))
        return i, j

    def summary(self):
        n = int(self._t.size)
        dur = float(self._t[-1]) if n else 0.0
        return {"path": str(self.path), "name": self.path.name, "kind": self.path.suffix.lower()[1:],
                "events": n, "duration_s": dur, "rate_mev_s": n / max(dur, 1e-9) / 1e6,
                "on_fraction": float(self.p.mean()) if n else 0.0, "width": self.width, "height": self.height,
                "camera": self.camera, "size_mb": self.path.stat().st_size / 1e6,
                "first_timestamp_us": int(self.t_abs[0]), "last_timestamp_us": int(self.t_abs[-1]),
                "memory_mb": (self.t_abs.nbytes + self._t.nbytes + self.x.nbytes * 2 + self.p.nbytes) / 1e6}

    def rate(self, bins=1500):
        dur = float(self._t[-1]) or 1.0
        edges = np.linspace(0, dur, bins + 1)
        on = np.histogram(self._t[self.p > 0], edges)[0]
        off = np.histogram(self._t[self.p == 0], edges)[0]
        width = dur / bins
        return {"t": edges[:-1].round(4).tolist(), "bin_s": width,
                "on": (on / width).round(1).tolist(), "off": (off / width).round(1).tolist()}

    def frame(self, t0, dt, mode, cam=None, tau=0.03):
        i, j = self.window(t0, dt)
        x, y = self.x[i:j], self.y[i:j]
        if cam:
            x, y = render.undistort(x, y, cam)
            x, y = np.round(x), np.round(y)
        data = render.frame(x, y, self.p[i:j], self._t[i:j], self.width, self.height, mode,
                            t_ref=t0 + dt, tau=tau)
        return data, j - i

    def cloud(self, t0, dt, n_max=60000, color="polarity", cam=None):
        i, j = self.window(t0, dt)
        idx = np.arange(i, j)
        if idx.size > n_max:
            idx = np.sort(np.random.default_rng(0).choice(idx, n_max, replace=False))
        x = self.x[idx].astype(np.float32)
        y = self.y[idx].astype(np.float32)
        if cam:
            xu, yu = render.undistort(x, y, cam)
            x, y = xu.astype(np.float32), yu.astype(np.float32)
        t = ((self._t[idx] - t0) * 1000).astype(np.float32)          # ms into the window
        p = self.p[idx]
        if color == "time":
            rgb = render.colormap(t / max(dt * 1000, 1e-9), "viridis")
        else:
            rgb = np.where(p[:, None] > 0, render.ON, render.OFF).astype(np.uint8)
        xyz = np.stack([x, y, t], 1).astype(np.float32)
        return {"kind": "points", "n": int(idx.size), "total": int(j - i),
                "xyz": base64.b64encode(xyz.tobytes()).decode(), "rgb": base64.b64encode(rgb.tobytes()).decode(),
                "axes": ["x [px]", "y [px]", "t [ms]"], "extent": [self.width, self.height, dt * 1000],
                "space": "image"}

    def hot(self):
        if self._hot is None:
            n = self.width * self.height
            idx, _ = render.pixel_index(self.x, self.y, self.width, self.height)
            self._hot = np.bincount(idx, minlength=n)
        c = self._hot
        dur = float(self._t[-1]) or 1.0
        top = np.argsort(c)[::-1][:25]
        med = float(np.median(c[c > 0])) if (c > 0).any() else 0.0
        return render.heat(c, self.width, self.height), {
            "top": [{"x": int(k % self.width), "y": int(k // self.width), "count": int(c[k]),
                     "rate_hz": round(float(c[k]) / dur, 1), "x_median": round(float(c[k]) / max(med, 1), 1)} for k in top],
            "median_rate_hz": round(med / dur, 2), "active_pixels": int((c > 0).sum())}

    def convert(self, out: Path, overwrite, progress):
        out = Path(out).expanduser()
        if out.exists() and not overwrite:
            raise ApiError(f"{out} exists (tick Overwrite to replace it)", 409)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(out.suffix + ".tmp")
        n = self.t_abs.size
        with h5py.File(tmp, "w") as f:
            fields = {"timestamp": (self.t_abs, np.int64), "x": (self.x, np.uint16),
                      "y": (self.y, np.uint16), "polarity": (self.p, np.uint8)}
            for k, (name, (arr, dt)) in enumerate(fields.items()):
                f.create_dataset(name, data=arr.astype(dt, copy=False), chunks=(262144,))
                progress((k + 1) / 4)
            f.attrs.update(source=str(self.path), timestamp_unit="microseconds", width=self.width,
                           height=self.height, event_count=n, camera=self.camera)
        os.replace(tmp, out)
        manifest = {"source": str(self.path), "output": str(out), "events": int(n),
                    "first_timestamp_us": int(self.t_abs[0]), "last_timestamp_us": int(self.t_abs[-1]),
                    "duration_s": float(self._t[-1]), "resolution": [self.width, self.height],
                    "conversion": "Event Studio: all events, absolute timestamps and polarity, no filtering."}
        out.with_suffix(".conversion.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return manifest


class Store:
    def __init__(self):
        self.rec = None
        self.loading = None
        self._lock = threading.Lock()

    def open(self, path):
        p = Path(path).expanduser()
        if not p.is_file() or p.suffix.lower() not in EXTS:
            raise ApiError(f"Not a recording: {p}")
        with self._lock:
            if self.loading:
                raise ApiError("A recording is already loading", 409)
            self.loading = {"path": str(p), "fraction": 0.0, "events": 0}
        threading.Thread(target=self._load, args=(p,), daemon=True).start()
        return self.loading

    def _load(self, p):
        rec = Recording(p)
        t0 = time.time()

        def progress(frac, n):
            self.loading.update(fraction=round(frac, 3), events=int(n))
            hub.publish("recording", {"loading": self.loading})
        try:
            rec.load(progress)
        except Exception as e:  # noqa: BLE001 - reported to the browser
            self.loading = None
            hub.log(f"Could not open {p.name}: {e}", "err", "data")
            hub.publish("recording", {"loading": None, "error": str(e)})
            return
        self.rec = rec
        self.loading = None
        s = rec.summary()
        hub.log(f"Opened {p.name}: {s['events']:,} events, {s['duration_s']:.1f} s ({time.time() - t0:.1f} s to load)",
                "ok", "data")
        hub.publish("recording", {"loading": None, "summary": s})

    def close(self):
        if self.rec:
            hub.log(f"Closed {self.rec.path.name} (memory freed)", "info", "data")
        self.rec = None
        hub.publish("recording", {"loading": None, "summary": None, "closed": True})
        return self.status()

    def get(self):
        if not self.rec:
            raise ApiError("No recording open", 404)
        return self.rec

    def status(self):
        return {"loading": self.loading, "summary": self.rec.summary() if self.rec else None}


store = Store()
