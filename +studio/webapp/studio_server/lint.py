"""Live code checks for the editor.

Studio checks (Python, instant, no MATLAB needed):
  - pkg.fn calls into the pipeline's packages that name no function there
  - cfg.<section>.<field> reads of fields config.m does not define
  - names used but never assigned in the file (candidates; MATLAB decides)
MATLAB checks (when MATLAB is free): the Code Analyzer on the unsaved text
(a temporary copy), and which of the candidate names exist nowhere on the
path, i.e. "Unrecognized function or variable", the classic typo MATLAB
itself only reports at run time.
"""
import difflib
import re

from . import code_index, config_model
from .common import cache

KEYWORDS = set("break case catch classdef continue else elseif end for function global if otherwise parfor "
               "persistent return spmd switch try while methods properties events enumeration arguments".split())
ALWAYS = set("ans nargin nargout varargin varargout true false pi eps inf Inf nan NaN i j end".split())
COMMANDS = set("clear clc close hold format diary axis grid warning more echo disp load save cd mkdir rehash "
               "drawnow figure clf colorbar colormap shading rotate3d profile pause keyboard dbstop dbclear syms".split())
_exists_cache = {}          # name -> True / False (MATLAB's verdict)


def forget_cache():
    _exists_cache.clear()


def tokenize(text):
    """MATLAB tokens (kind, value, line, col) without comments and strings, plus statement ends."""
    toks, line, col, i, depth = [], 1, 1, 0, 0
    stack = []               # open brackets; a '(' cannot span lines without '...'
    n = len(text)
    prev_sig = None          # last significant token kind for the transpose rule
    at_line_start = True
    in_block = False
    while i < n:
        c = text[i]
        if at_line_start:
            m = re.match(r"[ \t]*%([{}])[ \t]*(\n|$)", text[i:])
            if m:
                in_block = m.group(1) == "{"
                j = i + m.end()
                line += 1
                col = 1
                i = j
                continue
            if in_block:
                j = text.find("\n", i)
                j = n if j < 0 else j + 1
                line += 1
                col = 1
                i = j
                continue
        at_line_start = False
        if c == "\n":
            if "(" in stack:          # an unclosed '(' (a typo): the statement still ends here
                stack.clear()
                depth = 0
            if depth == 0:
                toks.append(("end_stmt", "\n", line, col))
            line += 1
            col = 1
            i += 1
            at_line_start = True
            prev_sig = None if depth == 0 else prev_sig
            continue
        if c in " \t\r":
            i += 1
            col += 1
            continue
        if c == "%" or (c == "!" and prev_sig is None):
            j = text.find("\n", i)
            j = n if j < 0 else j
            col += j - i
            i = j
            continue
        if text.startswith("...", i):
            j = text.find("\n", i)
            j = n if j < 0 else j + 1
            line += 1
            col = 1
            i = j
            continue
        if c == "'":
            transpose = prev_sig in ("ident", "num", "close", "quote") and i > 0 and text[i - 1] not in " \t"
            if transpose:
                toks.append(("op", "'", line, col))
                i += 1
                col += 1
                prev_sig = "quote"
                continue
            j = i + 1
            while j < n and text[j] != "\n":
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            toks.append(("str", "", line, col))
            col += j - i + 1
            i = j + 1
            prev_sig = "num"
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            toks.append(("str", "", line, col))
            col += j - i + 1
            i = j + 1
            prev_sig = "num"
            continue
        m = re.match(r"[A-Za-z]\w*", text[i:])
        if m:
            toks.append(("ident", m.group(0), line, col))
            i += m.end()
            col += m.end()
            prev_sig = "ident"
            continue
        m = re.match(r"(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?[ij]?", text[i:])
        if m:
            toks.append(("num", m.group(0), line, col))
            i += m.end()
            col += m.end()
            prev_sig = "num"
            continue
        if c in "([{":
            depth += 1
            stack.append(c)
            toks.append(("open", c, line, col))
            prev_sig = "open"
        elif c in ")]}":
            depth = max(0, depth - 1)
            if stack:
                stack.pop()
            toks.append(("close", c, line, col))
            prev_sig = "close"
        elif c in ";," and depth == 0:
            toks.append(("end_stmt", c, line, col))
            prev_sig = None
        else:
            m = re.match(r"==|~=|<=|>=|&&|\|\||\.\*|\./|\.\^|\.'|.", text[i:])
            v = m.group(0)
            toks.append(("op", v, line, col))
            i += len(v)
            col += len(v)
            prev_sig = "op"
            continue
        i += 1
        col += 1
    toks.append(("end_stmt", "", line, col))
    return toks


def analyse(text):
    toks = tokenize(text)
    stmts, cur = [], []
    for t in toks:
        if t[0] == "end_stmt":
            if cur:
                stmts.append(cur)
            cur = []
        else:
            cur.append(t)
    assigned, local_funcs, uses, pkg_refs, cfg_refs = set(), set(), {}, [], []
    for st in stmts:
        first = st[0]
        # command syntax: "hold on", "close all", "clear x y"
        if (first[0] == "ident" and first[1] not in KEYWORDS and len(st) > 1 and st[1][0] in ("ident", "num")
                and st[1][2] == first[2] and not any(t[1] == "=" for t in st)):
            if first[1] in COMMANDS or st[1][3] > first[3] + len(first[1]):
                uses.setdefault(first[1], (first[2], first[3]))
                continue
        if first[1] == "function":
            names = [t[1] for t in st[1:] if t[0] == "ident"]
            if any(t[1] == "=" for t in st):
                eq = next(k for k, t in enumerate(st) if t[1] == "=")
                assigned.update(t[1] for t in st[1:eq] if t[0] == "ident")
                rest = [t for t in st[eq + 1:] if t[0] == "ident"]
            else:
                rest = [t for t in st[1:] if t[0] == "ident"]
            if rest:
                local_funcs.add(rest[0][1])
                assigned.update(t[1] for t in rest[1:])
            del names
            continue
        if first[1] in ("global", "persistent"):
            assigned.update(t[1] for t in st[1:] if t[0] == "ident")
            continue
        if first[1] in ("for", "parfor") and len(st) > 1 and st[1][0] == "ident":
            assigned.add(st[1][1])
        if first[1] == "catch" and len(st) > 1 and st[1][0] == "ident":
            assigned.add(st[1][1])
            continue
        # assignment at depth 0
        depth, eq = 0, None
        for k, t in enumerate(st):
            if t[0] == "open":
                depth += 1
            elif t[0] == "close":
                depth -= 1
            elif t[1] == "=" and depth == 0:
                eq = k
                break
        if eq is not None and first[1] not in ("for", "parfor", "if", "while", "elseif", "switch", "case"):
            lhs = st[:eq]
            if lhs and lhs[0][1] == "[":
                d = 0
                for k, t in enumerate(lhs):
                    if t[0] == "open":
                        d += 1
                    elif t[0] == "close":
                        d -= 1
                    elif t[0] == "ident" and d == 1 and (k == 0 or lhs[k - 1][1] != "."):
                        assigned.add(t[1])
            elif lhs and lhs[0][0] == "ident":
                assigned.add(lhs[0][1])
                if lhs[0][1] == "cfg":
                    path = _dotted(lhs, 0)
                    if path:
                        cfg_refs.append((path, lhs[0][2], lhs[0][3], True))
        # anonymous function parameters
        for k, t in enumerate(st):
            if t[1] == "@" and k + 1 < len(st) and st[k + 1][1] == "(":
                for u in st[k + 2:]:
                    if u[1] == ")":
                        break
                    if u[0] == "ident":
                        assigned.add(u[1])
        start = eq + 1 if eq is not None else 0
        for k, t in enumerate(st):
            if t[0] != "ident" or t[1] in KEYWORDS:
                continue
            if k > 0 and st[k - 1][1] in (".", ".'"):
                continue
            if k > 0 and st[k - 1][1] == "@" :
                uses.setdefault(t[1], (t[2], t[3]))
                continue
            # pkg.fn( ... )
            if k + 2 < len(st) and st[k + 1][1] == "." and st[k + 2][0] == "ident":
                pkg_refs.append((t[1], st[k + 2][1], t[2], t[3], len(t[1]) + 1 + len(st[k + 2][1])))
                if t[1] == "cfg" and k >= start:
                    path = _dotted(st, k)
                    if path:
                        cfg_refs.append((path, t[2], t[3], False))
            if k < start and eq is not None and st[0][1] != "[":
                continue
            uses.setdefault(t[1], (t[2], t[3]))
    return {"assigned": assigned, "local_funcs": local_funcs, "uses": uses, "pkg_refs": pkg_refs, "cfg_refs": cfg_refs}


def _dotted(st, k):
    parts = []
    j = k + 1
    while j + 1 < len(st) and st[j][1] == "." and st[j + 1][0] == "ident":
        parts.append(st[j + 1][1])
        j += 2
    return ".".join(parts[:2]) if parts else None


def studio_checks(text, rel):
    """Instant checks; returns (messages, candidate unknown names with positions)."""
    msgs = []
    a = analyse(text)
    funcs = code_index.by_full_name()
    pkgs = set(code_index.packages())
    for pkg, fn, line, col, length in a["pkg_refs"]:
        if pkg in pkgs and pkg not in ("deployable",) and f"{pkg}.{fn}" not in funcs:
            names = [f.split(".", 1)[1] for f in funcs if f.startswith(pkg + ".") and f.count(".") == 1]
            sug = difflib.get_close_matches(fn, names, 1, 0.6)
            msgs.append({"line": line, "col": col, "end": col + length, "severity": "error", "source": "studio",
                         "message": f"+{pkg} has no function {fn}" + (f"; did you mean {pkg}.{sug[0]}?" if sug else "")})
    if rel != "config.m":
        model = config_model.parse()
        fields = {}
        for p in model["params"]:
            sec, _, rest = p["path"].partition(".")
            fields.setdefault(sec, set()).add(rest.split(".")[0])
        lhs_paths = {r[0] for r in a["cfg_refs"] if r[3]}
        for path, line, col, is_lhs in a["cfg_refs"]:
            if is_lhs:
                continue
            sec, _, field = path.partition(".")
            if sec not in fields:
                sug = difflib.get_close_matches(sec, list(fields), 1, 0.6)
                msgs.append({"line": line, "col": col, "end": col + 4 + len(sec), "severity": "warning", "source": "studio",
                             "message": f"config.m defines no cfg.{sec}" + (f"; did you mean cfg.{sug[0]}?" if sug else "")})
            elif field and field not in fields[sec] and path not in lhs_paths:
                sug = difflib.get_close_matches(field, list(fields[sec]), 1, 0.6)
                msgs.append({"line": line, "col": col, "end": col + 5 + len(path), "severity": "warning", "source": "studio",
                             "message": f"cfg.{sec} has no field {field} in config.m" + (f"; did you mean cfg.{sec}.{sug[0]}?" if sug else "")})
    skip = KEYWORDS | ALWAYS | pkgs | a["assigned"] | a["local_funcs"] | {"cfg"}
    candidates = {n: pos for n, pos in a["uses"].items() if n not in skip}
    return msgs, candidates


def matlab_severity(m):
    ident = (m.get("id") or "").upper()
    text = m.get("message", "")
    if ident in {"SYNER", "NOPAR", "ENDCT", "ENDCT2", "PARSEERR", "EOFNOEND", "NOEND", "MCHV2", "NODEF"} \
            or text.startswith(("Parse error", "Invalid", "Unbalanced", "A '", "This statement is incomplete")):
        return "error"
    return "warning"


def check(rel, text, matlab):
    msgs, cand = studio_checks(text, rel)
    ran_matlab = False
    if matlab.state == "idle":
        folder = cache() / "lint"
        folder.mkdir(exist_ok=True)
        tmp = folder / rel.split("/")[-1]
        tmp.write_text(text)
        ask = [n for n in cand if n not in _exists_cache]
        try:
            res = matlab.request("lint", {"path": str(tmp), "names": ask}, label="Code check", timeout=30)
            ran_matlab = True
            for n, ok in zip(ask, res.get("exists") or []):
                _exists_cache[n] = bool(ok)
            for m in res.get("messages") or []:
                col = m["col"][0] if isinstance(m.get("col"), list) else (m.get("col") or 1)
                end = m["col"][1] + 1 if isinstance(m.get("col"), list) and len(m["col"]) > 1 else col + 1
                msgs.append({"line": m["line"], "col": col, "end": end, "severity": matlab_severity(m),
                             "source": "matlab", "message": m["message"], "id": m.get("id")})
        except Exception:  # noqa: BLE001 - busy or offline: the Studio checks still stand
            pass
    script = not re.match(r"\s*(%[^\n]*\n\s*)*(function|classdef)\b", text)
    for n, (line, col) in cand.items():
        if _exists_cache.get(n) is False:
            if script:
                msgs.append({"line": line, "col": col, "end": col + len(n), "severity": "warning", "source": "studio",
                             "message": f"'{n}' is defined nowhere in this script and is not a function on MATLAB's path: "
                                        "fine only if it is already in the workspace when the script runs"})
            else:
                msgs.append({"line": line, "col": col, "end": col + len(n), "severity": "error", "source": "studio",
                             "message": f"Unrecognized function or variable '{n}' (not assigned in this function and not on MATLAB's path)"})
    msgs.sort(key=lambda m: (m["line"], m["col"]))
    return {"messages": msgs, "matlab": ran_matlab}
