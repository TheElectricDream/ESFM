"""The project journal: dated notes and activity, kept in <project>/journal.jsonl.

Two kinds of entries: notes you write (the Journal page is a chat box) and
automatic activity the Studio records as you work (steps run, parameters
changed, files saved, recordings converted, builds). The page groups
consecutive activity into one summary. Export writes JOURNAL.md.
"""
import json
import re
import threading
import time
import uuid
from datetime import datetime

from .common import ApiError, root
from .hub import hub

_lock = threading.Lock()
AUTO_SOURCES = {"pipeline", "code", "data", "build", "live", "camera", "remote"}
SKIP = re.compile(r"^(Waiting|Copying|Connecting|Checking|Installing|Collecting|Downloading|Using cached|Successfully|Requirement)")

SEED = [
    ("2026-10-08T20:00:00", "Python prototype (sparse junction features, SE(3) bootstrap, 12-state EKF): no blind reconstruction after five stages. "
     "Session 1 event-by-event estimator: the tracker holds 1.1° on a correct map, but joint map and pose slide along the bas-relief valley."),
    ("2026-10-09 23:30:00", "New 2-D tracker (Kalman, normal-flow velocity, signed direction gate): 76-82 % of tracks stay on one rigid edge (was 47-57 %). "
     "Rate-scale revolution closure with a rate hold: ROT-NOM 0.67°, CIRC-TR-NOM 4.8°. Identity drift measured as the root problem."),
    ("2026-10-10 12:20:00", "Hypotheses H1 (model-guided candidates: real tracker gain, neutral in the loop) and H2 (glare makes phantom landmarks). "
     "Blind generalisation: ROT-DARK, ROT-SG and CIRC-TR-DARK hold; CIRC-TR-SG fails at initialisation."),
    ("2026-10-10 20:08:00", "Reframed to cloud first. Production restructured as the offline cloud pipeline: 693 landmarks, 13.8 / 31.2 mm to and from the CAD, "
     "11.7 % off-surface, 1.69° rotation. Originals kept in _removed_2026-10-10."),
    ("2026-10-11 10:21:00", "Performance pass: the run went from ~1060 s to ~190 s (convergence test, multi-start pruning, Schur-complement solver, "
     "vectorised closure vote and association). Cloud equal or better. Deployable package and a compiled standalone that reproduces production."),
    ("2026-10-11 15:00:00", "Event Studio built (+studio): Data, Live, Camera, Pipeline, Code and Build pages, a MATLAB console, and automatic Python setup "
     "on any machine (studio.start)."),
]


def _file():
    return root() / "journal.jsonl"


def _write(entry):
    with _lock, open(_file(), "a") as f:
        f.write(json.dumps(entry) + "\n")


def _ensure():
    if not _file().exists():
        for t, text in SEED:
            ts = datetime.fromisoformat(t.replace(" ", "T")).timestamp()
            _write({"id": uuid.uuid4().hex[:12], "t": ts, "kind": "summary", "author": "studio", "text": text})


def entries():
    _ensure()
    out, deleted = [], set()
    with _lock:
        for line in open(_file()):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("kind") == "delete":
                deleted.add(e["target"])
            else:
                out.append(e)
    return [e for e in out if e["id"] not in deleted]


def add(text, kind="note", author="you", source=None):
    text = (text or "").strip()
    if not text:
        raise ApiError("Empty message")
    _ensure()
    e = {"id": uuid.uuid4().hex[:12], "t": time.time(), "kind": kind, "author": author, "text": text[:20000]}
    if source:
        e["source"] = source
    _write(e)
    hub.publish("journal", e)
    return e


def delete(entry_id):
    if not any(e["id"] == entry_id and e["kind"] == "note" for e in entries()):
        raise ApiError("Only your own notes can be deleted")
    _write({"id": uuid.uuid4().hex[:12], "t": time.time(), "kind": "delete", "target": entry_id})
    hub.publish("journal", {"deleted": entry_id})
    return {"deleted": entry_id}


def on_log(entry):
    """Record notable Studio activity (hub listener)."""
    if entry.get("source") not in AUTO_SOURCES or entry.get("level") not in ("ok", "err", "cmd"):
        return
    text = entry["text"].strip()
    if not text or SKIP.match(text) or len(text) > 400 or text.startswith("▶"):   # results, not "started"
        return
    e = {"id": uuid.uuid4().hex[:12], "t": entry["t"], "kind": "auto", "author": "studio",
         "text": text, "source": entry["source"], "level": entry["level"]}
    _ensure()
    _write(e)
    hub.publish("journal", e)


def export_md():
    lines = ["# Journal", "", "Notes and activity recorded by Event Studio (journal.jsonl).", ""]
    day = None
    for e in sorted(entries(), key=lambda e: e["t"]):
        d = datetime.fromtimestamp(e["t"])
        if d.date() != day:
            day = d.date()
            lines += ["", f"## {day.isoformat()}", ""]
        who = {"note": "**Note**", "summary": "**Summary**", "auto": f"_{e.get('source', 'studio')}_"}[e["kind"]]
        lines.append(f"- {d.strftime('%H:%M')} {who}: {e['text'].replace(chr(10), ' ')}")
    p = root() / "JOURNAL.md"
    p.write_text("\n".join(lines) + "\n")
    return {"path": str(p)}


hub.listeners.append(on_log)
