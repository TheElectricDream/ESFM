"""Live events: the DVXplorer (any iniVation camera dv_processing can open),
or a recording replayed in real time so the page can be tried without one.

A reader thread keeps the last few seconds of events; the browser asks for
frames (RGBA, the same renderer as the Data page) and the recent event
cloud as fast as it can draw them. Camera sessions can be recorded to
AEDAT4 (dv_processing's writer), which the Data page then opens or converts.
"""
import base64
import threading
import time
from collections import deque
from pathlib import Path

import numpy as np

from . import render
from . import settings
from .common import ApiError, root
from .hub import hub
from .recordings import store

try:
    import dv_processing as dv
except ImportError:
    dv = None

KEEP_S = 3.0


def discover():
    if dv is None:
        return {"available": False, "devices": [], "reason": "dv_processing is not installed"}
    out = []
    try:
        for d in dv.io.camera.discover():
            out.append({k: str(getattr(d, k)) for k in ("serialNumber", "cameraModel", "deviceName", "busNumber", "devAddress")
                        if hasattr(d, k)})
    except Exception as e:  # noqa: BLE001
        return {"available": True, "devices": [], "reason": str(e)}
    return {"available": True, "devices": out}


class Live:
    def __init__(self):
        self.source = None          # 'camera' | 'replay'
        self.cam = None
        self.thread = None
        self.running = False
        self.buf = deque()          # (t_us int64 array, x, y, p)
        self.lock = threading.Lock()
        self.name, self.w, self.h = "", 640, 480
        self.total = 0
        self.started = None
        self.t_latest = 0
        self.rate_hist = deque(maxlen=200)   # (wall, count)
        self.writer = None
        self.record_path = None
        self.record_count = 0
        self.replay = {}
        self.error = None
        self.stage = ""
        self.remote = None
        self.remote_controls = []
        self.h5 = None

    # ---------------- sources ----------------
    def start_camera(self, serial=None):
        if dv is None:
            raise ApiError("dv_processing is not installed")
        self.stop()
        try:
            cam = dv.io.camera.open(serial) if serial else dv.io.camera.open()
        except Exception as e:  # noqa: BLE001
            raise ApiError(f"No camera could be opened: {e}. Is the DVXplorer plugged in "
                           "(and the udev rule for iniVation devices installed)?", 404)
        if not cam.isEventStreamAvailable():
            raise ApiError("The camera has no event stream")
        self.cam = cam
        self.name = cam.getCameraName()
        self.w, self.h = cam.getEventResolution()
        self._begin("camera", self._camera_loop)
        return self.status()

    def start_remote(self, serial=None, replay=None):
        """Stream the DVXplorer plugged into the remote computer (settings 'remote')."""
        from .remote import RemoteStream
        self.stop()
        cfg = settings.get("remote")
        self.name = f"{cfg['host']} (connecting)"
        self.source, self.error, self.stage = "remote", None, "Connecting…"
        self.buf.clear()
        self.total = 0
        self.started = time.time()
        self.running = True
        self.remote_controls = []

        def on_stage(text):
            self.stage = text
            hub.publish("live", self.status())

        def on_msg(m):
            if m.get("type") == "hello":
                self.name = f"{m['name']} on {m.get('host', cfg['host'])}"
                self.w, self.h = m["width"], m["height"]
                self.remote_controls = m.get("controls", [])
                self.stage = "Streaming"
                hub.log(f"Live: {self.name} ({self.w}x{self.h})", "ok", "live")
            elif m.get("type") == "controls":
                self.remote_controls = m["controls"]
            elif m.get("type") == "error":
                self.error = m["message"]
                self.running = False
                hub.log(m["message"], "err", "remote")
            hub.publish("live", self.status())

        def work():
            self.remote = RemoteStream(cfg, lambda t, x, y, p: self._push(t, x, y, p), on_msg, on_stage)
            try:
                self.remote.start(serial or cfg.get("serial") or None, replay)
            except Exception as e:  # noqa: BLE001
                self.error, self.running = str(e), False
                self.stage = ""
                hub.log(str(e), "err", "remote")
                hub.publish("live", self.status())
        threading.Thread(target=work, daemon=True).start()
        hub.publish("live", self.status())
        return self.status()

    def start_replay(self, speed=1.0, t_start=0.0, loop=True):
        rec = store.get()
        self.stop()
        self.name = f"Replay: {rec.path.name}"
        self.w, self.h = rec.width, rec.height
        self.replay = {"speed": max(0.05, float(speed)), "t_start": float(t_start), "loop": bool(loop),
                       "path": str(rec.path), "duration": float(rec.t[-1])}
        self._begin("replay", self._replay_loop, rec)
        return self.status()

    def _begin(self, source, target, *args):
        self.source = source
        self.buf.clear()
        self.total = 0
        self.error = None
        self.started = time.time()
        self.running = True
        self.thread = threading.Thread(target=target, args=args, daemon=True)
        self.thread.start()
        hub.log(f"Live: {self.name} ({self.w}x{self.h})", "ok", "live")
        hub.publish("live", self.status())

    def stop(self):
        self.running = False
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=2)
        self._stop_record()
        if self.remote is not None:
            self.remote.stop()
            self.remote = None
        self.thread = None
        self.cam = None
        self.stage = ""
        if self.source:
            hub.log("Live stopped", "info", "live")
        self.source = None
        hub.publish("live", self.status())
        return self.status()

    def _push(self, t, x, y, p):
        with self.lock:
            self.buf.append((t, x, y, p))
            self.t_latest = int(t[-1])
            cutoff = self.t_latest - int(KEEP_S * 1e6)
            while self.buf and self.buf[0][0][-1] < cutoff:
                self.buf.popleft()
            self.total += len(t)
            self.rate_hist.append((time.time(), len(t)))
            if self.h5 is not None:
                self.h5.append(t, x, y, p)

    def _camera_loop(self):
        try:
            while self.running and self.cam.isRunning():
                b = self.cam.getNextEventBatch()
                if b is None:
                    time.sleep(0.001)
                    continue
                if self.writer is not None:
                    self.writer.writeEvents(b)
                    self.record_count += len(b)
                a = b.numpy()
                if len(a):
                    self._push(a["timestamp"].astype(np.int64), a["x"], a["y"], (a["polarity"] > 0).astype(np.uint8))
        except Exception as e:  # noqa: BLE001
            self.error = str(e)
            hub.log(f"Camera stopped: {e}", "err", "live")
        self.running = False
        hub.publish("live", self.status())

    def _replay_loop(self, rec):
        r = self.replay
        t = rec.t
        pos = int(np.searchsorted(t, r["t_start"]))
        wall0, rec0 = time.time(), r["t_start"]
        offset = 0
        while self.running:
            now_rec = rec0 + (time.time() - wall0) * r["speed"]
            end = int(np.searchsorted(t, now_rec))
            if end > pos:
                sl = slice(pos, end)
                # re-based to a monotonic clock so a loop never goes back in time
                self._push(rec.t_abs[sl] - rec.t_abs[0] + offset, rec.x[sl], rec.y[sl], rec.p[sl])
                pos = end
            if pos >= t.size:
                if not r["loop"]:
                    break
                offset += int(t[-1] * 1e6) + 1000
                pos, wall0, rec0 = 0, time.time(), 0.0
            r["position"] = round(now_rec, 2)
            time.sleep(0.008)
        self.running = False
        hub.publish("live", self.status())

    # ---------------- views ----------------
    def _recent(self, window_s):
        with self.lock:
            if not self.buf:
                return None
            lo = self.t_latest - int(window_s * 1e6)
            parts = [b for b in self.buf if b[0][-1] >= lo]
        t = np.concatenate([b[0] for b in parts])
        k = int(np.searchsorted(t, lo))
        cat = [np.concatenate([b[i] for b in parts])[k:] for i in (1, 2, 3)]
        return t[k:], cat[0], cat[1], cat[2]

    def frame(self, window_ms=33, mode="polarity", tau_ms=30, cam=None):
        ev = self._recent(window_ms / 1000 if mode != "timesurface" else max(window_ms, 5 * tau_ms) / 1000)
        if ev is None:
            return render.frame(np.zeros(0), np.zeros(0), np.zeros(0), np.zeros(0), self.w, self.h), 0
        t, x, y, p = ev
        if cam:
            x, y = render.undistort(x, y, cam)
            x, y = np.round(x), np.round(y)
        ts = t / 1e6
        return render.frame(x, y, p, ts, self.w, self.h, mode, t_ref=self.t_latest / 1e6, tau=tau_ms / 1000), int(t.size)

    def cloud(self, window_ms=500, n_max=40000):
        ev = self._recent(window_ms / 1000)
        if ev is None:
            raise ApiError("No events yet", 404)
        t, x, y, p = ev
        idx = np.arange(t.size)
        if idx.size > n_max:
            idx = np.sort(np.random.default_rng().choice(idx, n_max, replace=False))
        tt = ((t[idx] - t[idx][0]) / 1000).astype(np.float32)
        xyz = np.stack([x[idx].astype(np.float32), y[idx].astype(np.float32), tt], 1)
        rgb = np.where(p[idx, None] > 0, render.ON, render.OFF).astype(np.uint8)
        return {"kind": "points", "n": int(idx.size), "total": int(t.size),
                "xyz": base64.b64encode(xyz.tobytes()).decode(), "rgb": base64.b64encode(rgb.tobytes()).decode(),
                "axes": ["x [px]", "y [px]", "t [ms]"], "extent": [self.w, self.h, window_ms], "space": "image"}

    def status(self):
        now = time.time()
        recent = [c for w, c in self.rate_hist if now - w < 1.0]
        st = {"source": self.source, "running": self.running, "name": self.name, "width": self.w,
              "height": self.h, "total": self.total, "rate_ev_s": sum(recent),
              "uptime_s": round(now - self.started, 1) if self.started and self.source else 0,
              "recording": ({"path": self.record_path, "events": self.record_count} if self.writer else
                            {"path": str(self.h5.path), "events": self.h5.n} if self.h5 else None),
              "replay": self.replay if self.source == "replay" else None, "error": self.error,
              "controls": self.controls() if self.source == "camera" else self.remote_controls if self.source == "remote" else None,
              "stage": self.stage}
        return st

    # ---------------- camera controls ----------------
    CONTROLS = [("ContrastThresholdOn", "ON threshold", "int"), ("ContrastThresholdOff", "OFF threshold", "int"),
                ("FlipHorizontal", "Flip horizontal", "bool"), ("FlipVertical", "Flip vertical", "bool")]

    def controls(self):
        out = []
        for key, label, kind in self.CONTROLS:
            g = getattr(self.cam, "get" + key, None)
            if g:
                try:
                    out.append({"key": key, "label": label, "kind": kind, "value": g()})
                except Exception:  # noqa: BLE001
                    pass
        return out

    def set_control(self, key, value):
        if self.source == "remote" and self.remote is not None:
            self.remote.send({"cmd": "set", "key": key, "value": value})
            return self.status()
        if self.source != "camera":
            raise ApiError("Only for a camera")
        if key not in {k for k, _, _ in self.CONTROLS}:
            raise ApiError("Unknown control")
        s = getattr(self.cam, "set" + key, None)
        if not s:
            raise ApiError("This camera has no such control")
        s(bool(value) if isinstance(value, bool) else int(value))
        return self.status()

    # ---------------- recording ----------------
    def start_record(self, folder=None):
        """A local camera records AEDAT4 (dv_processing's writer); a remote camera
        or a replay records the pipeline's HDF5 (timestamp, x, y, polarity)."""
        if not self.running:
            raise ApiError("Start a stream first")
        if self.writer is not None or self.h5 is not None:
            raise ApiError("Already recording")
        folder = Path(folder or root() / "recordings").expanduser()
        folder.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime('%Y%m%d_%H%M%S')
        if self.source != "camera":
            path = folder / f"live_{stamp}.hdf5"
            self.h5 = _H5Recorder(path, self.w, self.h, self.name)
            self.record_path, self.record_count = str(path), 0
            hub.log(f"Recording to {path}", "ok", "live")
            return self.status()
        path = folder / f"live_{stamp}.aedat4"
        self.writer = dv.io.MonoCameraWriter(str(path), self.cam)
        self.record_path = str(path)
        self.record_count = 0
        hub.log(f"Recording to {path}", "ok", "live")
        return self.status()

    def _stop_record(self):
        if self.h5 is not None:
            h, self.h5 = self.h5, None
            n = h.close()
            hub.log(f"Recorded {n:,} events to {h.path}", "ok", "live")
        if self.writer is not None:
            w, self.writer = self.writer, None
            del w
            hub.log(f"Recorded {self.record_count:,} events to {self.record_path}", "ok", "live")

    def stop_record(self):
        self._stop_record()
        return self.status()


live = Live()


class _H5Recorder:
    """Appends streamed events to an HDF5 file in the pipeline's layout."""

    def __init__(self, path, w, h, name):
        import h5py
        self.path, self.n = Path(path), 0
        self.f = h5py.File(self.path, "w")
        self.d = {k: self.f.create_dataset(k, shape=(0,), maxshape=(None,), dtype=dt, chunks=(65536,))
                  for k, dt in (("timestamp", np.int64), ("x", np.uint16), ("y", np.uint16), ("polarity", np.uint8))}
        self.f.attrs.update(width=w, height=h, camera=name, timestamp_unit="microseconds", source="Event Studio live")

    def append(self, t, x, y, p):
        m = self.n + len(t)
        for k, a in (("timestamp", t), ("x", x), ("y", y), ("polarity", p)):
            self.d[k].resize((m,))
            self.d[k][self.n:m] = a
        self.n = m

    def close(self):
        self.f.attrs["event_count"] = self.n
        self.f.close()
        return self.n
