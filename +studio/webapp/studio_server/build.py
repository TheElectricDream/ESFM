"""The deployable package: generate it from production, compile it, test it.

Generate runs diagnostics/make_deployable.py (optionally baking in the
current parameter overrides); Compile asks MATLAB to run
<package>.build_standalone (MATLAB Compiler); Test runs the executable on a
recording through run_posefromevents.sh and shows its cloud.
"""
import json
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

from . import config_model
from .common import ApiError, cache, find_matlab, read_json, root
from .hub import hub
from .matlab_link import matlab

SRC_PKGS = ["io", "geom", "surface", "track", "warm", "traj", "adjust", "prog"]


def _pkg(name):
    if not re.fullmatch(r"[A-Za-z]\w*", name or ""):
        raise ApiError("Invalid package name")
    if name in SRC_PKGS + ["studio", "spot", "viz"]:
        raise ApiError("That name is taken by a production package")
    return name


def _newest_source():
    r = root()
    files = [r / "main.m", r / "config.m"] + [f for p in SRC_PKGS for f in (r / f"+{p}").glob("*.m")]
    newest = max(files, key=lambda f: f.stat().st_mtime)
    return newest.stat().st_mtime, str(newest.relative_to(r))


def status(package="deployable"):
    package = _pkg(package)
    r = root()
    gen = read_json(r / f"+{package}" / "generated.json", None)
    gen_t = (r / f"+{package}" / "generated.json").stat().st_mtime if gen else None
    newest_t, newest_f = _newest_source()
    exe = r / f"build_{package}" / "standalone" / "posefromevents"
    exe_t = exe.stat().st_mtime if exe.is_file() else None
    ov = config_model.overrides()
    return {
        "package": package,
        "generated": gen, "generated_at": gen_t,
        "up_to_date": bool(gen_t and gen_t >= newest_t),
        "newest_source": newest_f, "newest_source_at": newest_t,
        "overrides_now": ov,
        "overrides_differ": bool(gen) and gen.get("overrides", {}) != ov,
        "exe": str(exe.relative_to(r)) if exe_t else None, "exe_at": exe_t,
        "exe_size_kb": round(exe.stat().st_size / 1024) if exe_t else None,
        "exe_up_to_date": bool(exe_t and gen_t and exe_t >= gen_t),
        "run": runner.status(),
        "matlab_root": _matlab_root(),
    }


def _matlab_root():
    info = matlab.info or {}
    if info.get("matlabroot"):
        return info["matlabroot"]
    exe = find_matlab()
    return str(Path(exe).resolve().parent.parent) if exe else None


def generate(package="deployable", include_overrides=True):
    package = _pkg(package)
    cmd = [sys.executable, str(root() / "diagnostics" / "make_deployable.py"), "--package", package]
    ov = config_model.overrides()
    if include_overrides and ov:
        f = cache() / "build_overrides.json"
        f.write_text(json.dumps(ov))
        cmd += ["--overrides", str(f)]
    p = subprocess.run(cmd, cwd=root(), capture_output=True, text=True, timeout=120)
    out = (p.stdout + p.stderr).strip()
    hub.log(out or "(no output)", "ok" if p.returncode == 0 else "err", "build")
    if p.returncode:
        raise ApiError(out or "make_deployable.py failed", 422)
    if matlab.state == "idle":
        try:
            matlab.request("rehash", {}, label="rehash", timeout=30)
        except ApiError:
            pass
    return {"output": out, "status": status(package)}


def compile_(package="deployable"):
    package = _pkg(package)
    if not (root() / f"+{package}" / "build_standalone.m").is_file():
        raise ApiError("Generate the package first")
    hub.log(f"Compiling {package} with MATLAB Compiler…", "cmd", "build")
    t0 = time.time()
    res = matlab.request("build.standalone", {"package": package}, label="Compile standalone",
                         log_file=cache() / "build_compile.log", run_id="compile")
    hub.log(f"Compiled in {time.time() - t0:.0f} s", "ok", "build")
    return {"result": res, "status": status(package)}


class Runner:
    def __init__(self):
        self.proc = None
        self.info = None

    def status(self):
        st = dict(self.info or {})
        if self.proc is not None:
            st["running"] = self.proc.poll() is None
        return st or None

    def start(self, package, hdf5, start_s, end_s, out_dir):
        package = _pkg(package)
        if self.proc is not None and self.proc.poll() is None:
            raise ApiError("A test run is in progress", 409)
        r = root()
        script = r / f"build_{package}" / "standalone" / "run_posefromevents.sh"
        if not script.is_file():
            raise ApiError("Compile the standalone first")
        if not Path(hdf5).is_file():
            raise ApiError(f"No such recording: {hdf5}")
        mroot = _matlab_root()
        if not mroot:
            raise ApiError("No MATLAB or MATLAB Runtime found to run it with")
        out = Path(out_dir).expanduser() if out_dir else r / ".studio_cache" / "standalone_test"
        out.mkdir(parents=True, exist_ok=True)
        cmd = [str(script), mroot, str(hdf5), str(out), str(start_s), str(end_s)]
        self.info = {"cmd": " ".join(cmd), "out": str(out), "started": time.time(), "lines": [], "summary": {},
                     "running": True}
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                     cwd=str(r), start_new_session=True)
        threading.Thread(target=self._pump, daemon=True).start()
        hub.log(f"Running the standalone on {Path(hdf5).name} [{start_s}, {end_s}] s", "cmd", "build")
        return self.status()

    def _pump(self):
        for line in self.proc.stdout:
            line = line.rstrip("\n")
            self.info["lines"].append(line)
            self.info["lines"] = self.info["lines"][-400:]
            hub.publish("build-output", {"text": line + "\n"})
            m = re.match(r"^(.*?): ([\d.]+) \[sec\]", line)
            if m:
                self.info["summary"].setdefault("stages", []).append([m.group(1), float(m.group(2))])
            for key, pat in (("final", r"^Final: (.*)"), ("spin", r"^Mean spin (.*)"), ("total", r"^Total: ([\d.]+)")):
                mm = re.match(pat, line)
                if mm:
                    self.info["summary"][key] = mm.group(1)
        code = self.proc.wait()
        self.info.update(running=False, code=code, finished=time.time())
        hub.log(f"Standalone finished with code {code}", "ok" if code == 0 else "err", "build")
        hub.publish("build", {"run": self.status()})

    def stop(self):
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
        return self.status()


def read_ply(path: Path, n_max=200000):
    import base64
    import numpy as np
    with open(path, "rb") as f:
        header = []
        while True:
            ln = f.readline().decode(errors="replace").strip()
            header.append(ln)
            if ln == "end_header" or not ln:
                break
        if "format ascii 1.0" not in header:
            raise ApiError("Only ASCII PLY")
        n = int(next(h.split()[-1] for h in header if h.startswith("element vertex")))
        xyz = np.loadtxt(f, max_rows=n, usecols=(0, 1, 2), ndmin=2).astype(np.float32)
    if len(xyz) > n_max:
        xyz = xyz[np.random.default_rng(0).choice(len(xyz), n_max, replace=False)]
    from . import render
    z = xyz[:, 2]
    rgb = render.colormap((z - z.min()) / max(np.ptp(z), 1e-9), "viridis")
    return {"kind": "points", "n": int(len(xyz)), "xyz": base64.b64encode(xyz.tobytes()).decode(),
            "rgb": base64.b64encode(rgb.tobytes()).decode(), "axes": ["x [m]", "y [m]", "z [m]"], "space": "metric"}


runner = Runner()
