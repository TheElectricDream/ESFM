#!/usr/bin/env python3
"""Set up (or check) the Python environment Event Studio runs in.

Standard library only, so it runs on any Python 3.10+. It creates a virtual
environment for this machine and this Python (outside the project, so a
copied or synced project folder never carries a broken one), installs the
packages in requirements.txt that are missing, and checks they import. A
second run only checks (about a second). Every stage is printed as it
happens.

    python3 setup_env.py                 # set up / check
    python3 setup_env.py --force         # rebuild from scratch
    python3 setup_env.py --report f.json # also write the result for MATLAB

Where: $STUDIO_VENV_DIR if set, else <cache>/event-studio/venvs/<key>, with
<cache> = $XDG_CACHE_HOME or ~/.cache (Linux, macOS) or %LOCALAPPDATA%
(Windows) and <key> naming the Python version, platform and interpreter.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REQ_FILE = HERE / "requirements.txt"   # --requirements overrides
MIN_PY = (3, 10)
IMPORT_NAME = {"numpy": "numpy", "h5py": "h5py", "dv-processing": "dv_processing", "paramiko": "paramiko"}


def say(msg):
    print(f"[Event Studio] {msg}", flush=True)


def requirements():
    out = []
    for raw in REQ_FILE.read_text().splitlines():
        line, _, comment = raw.partition("#")
        spec = line.strip()
        if not spec:
            continue
        name = spec.split(">")[0].split("=")[0].split("<")[0].strip()
        out.append({"spec": spec, "name": name, "module": IMPORT_NAME.get(name, name.replace("-", "_")),
                    "optional": "optional" in comment})
    return out


def distro():
    try:
        for line in open("/etc/os-release"):
            if line.startswith("ID="):
                return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return platform.system().lower()


def venv_dir():
    if os.environ.get("STUDIO_VENV_DIR"):
        return Path(os.environ["STUDIO_VENV_DIR"]).expanduser()
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    else:
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    ident = f"{os.path.realpath(sys.executable)}|{sys.version}|{platform.machine()}|{distro()}"
    key = (f"py{sys.version_info.major}{sys.version_info.minor}-{platform.machine()}-{distro()}-"
           + hashlib.sha1(ident.encode()).hexdigest()[:8])
    return base / "event-studio" / "venvs" / key


def venv_python(d: Path):
    return d / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def run(cmd, prefix="    "):
    """Run a command, echoing its output line by line; return the exit code."""
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                         env={**os.environ, "PIP_DISABLE_PIP_VERSION_CHECK": "1", "PYTHONNOUSERSITE": "1"})
    for line in p.stdout:
        line = line.rstrip()
        if line:
            print(prefix + line, flush=True)
    return p.wait()


def importable(py, module):
    r = subprocess.run([str(py), "-c", f"import {module}"], capture_output=True, text=True,
                       env={**os.environ, "PYTHONNOUSERSITE": "1"})
    return r.returncode == 0, (r.stderr.strip().splitlines() or [""])[-1]


def create(d: Path):
    say(f"Creating a Python environment for this machine in {d}")
    say("(once per machine and Python version; it takes a few seconds)")
    d.parent.mkdir(parents=True, exist_ok=True)
    import venv
    # system site-packages stay visible, so packages the system already
    # provides (e.g. a dv_processing from iniVation's repository) are reused
    if has_ensurepip():
        try:
            venv.EnvBuilder(with_pip=True, system_site_packages=True, clear=True).create(d)
            return
        except BaseException as e:  # noqa: BLE001 - some distributions exit instead of raising
            say(f"The standard venv module could not install pip ({e or 'exit'}); bootstrapping pip instead")
    else:
        say("This Python has no ensurepip (Debian / Ubuntu / Jetson without python3-venv); bootstrapping pip instead")
    try:
        venv.EnvBuilder(with_pip=False, system_site_packages=True, clear=True).create(d)
    except BaseException as e:  # noqa: BLE001
        fail_venv(f"even without pip the environment could not be created ({e})")
    bootstrap_pip(venv_python(d))


def has_ensurepip():
    return subprocess.run([sys.executable, "-c", "import ensurepip"], capture_output=True).returncode == 0


GET_PIP = "https://bootstrap.pypa.io/get-pip.py"


def bootstrap_pip(py: Path):
    import tempfile
    import urllib.request
    say(f"Downloading pip's installer ({GET_PIP})")
    tmp = Path(tempfile.gettempdir()) / f"event_studio_get_pip_{os.getpid()}.py"
    try:
        with urllib.request.urlopen(GET_PIP, timeout=60) as r:
            tmp.write_bytes(r.read())
    except OSError as e:
        fail_venv(f"pip's installer could not be downloaded ({e}); check the internet connection")
    say("Installing pip into the environment")
    code = run([str(py), str(tmp), "--no-warn-script-location", "--disable-pip-version-check"])
    tmp.unlink(missing_ok=True)
    if code or not importable(py, "pip")[0]:
        fail_venv("pip could not be installed into the environment")


def fail_venv(why):
    hint = {"ubuntu": "sudo apt install python3-venv python3-pip", "debian": "sudo apt install python3-venv python3-pip",
            "fedora": "sudo dnf install python3-pip", "rhel": "sudo dnf install python3-pip",
            "arch": "sudo pacman -S python-pip"}.get(distro(), "install pip and venv support for this Python")
    raise SystemExit(f"[Event Studio] Could not create a Python environment: {why}. "
                     f"If that keeps failing, install the venv support for {sys.executable} ({hint}) and start again.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--report")
    ap.add_argument("--requirements", help="another requirements file (the remote camera agent uses its own)")
    ap.add_argument("--min-python", default="3.10", help="oldest Python accepted (the remote agent runs on 3.8)")
    a = ap.parse_args()
    global REQ_FILE
    if a.requirements:
        REQ_FILE = Path(a.requirements).expanduser().resolve()
    t0 = time.time()
    min_py = tuple(int(x) for x in a.min_python.split("."))
    if sys.version_info < min_py:
        raise SystemExit(f"[Event Studio] Python {platform.python_version()} at {sys.executable} is too old; "
                         f"Event Studio needs {a.min_python} or newer (set STUDIO_PYTHON to another one).")
    reqs = requirements()
    d = venv_dir()
    py = venv_python(d)
    marker = d / ".studio_requirements.json"
    wanted = {"requirements": REQ_FILE.read_text(), "python": sys.version}
    if a.force and d.exists():
        say(f"Rebuilding {d}")
        shutil.rmtree(d)
    if not py.exists():
        create(d)
    else:
        say(f"Checking the Python environment ({d})")

    missing_opt = []
    for i, r in enumerate(reqs, 1):
        ok, err = importable(py, r["module"])
        if ok:
            continue
        say(f"Installing {r['name']} ({i}/{len(reqs)}){' (optional)' if r['optional'] else ''}…")
        code = run([str(py), "-m", "pip", "install", "--no-input", "--progress-bar", "off", r["spec"]])
        ok, err = importable(py, r["module"])
        if not ok:
            if r["optional"]:
                missing_opt.append(r["name"])
                say(f"{r['name']} could not be installed ({err or f'pip exit {code}'}); the Studio still runs, "
                    "but AEDAT4 files and the live camera are unavailable until it is.")
                continue
            raise SystemExit(f"[Event Studio] {r['name']} could not be installed: {err or f'pip exit {code}'}. "
                             "Check the internet connection (pip needs PyPI) and start again.")
        say(f"{r['name']} ready")

    versions = subprocess.run([str(py), "-c", "import importlib.metadata as m, json; print(json.dumps({n: m.version(n) "
                               f"for n in {[r['name'] for r in reqs if r['name'] not in missing_opt]!r}}}))"],
                              capture_output=True, text=True, env={**os.environ, "PYTHONNOUSERSITE": "1"}).stdout.strip()
    marker.write_text(json.dumps({**wanted, "optional_missing": missing_opt}, indent=2))
    try:
        v = json.loads(versions)
    except ValueError:
        v = {}
    say(f"Python environment ready in {time.time() - t0:.1f} s: Python {platform.python_version()}, "
        + ", ".join(f"{k} {x}" for k, x in v.items()))
    report = {"python": str(py), "venv": str(d), "optional_missing": missing_opt, "versions": v}
    if a.report:
        Path(a.report).write_text(json.dumps(report, indent=2))
    return report


if __name__ == "__main__":
    main()
