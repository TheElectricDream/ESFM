"""main.m as a sequence of steps, run one at a time in MATLAB's base workspace.

main.m is split at its `%% [step] <Name>` cell markers (they also work with
MATLAB's Run Section). Code before the first marker (clear; clc; close all)
is not run. Each step is run verbatim with evalin('base', ...), so its
variables appear in the workspace exactly as if main.m had run up to there.

The Configuration step additionally rebuilds cfg from config.m plus the
Studio's overrides (.studio_cache/config_studio/studio_config.m) when there
are any. A step becomes stale when its code, a parameter of a cfg section it
(or any function it calls) reads, or one of those functions changes; every
later step is stale with it.
"""
import hashlib
import re
import threading
import time

from . import code_index, config_model
from .common import ApiError, cache, require_memory, root
from .hub import hub
from .matlab_link import matlab

MARK_RE = re.compile(r"^%%\s*\[step\]\s*(.+?)\s*$")
CALL_RE = re.compile(r"(?<![\w.])([a-z]\w*)\.([A-Za-z]\w*)\s*\(")
ASSIGN_RE = re.compile(r"^\s*(\[[^\]]*\]|[A-Za-z]\w*)\s*(?:\.[\w.]+|\([^=]*\))?\s*=(?!=)")


def parse_steps():
    text = (root() / "main.m").read_text()
    lines = text.split("\n")
    steps, cur = [], None
    for i, ln in enumerate(lines):
        m = MARK_RE.match(ln.strip())
        if m:
            cur = {"name": m.group(1), "line": i + 1, "code_lines": []}
            steps.append(cur)
        elif cur is not None:
            cur["code_lines"].append(ln)
    funcs = code_index.by_full_name()
    for k, s in enumerate(steps):
        code = "\n".join(s.pop("code_lines")).strip("\n")
        s["id"] = k
        s["code"] = code
        s["hash"] = hashlib.sha1(code.encode()).hexdigest()[:12]
        exec_lines = [ln.split("%", 1)[0] for ln in code.split("\n")]
        calls = sorted({f"{a}.{b}" for a, b in CALL_RE.findall("\n".join(exec_lines)) if f"{a}.{b}" in funcs})
        sections, reached = code_index.closure_sections(calls)
        sections |= set(re.findall(r"\bcfg\.([A-Za-z]\w*)", "\n".join(exec_lines)))
        s["calls"] = calls
        s["reaches"] = sorted(reached)
        s["sections"] = sorted(sections)
        outs = []
        for ln in exec_lines:
            m = ASSIGN_RE.match(ln)
            if m:
                lhs = m.group(1)
                names = [x.strip() for x in lhs.strip("[]").split(",")] if lhs.startswith("[") else [lhs]
                for n in names:
                    n = n.split(".")[0].split("(")[0].strip()
                    if n and n != "~" and n not in outs:
                        outs.append(n)
        s["outputs"] = outs
        s["is_config"] = bool(re.search(r"\bcfg\s*=\s*config\s*\(", code))
        s["lines"] = code.count("\n") + 1
    return steps


class Pipeline:
    def __init__(self):
        self.state = {}         # step name -> {status, elapsed, hash, error, changed, ran_at}
        self.running = None     # {"target": .., "current": ..}
        self._lock = threading.Lock()
        self.cancel = False
        self.epoch = 0          # bumps on every reset: the page forgets logs and views

    def summary(self):
        steps = parse_steps()
        for s in steps:
            st = self.state.get(s["name"], {"status": "pending"})
            if st.get("status") == "done" and st.get("hash") != s["hash"]:
                st = dict(st, status="stale", stale_reason="its code in main.m changed")
            s["state"] = st
        return {"steps": steps, "running": self.running, "overrides": config_model.overrides(), "epoch": self.epoch}

    def publish(self):
        hub.publish("pipeline", self.summary())

    def mark_stale_from(self, idx, reason):
        steps = parse_steps()
        for s in steps[idx:]:
            st = self.state.get(s["name"])
            if st and st.get("status") in ("done", "error"):
                st["status"] = "stale"
                st["stale_reason"] = reason
        self.publish()

    def on_override(self, path):
        steps = parse_steps()
        section = path.split(".")[0] if "." in path else None
        first = None
        for s in steps:
            if s["is_config"]:
                continue
            if section is None or section in s["sections"]:
                first = s["id"]
                break
        if first is not None:
            self.mark_stale_from(first, f"parameter {path} changed")
        else:
            self.publish()

    def on_code_saved(self, rel):
        if rel == "config.m":
            self.mark_stale_from(0, "config.m changed")
            return
        if rel == "main.m":
            self.publish()
            return
        e = next((x for x in code_index.index() if x["path"] == rel), None)
        if not e:
            return
        for s in parse_steps():
            if e["full"] in s["reaches"]:
                self.mark_stale_from(s["id"], f"{e['full']} changed")
                return

    def reset(self):
        if self.running:
            raise ApiError("A run is in progress", 409)
        self.state = {}
        self.epoch += 1
        self.publish()

    def fresh_start(self, why):
        """A new input recording: forget every step and clear MATLAB's workspace."""
        self.reset()
        cleared = False
        if matlab.state == "idle":
            try:
                matlab.request("ws.clear", {"names": []}, label="Clear workspace", timeout=60)
                cleared = True
            except ApiError:
                pass
        hub.log(f"Pipeline reset: {why}" + (" (workspace cleared)" if cleared else ""), "ok", "pipeline")
        return cleared

    def run(self, target, mode="to"):
        """mode 'to': run every step up to TARGET that is not done; 'only': TARGET alone."""
        steps = parse_steps()
        if not 0 <= target < len(steps):
            raise ApiError("No such step")
        if matlab.state == "offline":
            raise ApiError("MATLAB is not connected", 503)
        with self._lock:
            if self.running:
                raise ApiError("A run is in progress", 409)
            todo = []
            if mode == "only":
                todo = [target]
            else:
                for s in steps[:target + 1]:
                    st = self.state.get(s["name"], {})
                    if st.get("status") != "done" or st.get("hash") != s["hash"] or s["id"] == target:
                        todo.append(s["id"])
                # once one step reruns, everything after it reruns too
                if todo:
                    todo = list(range(todo[0], target + 1))
            self.running = {"target": target, "todo": todo, "current": None}
            self.cancel = False
        threading.Thread(target=self._run, args=(todo,), daemon=True).start()
        return {"todo": todo}

    def _run(self, todo):
        try:
            for idx in todo:
                if self.cancel:
                    hub.log("Pipeline run cancelled after the current step", "warn", "pipeline")
                    break
                steps = parse_steps()
                s = steps[idx]
                self.running["current"] = idx
                self.state[s["name"]] = {"status": "running", "started": time.time(), "hash": s["hash"]}
                self.publish()
                args = {"name": s["name"], "code": s["code"]}
                if s["is_config"] and config_model.overrides():
                    args["config_dir"] = str(config_model.write_studio_config())
                hub.log(f"▶ {s['name']}", "cmd", "pipeline")
                t0 = time.time()
                try:
                    if not s["is_config"]:
                        require_memory(f"the step {s['name']}")
                    res = matlab.request("step.run", args, label=f"Step: {s['name']}",
                                         log_file=cache() / f"step_{idx}.log", run_id=f"step{idx}")
                except ApiError as e:
                    self.state[s["name"]] = {"status": "error", "error": str(e),
                                             "report": e.details.get("report", ""), "hash": s["hash"],
                                             "elapsed": round(time.time() - t0, 2), "ran_at": time.time()}
                    hub.log(f"✖ {s['name']}: {e}", "err", "pipeline")
                    break
                self.state[s["name"]] = {"status": "done", "elapsed": res.get("elapsed"), "hash": s["hash"],
                                         "changed": res.get("changed", []), "ran_at": time.time(),
                                         "overrides": dict(config_model.overrides())}
                hub.log(f"✔ {s['name']} ({res.get('elapsed', 0):.1f} s)", "ok", "pipeline")
                # a rerun invalidates what came after it
                for later in steps[idx + 1:]:
                    st = self.state.get(later["name"])
                    if st and st.get("status") == "done" and later["id"] not in todo:
                        st["status"] = "stale"
                        st["stale_reason"] = f"{s['name']} was rerun"
                self.publish()
        finally:
            self.running = None
            self.publish()


pipeline = Pipeline()
