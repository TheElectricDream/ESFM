"""The pipeline's .m files: listing, reading, saving with history, symbols.

Editable: main.m, config.m, the production packages (+adjust, +geom, ...)
and tests/. The generated deployable package is listed read-only. Saving
backs the old file up to .studio_cache/history and refuses to overwrite a
file that changed on disk since it was opened (someone saved it in MATLAB).
"""
import re
import threading
from pathlib import Path

from .common import ApiError, backup, root, safe_path

EXCLUDE_PKGS = {"spot", "studio"}
GENERATED_PKGS = {"deployable", "compile"}
REF_RE = re.compile(r"(?<![\w.])([a-z]\w*)\.([A-Za-z]\w*)\s*(?=\()")
FUNC_RE = re.compile(r"^\s*function\s+(?:(\[[^\]]*\]|[A-Za-z]\w*)\s*=\s*)?([A-Za-z]\w*)\s*(\([^)]*\))?", re.M)
_lock = threading.Lock()
_cache = {"key": None, "index": None}


def packages():
    return sorted(p.name[1:] for p in root().glob("+*") if p.is_dir() and p.name[1:] not in EXCLUDE_PKGS)


def _help_block(lines, start):
    out = []
    for ln in lines[start:start + 80]:
        s = ln.strip()
        if s.startswith("%"):
            out.append(s[1:].rstrip()[1:] if s[1:2] == " " else s[1:].rstrip())
        elif out or s:
            break
    while out and not out[-1].strip():
        out.pop()
    return out


def _describe(path: Path, rel: str, pkg: str | None):
    text = path.read_text(errors="replace")
    lines = text.split("\n")
    m = FUNC_RE.search(text)
    kind = "script"
    sig, help_lines = "", []
    if text.lstrip().startswith("classdef"):
        kind = "class"
    elif m and not text[:m.start()].strip().replace("%", "").strip():
        kind = "function"
        line_no = text[:m.start()].count("\n")
        sig = lines[line_no].strip()
        help_lines = _help_block(lines, line_no + 1)
    elif m:
        # comments before the declaration: still a function file
        kind = "function"
        line_no = text[:m.start()].count("\n")
        sig = lines[line_no].strip()
        help_lines = _help_block(lines, line_no + 1)
    if kind == "script":
        help_lines = _help_block(lines, 0)
    name = path.stem
    full = f"{pkg}.{name}" if pkg else name
    h1 = next((h.strip() for h in help_lines if h.strip()), "")
    refs = sorted({f"{a}.{b}" for a, b in REF_RE.findall(text)})
    cfg_sections = sorted(set(re.findall(r"\bcfg\.([A-Za-z]\w*)", text)))
    return {"path": rel, "name": name, "full": full, "pkg": pkg, "kind": kind, "signature": sig,
            "h1": h1, "help": "\n".join(help_lines[:60]), "refs": refs, "cfg_sections": cfg_sections,
            "readonly": pkg in GENERATED_PKGS or (pkg or "").split(".")[0] in GENERATED_PKGS,
            "lines": len(lines), "mtime": path.stat().st_mtime_ns}


def _files():
    r = root()
    out = []
    for f in ("main.m", "config.m"):
        if (r / f).is_file():
            out.append((r / f, f, None))
    for pkg in packages():
        for f in sorted((r / f"+{pkg}").rglob("*.m")):
            parts = [p[1:] for p in f.relative_to(r).parts[:-1]]
            out.append((f, str(f.relative_to(r)), ".".join(parts)))
    if (r / "tests").is_dir():
        for f in sorted((r / "tests").glob("*.m")):
            out.append((f, str(f.relative_to(r)), None))
    return out


def index():
    files = _files()
    key = tuple((rel, f.stat().st_mtime_ns) for f, rel, _ in files)
    with _lock:
        if _cache["key"] == key:
            return _cache["index"]
        idx = [_describe(f, rel, pkg) for f, rel, pkg in files]
        _cache.update(key=key, index=idx)
        return idx


def by_full_name():
    return {e["full"]: e for e in index() if e["kind"] in ("function", "class")}


def read(rel: str):
    p = safe_path(rel)
    e = next((x for x in index() if x["path"] == rel), None)
    return {"path": rel, "text": p.read_text(errors="replace"), "mtime": p.stat().st_mtime_ns,
            "readonly": bool(e and e["readonly"]), "entry": e}


def write(rel: str, text: str, base_mtime: int | None, force=False):
    p = safe_path(rel, must_exist=False)
    e = next((x for x in index() if x["path"] == rel), None)
    if e and e["readonly"]:
        raise ApiError("This file is generated; edit the production file and regenerate (Build page)")
    if p.is_file() and base_mtime and not force and p.stat().st_mtime_ns != int(base_mtime):
        raise ApiError("The file changed on disk since you opened it", 409, conflict=True)
    if not p.parent.is_dir():
        raise ApiError("Folder does not exist")
    bk = backup(p)
    p.write_text(text)
    return {"path": rel, "mtime": p.stat().st_mtime_ns, "backup": str(bk.relative_to(root())) if bk else None}


def callers(full: str):
    pat = re.compile(r"(?<![\w.])" + re.escape(full) + r"\b")
    out = []
    for f, rel, _ in _files():
        for i, ln in enumerate(f.read_text(errors="replace").split("\n"), 1):
            code = ln.split("%", 1)[0]
            if pat.search(code):
                out.append({"path": rel, "line": i, "text": ln.strip()[:160]})
    return out


def closure_sections(names):
    """cfg sections read by these functions and everything they call."""
    funcs = by_full_name()
    seen, stack, sections = set(), list(names), set()
    while stack:
        n = stack.pop()
        if n in seen or n not in funcs:
            continue
        seen.add(n)
        sections.update(funcs[n]["cfg_sections"])
        stack.extend(funcs[n]["refs"])
    return sections, seen


def symbols():
    """Completion and hover data for the editor."""
    out = []
    for e in index():
        if e["kind"] in ("function", "class") and e["pkg"] and not e["readonly"]:
            out.append({"text": e["full"], "kind": "function", "sig": e["signature"], "h1": e["h1"],
                        "help": e["help"], "path": e["path"]})
    return out
