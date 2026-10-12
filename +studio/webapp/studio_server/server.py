"""HTTP routes, the event stream, and start-up."""
import argparse
import json
import os
import queue
import socket
import sys
import threading
import time
import traceback
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import build, calibration, code_index, config_model, common, journal, lint, settings
from .common import ApiError, STATIC_DIR, cache, mem_info, root, write_json
from .hub import hub
from .live import discover, live
from .matlab_link import matlab
from .pipeline import pipeline
from .recordings import browse, places, store

TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
         ".svg": "image/svg+xml", ".png": "image/png", ".json": "application/json", ".txt": "text/plain"}
_values = {"values": None, "at": None}     # last cfg values read from MATLAB


# ---------------- helpers used by several routes ----------------
def active_cam():
    name, _ = calibration.active_file()
    try:
        c = calibration.read(name)
    except ApiError:
        return None
    return {"fx": c["fx"], "fy": c["fy"], "cx": c["cx"], "cy": c["cy"],
            "k1": c["dist"][0] if c["dist"] else 0.0, "k2": c["dist"][1] if len(c["dist"]) > 1 else 0.0}


def config_values(refresh=False, apply=False):
    """cfg as MATLAB evaluates it (config.m + overrides), flattened; cached."""
    if (refresh or _values["values"] is None) and matlab.state == "idle":
        folder = config_model.write_studio_config()
        try:
            res = matlab.request("config.load", {"dir": str(folder), "apply": apply}, label="Read cfg", timeout=60)
            _values.update(values=res.get("values", {}), at=time.time(), applied=res.get("applied"))
        except ApiError as e:
            _values.update(error=str(e))
    return _values


def config_payload(refresh=False):
    model = config_model.parse()
    vals = config_values(refresh)
    return {**model, "overrides": config_model.overrides(), "values": vals.get("values"),
            "values_at": vals.get("at"), "values_error": vals.get("error")}


INPUT_PATHS = {"data.hdf5_dir", "data.hdf5_file"}


def after_override(path):
    if path in INPUT_PATHS:
        pipeline.fresh_start("new input recording")
    applied = False
    if matlab.state == "idle":
        v = config_values(refresh=True, apply=True)
        applied = bool(v.get("applied"))
    pipeline.on_override(path)
    out = config_payload()
    out["applied_to_workspace"] = applied
    hub.publish("config", {"overrides": out["overrides"]})
    return out


def state():
    name, overridden = calibration.active_file()
    return {"project": str(root()), "host": socket.gethostname(), "pid": os.getpid(),
            "matlab": matlab.status(), "recording": store.status(), "live": live.status(),
            "calibration": {"files": calibration.files(), "active": name, "overridden": overridden},
            "logs": hub.history(), "overrides": config_model.overrides(), "memory": mem_info()}


def q1(qs, k, default=None, cast=str):
    v = qs.get(k, [default])[0]
    if v is None:
        return None
    return cast(v) if cast is not bool else v in ("1", "true", "yes")


# ---------------- routes ----------------
def route(method, path, qs, body):
    # MATLAB
    if path == "/api/state":
        return state()
    if path == "/api/matlab/start":
        return matlab.start_headless()
    if path == "/api/matlab/stop":
        return matlab.stop_headless()
    if path == "/api/matlab/eval":
        code = body.get("code", "")
        if not code.strip():
            raise ApiError("Nothing to run")
        hub.publish("matlab-input", {"code": code})
        res = matlab.request("eval", {"code": code}, label=code.strip().split("\n")[0][:60],
                             log_file=cache() / "eval.log", run_id="eval")
        return res
    if path == "/api/matlab/workspace":
        return matlab.request("ws.list", {}, label="Workspace", timeout=60)
    if path == "/api/matlab/inspect":
        return matlab.request("ws.inspect", {"expr": body.get("expr", "")}, label="Inspect", timeout=60)
    if path == "/api/matlab/view":
        return matlab.request("view", {"expr": body.get("expr", ""), "kind": body.get("kind", ""),
                                       "opts": body.get("opts", {})}, label=f"View {body.get('expr', '')}", timeout=300)
    if path == "/api/matlab/clear":
        res = matlab.request("ws.clear", {"names": body.get("names", [])}, label="Clear", timeout=60)
        return res

    # Code
    if path == "/api/code/index":
        return {"files": [{k: v for k, v in e.items() if k != "help"} for e in code_index.index()],
                "packages": code_index.packages()}
    if path == "/api/code/file" and method == "GET":
        return code_index.read(q1(qs, "path"))
    if path == "/api/code/file" and method == "POST":
        res = code_index.write(body["path"], body["text"], body.get("mtime"), body.get("force", False))
        hub.log(f"Saved {body['path']}" + (f" (backup {res['backup']})" if res.get("backup") else ""), "ok", "code")
        pipeline.on_code_saved(body["path"])
        lint.forget_cache()
        if matlab.state == "idle":
            try:
                matlab.request("rehash", {}, label="rehash", timeout=30)
            except ApiError:
                pass
        hub.publish("code-saved", {"path": body["path"]})
        return res
    if path == "/api/code/symbols":
        params = config_model.parse()
        return {"functions": code_index.symbols(),
                "cfg": [{"text": "cfg." + p["path"], "doc": p["comment"], "kind": p["kind"]} for p in params["params"]]}
    if path == "/api/code/callers":
        return {"callers": code_index.callers(q1(qs, "name"))}
    if path == "/api/code/lint":
        p = common.safe_path(body["path"])
        text = body.get("text")
        return lint.check(body["path"], p.read_text(errors="replace") if text is None else text, matlab)
    if path == "/api/code/open":
        p = common.safe_path(body["path"])
        return matlab.request("edit", {"path": str(p), "line": body.get("line", 1)}, label="Open in editor", timeout=30)

    # Configuration and pipeline
    if path == "/api/config":
        return config_payload(refresh=q1(qs, "refresh", "0", bool))
    if path == "/api/config/override":
        config_model.set_override(body["path"], body.get("expr"))
        hub.log(f"cfg.{body['path']} = {body.get('expr')}" if body.get("expr") else f"cfg.{body['path']}: override removed",
                "cmd", "pipeline")
        return after_override(body["path"])
    if path == "/api/config/clear":
        p = body.get("path")
        if p:
            config_model.set_override(p, None)
        else:
            config_model.clear_overrides()
        return after_override(p or "data")
    if path == "/api/config/save":
        res = config_model.save_to_config(body.get("paths"))
        hub.log(f"Saved {', '.join(res['saved'])} into config.m (backup {res['backup']})", "ok", "pipeline")
        pipeline.on_code_saved("config.m")
        res["config"] = config_payload(refresh=True)
        return res
    if path == "/api/pipeline":
        return pipeline.summary()
    if path == "/api/pipeline/run":
        return pipeline.run(int(body["step"]), body.get("mode", "to"))
    if path == "/api/pipeline/cancel":
        pipeline.cancel = True
        return {"cancelling": True}
    if path == "/api/pipeline/reset":
        if body.get("clear_workspace") and matlab.state == "idle":
            matlab.request("ws.clear", {"names": []}, label="Clear workspace", timeout=60)
        pipeline.reset()
        return pipeline.summary()

    # Data
    if path == "/api/memory":
        return mem_info()
    if path == "/api/data/close":
        from .live import live as _live
        if _live.source == "replay":
            _live.stop()
        return store.close()
    if path == "/api/data/places":
        return {"places": places()}
    if path == "/api/data/browse":
        return browse(q1(qs, "path"))
    if path == "/api/data/open":
        return store.open(body["path"])
    if path == "/api/data/status":
        return store.status()
    if path == "/api/data/rate":
        return store.get().rate(int(q1(qs, "bins", "1500")))
    if path == "/api/data/frame":
        rec = store.get()
        cam = active_cam() if q1(qs, "undistort", "0", bool) else None
        data, n = rec.frame(q1(qs, "t0", "0", float), q1(qs, "dt", "0.033", float), q1(qs, "mode", "polarity"),
                            cam, q1(qs, "tau", "0.03", float))
        return ("bin", data, {"X-W": rec.width, "X-H": rec.height, "X-Count": n})
    if path == "/api/data/cloud":
        cam = active_cam() if q1(qs, "undistort", "0", bool) else None
        return store.get().cloud(q1(qs, "t0", "0", float), q1(qs, "dt", "0.5", float), int(q1(qs, "n", "60000")),
                                 q1(qs, "color", "polarity"), cam)
    if path == "/api/data/hot":
        rec = store.get()
        data, info = rec.hot()
        return ("bin", data, {"X-W": rec.width, "X-H": rec.height, "X-Info": json.dumps(info)})
    if path == "/api/data/convert":
        rec = store.get()
        out = body.get("out") or str(Path.home() / "esfm_work" / "hdf5" / (rec.path.stem + ".hdf5"))

        def work():
            try:
                hub.publish("convert", {"state": "running", "fraction": 0, "out": out})
                m = rec.convert(Path(out), body.get("overwrite", False),
                                lambda f: hub.publish("convert", {"state": "running", "fraction": f, "out": out}))
                hub.log(f"Converted to {out} ({m['events']:,} events)", "ok", "data")
                hub.publish("convert", {"state": "done", "out": out, "manifest": m})
            except Exception as e:  # noqa: BLE001
                hub.log(f"Conversion failed: {e}", "err", "data")
                hub.publish("convert", {"state": "error", "error": str(e)})
        if Path(out).expanduser().exists() and not body.get("overwrite"):
            raise ApiError(f"{out} exists (tick Overwrite to replace it)", 409)
        threading.Thread(target=work, daemon=True).start()
        return {"out": out}
    if path == "/api/data/use":
        h = Path(body["hdf5"]).expanduser()
        if pipeline.running:
            raise ApiError("A pipeline run is in progress; stop it first", 409)
        if h.suffix.lower() not in (".hdf5", ".h5") or not h.is_file():
            raise ApiError("Choose an HDF5 file (convert the AEDAT4 first)")
        config_model.set_override("data.hdf5_dir", "'" + str(h.parent).replace("'", "''") + "/'")
        config_model.set_override("data.hdf5_file", "'" + h.name.replace("'", "''") + "'")
        if body.get("start") is not None:
            config_model.set_override("data.start_time_s", repr(float(body["start"])))
        if body.get("end") is not None:
            config_model.set_override("data.end_time_s", repr(float(body["end"])))
        hub.log(f"Pipeline input: {h.name} [{body.get('start')}, {body.get('end')}] s", "ok", "pipeline")
        return after_override("data.hdf5_file")

    # Live
    if path == "/api/live/discover":
        return discover()
    if path == "/api/live/status":
        return live.status()
    if path == "/api/live/camera":
        return live.start_camera(body.get("serial"))
    if path == "/api/live/remote":
        return live.start_remote(body.get("serial"), body.get("replay"))   # replay: a recording on the remote computer
    if path == "/api/settings/remote" and method == "GET":
        return settings.get("remote")
    if path == "/api/settings/remote":
        return settings.put("remote", body)
    if path == "/api/live/remote/test":
        from .remote import test
        return test(settings.get("remote"))
    if path == "/api/live/replay":
        return live.start_replay(body.get("speed", 1.0), body.get("t_start", 0.0), body.get("loop", True))
    if path == "/api/live/stop":
        return live.stop()
    if path == "/api/live/frame":
        cam = active_cam() if q1(qs, "undistort", "0", bool) else None
        data, n = live.frame(q1(qs, "window", "33", float), q1(qs, "mode", "polarity"), q1(qs, "tau", "30", float), cam)
        st = live.status()
        return ("bin", data, {"X-W": live.w, "X-H": live.h, "X-Count": n, "X-Rate": st["rate_ev_s"],
                              "X-Total": st["total"]})
    if path == "/api/live/cloud":
        return live.cloud(q1(qs, "window", "500", float))
    if path == "/api/live/control":
        return live.set_control(body["key"], body["value"])
    if path == "/api/live/record":
        return live.start_record(body.get("folder")) if body.get("on") else live.stop_record()

    # Journal
    if path == "/api/journal" and method == "GET":
        return {"entries": journal.entries()}
    if path == "/api/journal":
        return journal.add(body.get("text", ""))
    if path == "/api/journal/delete":
        return journal.delete(body["id"])
    if path == "/api/journal/export":
        return journal.export_md()

    # Camera intrinsics
    if path == "/api/calib":
        name, overridden = calibration.active_file()
        return {"files": calibration.files(), "active": name, "overridden": overridden}
    if path == "/api/calib/file":
        return calibration.read(q1(qs, "name"))
    if path == "/api/calib/save":
        res = calibration.write(body["name"], body.get("values", {}), body.get("save_as"))
        hub.log(f"Saved intrinsics to {res['saved']}", "ok", "camera")
        if res["saved"] == calibration.active_file()[0]:
            pipeline.mark_stale_from(2, "camera intrinsics changed")
        return res
    if path == "/api/calib/use":
        name = body["name"]
        calibration.read(name)
        cfg_name = next((p["expr"] for p in config_model.parse()["params"] if p["path"] == "camera.calibration_xml"), "")
        if "".join(__import__("re").findall(r"'([^']*)'", cfg_name)) == name:
            config_model.set_override("camera.calibration_xml", None)
        else:
            config_model.set_override("camera.calibration_xml", f"'{name}'")
        return after_override("camera.calibration_xml")

    # Build
    if path == "/api/build":
        return build.status(q1(qs, "package", "deployable"))
    if path == "/api/build/generate":
        return build.generate(body.get("package", "deployable"), body.get("overrides", True))
    if path == "/api/build/compile":
        return build.compile_(body.get("package", "deployable"))
    if path == "/api/build/run":
        return build.runner.start(body.get("package", "deployable"), body["hdf5"], body.get("start", 60),
                                  body.get("end", 185), body.get("out"))
    if path == "/api/build/stop":
        return build.runner.stop()
    if path == "/api/build/cloud":
        out = Path(q1(qs, "out")).expanduser()
        ply = out / "cloud_m.ply"
        if not ply.is_file():
            raise ApiError("No cloud_m.ply in that folder yet", 404)
        return build.read_ply(ply)
    raise ApiError(f"Unknown endpoint {method} {path}", 404)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "EventStudio/1"

    def log_message(self, *a):
        pass

    def _send(self, status, body: bytes, ctype, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, str(v))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, obj):
        self._send(status, json.dumps(obj, default=str).encode(), "application/json")

    def _handle(self, method):
        url = urlparse(self.path)
        if url.path == "/api/stream":
            return self._stream()
        if not url.path.startswith("/api/"):
            return self._static(url.path)
        body = {}
        if method == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                return self._json(400, {"error": "Invalid JSON"})
        try:
            res = route(method, url.path, parse_qs(url.query), body)
            if isinstance(res, tuple) and res and res[0] == "bin":
                return self._send(200, res[1], "application/octet-stream", res[2])
            self._json(200, res if res is not None else {})
        except ApiError as e:
            self._json(e.status, {"error": str(e), **e.details})
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            self._json(500, {"error": f"{type(e).__name__}: {e}"})

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def _static(self, path):
        if path in ("/", "/index.html"):
            path = "/index.html"
        f = (STATIC_DIR / path.lstrip("/")).resolve()
        if not f.is_relative_to(STATIC_DIR) or not f.is_file():
            return self._send(404, b"Not found", "text/plain")
        self._send(200, f.read_bytes(), TYPES.get(f.suffix, "application/octet-stream"))

    def _stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        q = hub.subscribe()
        try:
            self.wfile.write(b": hello\n\n")
            self.wfile.flush()
            while True:
                try:
                    msg = q.get(timeout=15)
                    self.wfile.write(f"data: {msg}\n\n".encode())
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            hub.unsubscribe(q)
            self.close_connection = True


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    ap = argparse.ArgumentParser(description="Event Studio")
    ap.add_argument("--root", default=str(common.STUDIO_DIR.parent))
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--worker-port", type=int, default=0)
    ap.add_argument("--ready-file")
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--matlab", action="store_true", help="start a headless MATLAB and connect it")
    a = ap.parse_args()
    common.PROJECT["root"] = Path(a.root).resolve()
    if not (root() / "main.m").is_file():
        sys.exit(f"{root()} has no main.m")
    try:
        httpd = Server(("127.0.0.1", a.port), Handler)
    except OSError:
        httpd = Server(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]
    matlab.listen(a.worker_port)
    url = f"http://127.0.0.1:{port}/"
    info = {"port": port, "worker_port": matlab.port, "token": matlab.token, "pid": os.getpid(), "url": url,
            "root": str(root()), "started": time.time()}
    write_json(cache() / "studio.json", info)
    if a.ready_file:
        write_json(Path(a.ready_file), info)
    print(f"Event Studio on {url} (MATLAB worker port {matlab.port})", flush=True)
    hub.log(f"Event Studio started for {root()}", "ok")
    if a.matlab:
        matlab.start_headless()
    if not a.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        live.stop()
        matlab.stop_headless()
