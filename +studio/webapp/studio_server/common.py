"""Paths, errors and small helpers shared by every module."""
import json
import os
import re
import shutil
import time
from pathlib import Path

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"
STUDIO_DIR = Path(__file__).resolve().parent.parent.parent      # +studio
PROJECT = {"root": STUDIO_DIR.parent}                           # set by server.main


def root() -> Path:
    return PROJECT["root"]


def cache() -> Path:
    p = root() / ".studio_cache"
    p.mkdir(exist_ok=True)
    return p


class ApiError(Exception):
    def __init__(self, message, status=400, **details):
        super().__init__(message)
        self.status = status
        self.details = details


def backup(path: Path) -> Path | None:
    """Copy a file into .studio_cache/history before it is overwritten."""
    if not path.is_file():
        return None
    hist = cache() / "history"
    hist.mkdir(exist_ok=True)
    rel = str(path.relative_to(root())) if path.is_relative_to(root()) else path.name
    dst = hist / f"{time.strftime('%Y%m%d_%H%M%S')}_{rel.replace(os.sep, '__')}"
    shutil.copy2(path, dst)
    return dst


def safe_path(rel: str, must_exist=True, suffixes=(".m",)) -> Path:
    """A project-relative path that stays inside the project."""
    p = (root() / rel).resolve()
    if not p.is_relative_to(root().resolve()):
        raise ApiError("Path outside the project")
    if suffixes and p.suffix not in suffixes:
        raise ApiError(f"Only {', '.join(suffixes)} files")
    if must_exist and not p.is_file():
        raise ApiError(f"No such file: {rel}", 404)
    return p


CFG_PATH = re.compile(r"^[A-Za-z]\w*(\.[A-Za-z]\w*)+$")


def check_cfg_path(path: str) -> str:
    if not CFG_PATH.match(path):
        raise ApiError(f"Invalid parameter path: {path}")
    return path


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write_json(path: Path, data):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(tmp, path)


def find_matlab() -> str | None:
    """The newest MATLAB under ~/Applications/MATLAB, /usr/local/MATLAB or on PATH."""
    env = os.environ.get("STUDIO_MATLAB")
    if env and os.path.isfile(env):
        return env
    cands = []
    for base in (Path.home() / "Applications" / "MATLAB", Path("/usr/local/MATLAB"), Path("/opt/MATLAB")):
        if base.is_dir():
            cands += sorted(base.glob("R20*/bin/matlab"))
    if cands:
        # prefer the release the user runs interactively (R2026a) when present
        for c in cands:
            if "R2026a" in str(c):
                return str(c)
        return str(cands[-1])
    return shutil.which("matlab")


MIN_FREE_GB = float(os.environ.get("STUDIO_MIN_FREE_GB", "4"))


def mem_info():
    """Total and available memory [GB] from /proc/meminfo (Linux)."""
    try:
        m = {}
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1)
            m[k] = int(v.split()[0]) / 1024 / 1024
        return {"total_gb": round(m["MemTotal"], 1), "available_gb": round(m["MemAvailable"], 1),
                "min_free_gb": MIN_FREE_GB}
    except (OSError, KeyError, ValueError):
        return None


def require_memory(what, need_gb=None):
    """Refuse to start something heavy when the machine is short of memory."""
    need = MIN_FREE_GB if need_gb is None else need_gb
    m = mem_info()
    if m and m["available_gb"] < need:
        raise ApiError(f"Only {m['available_gb']:.1f} GB of memory is available; {what} needs at least {need:.0f} GB free. "
                       "Close a MATLAB session or the open recording, or shorten the data window "
                       "(set STUDIO_MIN_FREE_GB to change the limit).", 507)
