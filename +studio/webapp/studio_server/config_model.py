"""config.m as documented parameters, and parameter overrides.

Every `cfg.<section>.<name> = <expr>;  % <comment>` statement of config.m
becomes a parameter. Its comment's tag sets how the Studio shows it:
    FIXED:       validated; collapsed under "Fixed" (still editable)
    DERIVED:     computed from other values; read-only
    EXPERIMENT:  under test; highlighted
    (none)       tunable, unless the value only names a constant or
                 another cfg field ("linked", read-only)
The comment block above a group of statements is kept as its description.
UPPER_CASE constants at the top (MIN_EVENTS = 3; ...) are parameters too.

Overrides never touch config.m until saved: the Studio writes a copy,
.studio_cache/config_studio/studio_config.m, with the overridden right-hand
sides replaced, so values derived from them follow. Saving writes the same
replacement into config.m (backed up first).
"""
import re
from pathlib import Path

from .common import ApiError, backup, cache, check_cfg_path, read_json, root, write_json

CONST_RE = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.+)$")
CFG_RE = re.compile(r"^\s*cfg\.([A-Za-z]\w*(?:\.[A-Za-z]\w*)+)\s*=\s*(.+)$", re.S)
TAG_RE = re.compile(r"^(FIXED|DERIVED|EXPERIMENT|REQUIRED)\b:?\s*", re.I)


def split_comment(line: str):
    """Code and comment of one MATLAB line (a % inside a string is code)."""
    in_str = False
    prev = ""
    for i, ch in enumerate(line):
        if ch == "'":
            if in_str:
                in_str = False
            elif not (prev.isalnum() or prev in ")]}.'_"):
                in_str = True
        elif ch == "%" and not in_str:
            return line[:i].rstrip(), line[i + 1:].strip()
        if not ch.isspace():
            prev = ch
    return line.rstrip(), ""


def config_path() -> Path:
    return root() / "config.m"


def parse(text: str | None = None):
    text = config_path().read_text() if text is None else text
    lines = text.split("\n")
    params, consts, sections = [], [], {}
    doc_block, pending_doc = [], []
    i = 0
    while i < len(lines):
        raw = lines[i]
        stripped = raw.strip()
        if stripped.startswith("%"):
            body = stripped.lstrip("%").strip()
            if body.strip("-% ") and not body.startswith("[studio") and not body.startswith("%"):
                pending_doc.append(body)
            i += 1
            continue
        if not stripped:
            if pending_doc:
                doc_block, pending_doc = pending_doc, []
            i += 1
            continue
        if pending_doc:
            doc_block, pending_doc = pending_doc, []
        # join continuation lines
        start = i
        code, comment = split_comment(raw)
        comments = [comment] if comment else []
        while code.rstrip().endswith("...") and i + 1 < len(lines):
            i += 1
            c2, cm2 = split_comment(lines[i])
            code = code.rstrip()[:-3] + " " + c2.strip()
            if cm2:
                comments.append(cm2)
        end = i
        i += 1
        code = code.strip()
        if not code.endswith(";"):
            continue
        stmt = code[:-1].strip()
        comment = " ".join(comments)
        m = CFG_RE.match(stmt)
        c = CONST_RE.match(stmt) if not m else None
        if not (m or c):
            continue
        tag_m = TAG_RE.match(comment)
        tag = tag_m.group(1).upper() if tag_m else ""
        note = comment[tag_m.end():] if tag_m else comment
        expr = (m or c).group(2).strip()
        entry = {"expr": expr, "comment": note, "line": start + 1, "end_line": end + 1,
                 "multiline": end > start, "doc": " ".join(doc_block)}
        if m:
            path = m.group(1)
            section = path.split(".")[0]
            linked = bool(re.fullmatch(r"[A-Z][A-Z0-9_]*", expr)) or "cfg." in expr
            if tag == "DERIVED" or (not tag and linked):
                kind = "derived" if tag == "DERIVED" else "linked"
            elif tag in ("FIXED", "REQUIRED"):
                kind = "fixed"
            elif tag == "EXPERIMENT":
                kind = "experiment"
            else:
                kind = "tunable"
            entry.update(path=path, section=section, name=path.split(".", 1)[1], kind=kind, tag=tag)
            params.append(entry)
            own = entry["doc"] if entry["doc"].lower().startswith(section + ":") else ""
            sections.setdefault(section, {"name": section, "doc": own, "count": 0})
            sections[section]["count"] += 1
        else:
            entry.update(path=c.group(1), name=c.group(1), section="constants",
                         kind="fixed" if tag in ("FIXED", "REQUIRED") else "tunable", tag=tag)
            consts.append(entry)
    return {"params": params, "constants": consts, "sections": list(sections.values())}


# ---------------- overrides ----------------
def _ovr_file():
    return cache() / "overrides.json"


def overrides() -> dict:
    return read_json(_ovr_file(), {})


def set_override(path: str, expr: str | None):
    ov = overrides()
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", path):
        check_cfg_path("cfg." + path)
    if expr is None or expr == "":
        ov.pop(path, None)
    else:
        if "\n" in expr or ";" in expr.strip().rstrip(";"):
            raise ApiError("One expression only (no ';' or newlines)")
        ov[path] = expr.strip().rstrip(";")
    write_json(_ovr_file(), ov)
    return ov


def clear_overrides():
    write_json(_ovr_file(), {})
    return {}


def _apply(text: str, ov: dict, annotate: bool):
    model = parse(text)
    lines = text.split("\n")
    by_path = {p["path"]: p for p in model["params"]}
    by_path.update({c["path"]: c for c in model["constants"]})
    appended = []
    # replace from the bottom up so earlier line numbers stay valid
    targets = []
    for path, expr in ov.items():
        p = by_path.get(path)
        if p is None or p["multiline"]:
            if re.fullmatch(r"[A-Z][A-Z0-9_]*", path):
                raise ApiError(f"Constant {path} not found in config.m")
            appended.append((path, expr))
        else:
            targets.append((p["line"] - 1, path, expr, p))
    for idx, path, expr, p in sorted(targets, reverse=True):
        code, comment = split_comment(lines[idx])
        indent = re.match(r"^\s*", lines[idx]).group(0)
        lhs = f"cfg.{path}" if not re.fullmatch(r"[A-Z][A-Z0-9_]*", path) else path
        pad = code.split("=", 1)[0].rstrip()
        lhs_txt = pad if pad.strip() == lhs else indent + lhs
        new = f"{lhs_txt} = {expr};"
        if annotate:
            new += f"  % [studio override] was: {p['expr']}"
        elif comment:
            new += f"  % {comment}"
        lines[idx] = new
    text = "\n".join(lines)
    if appended:
        end = text.rstrip().rfind("end")
        block = "\n".join(f"    cfg.{p} = {e};  % [studio override]" for p, e in appended)
        text = text[:end] + block + "\n" + text[end:]
    return text


def write_studio_config(ov: dict | None = None) -> Path:
    """The overridden copy of config.m as function studio_config; returns its folder."""
    ov = overrides() if ov is None else ov
    src = config_path().read_text()
    text = _apply(src, ov, annotate=True)
    text, n = re.subn(r"^function\s+cfg\s*=\s*config\s*\(\s*\)", "function cfg = studio_config()", text, count=1, flags=re.M)
    if n != 1:
        raise ApiError("config.m must start with 'function cfg = config()'")
    folder = cache() / "config_studio"
    folder.mkdir(exist_ok=True)
    (folder / "studio_config.m").write_text(
        "% GENERATED by Event Studio from config.m and .studio_cache/overrides.json; do not edit.\n" + text)
    return folder


def save_to_config(paths: list[str] | None = None):
    """Write overrides (all, or the listed paths) into config.m and drop them."""
    ov = overrides()
    chosen = {k: v for k, v in ov.items() if paths is None or k in paths}
    if not chosen:
        raise ApiError("No overrides to save")
    src = config_path().read_text()
    model = parse(src)
    multi = {p["path"] for p in model["params"] if p["multiline"]}
    if any(k in multi for k in chosen):
        raise ApiError("A multi-line statement cannot be saved automatically; edit config.m in the Code page")
    new = _apply(src, chosen, annotate=False)
    bk = backup(config_path())
    config_path().write_text(new)
    for k in chosen:
        ov.pop(k)
    write_json(_ovr_file(), ov)
    return {"saved": sorted(chosen), "backup": str(bk.relative_to(root())) if bk else None, "overrides": ov}
