"""The MATLAB worker connection.

The worker (studio.Worker, started by studio.start in the user's MATLAB or by
studio.serve in a headless MATLAB this module launches) connects to a local
TCP port and receives one JSON command per line:
    {"id": 7, "cmd": "eval", "args": {...}}
and answers {"id": 7, "ok": true, "result": ...} or {"id": 7, "ok": false,
"error": "...", "report": "..."}. MATLAB runs one command at a time on its main
thread, so this link does the same: while a command runs, MATLAB is "busy" and
other requests are refused at once (409) instead of queueing behind a long step.
Output of commands that run user code is captured with MATLAB's diary into a
file that is tailed here and streamed to the browser as it appears.
"""
import itertools
import json
import os
import secrets
import socket
import subprocess
import threading
import time
from pathlib import Path

from .common import ApiError, STUDIO_DIR, cache, find_matlab, require_memory, root
from .hub import hub


class MatlabLink:
    def __init__(self):
        self.token = secrets.token_hex(16)
        self.port = None
        self._sock = None
        self._conn = None
        self._send_lock = threading.Lock()
        self._busy_lock = threading.Lock()
        self._pending = {}
        self._ids = itertools.count(1)
        self.busy = None            # label of the running command
        self.busy_cmd = None
        self.busy_since = None
        self.info = None
        self.state = "offline"      # offline | starting | idle | busy
        self.proc = None            # headless MATLAB we started, if any

    # ---------------- listening ----------------
    def listen(self, port=0):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", port))
        self._sock.listen(2)
        self.port = self._sock.getsockname()[1]
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def _accept_loop(self):
        while True:
            conn, _ = self._sock.accept()
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        f = conn.makefile("rb")
        try:
            hello = json.loads(f.readline().decode() or "{}")
        except ValueError:
            conn.close()
            return
        if hello.get("hello") != "studio-worker" or hello.get("token") != self.token:
            conn.close()
            return
        old = self._conn
        self._conn = conn
        if old:
            try:
                old.close()
            except OSError:
                pass
        self.info = hello.get("info", {})
        self._set_state("idle")
        hub.log(f"MATLAB {self.info.get('release', '')} connected (pid {self.info.get('pid', '?')}, "
                f"{'desktop' if self.info.get('desktop') else 'headless'})", "ok", "matlab")
        try:
            for raw in f:
                try:
                    msg = json.loads(raw.decode())
                except ValueError:
                    continue
                waiter = self._pending.pop(msg.get("id"), None)
                if waiter:
                    waiter["msg"] = msg
                    waiter["event"].set()
        except OSError:
            pass
        if self._conn is conn:
            self._conn = None
            self.info = None
            for w in list(self._pending.values()):
                w["msg"] = {"ok": False, "error": "MATLAB disconnected"}
                w["event"].set()
            self._pending.clear()
            self.busy = None
            self._set_state("offline")
            hub.log("MATLAB disconnected", "warn", "matlab")

    def _set_state(self, state):
        self.state = state
        hub.publish("matlab", self.status())

    def status(self):
        return {"state": self.state, "busy": self.busy,
                "busy_s": round(time.time() - self.busy_since, 1) if self.busy_since and self.busy else None,
                "info": self.info, "headless": bool(self.proc and self.proc.poll() is None),
                "matlab_exe": find_matlab()}

    # ---------------- requests ----------------
    QUICK = {"ws.list", "ws.inspect", "view", "config.load", "lint", "rehash", "edit", "info", "ping"}

    def request(self, cmd, args=None, label=None, log_file: Path | None = None, run_id=None, timeout=None):
        """Run one worker command and return its result (raises ApiError).

        MATLAB runs one command at a time. A command that finds MATLAB busy
        with a SHORT command (a workspace listing, a view, a code check: the
        page asks for these all the time, e.g. right after a step finishes)
        waits for it, up to a minute. Only a command that would queue behind
        a LONG one (user code, a pipeline step, a build) is refused at once,
        so the page can say MATLAB is busy instead of hanging."""
        if not self._conn:
            raise ApiError("MATLAB is not connected. Run studio.start in MATLAB, or press Start MATLAB.", 503)
        got = self._busy_lock.acquire(blocking=False)
        if not got:
            t_end = time.time() + 60
            while not got and time.time() < t_end and (self.busy_cmd in self.QUICK or self.busy_cmd is None):
                got = self._busy_lock.acquire(timeout=0.1)
        if not got:
            raise ApiError(f"MATLAB is busy: {self.busy}", 409, busy=self.busy)
        self.busy_cmd = cmd
        tail = None
        try:
            self.busy = label or cmd
            self.busy_since = time.time()
            self._set_state("busy")
            rid = next(self._ids)
            waiter = {"event": threading.Event(), "msg": None}
            self._pending[rid] = waiter
            payload = {"id": rid, "cmd": cmd, "args": args or {}}
            if log_file is not None:
                if log_file.exists():
                    log_file.unlink()
                payload["args"]["log"] = str(log_file)
                tail = _Tail(log_file, run_id or rid)
                tail.start()
            data = (json.dumps(payload) + "\n").encode()
            with self._send_lock:
                self._conn.sendall(data)
            if not waiter["event"].wait(timeout):
                self._pending.pop(rid, None)
                raise ApiError(f"MATLAB did not answer {cmd} within {timeout} s", 504)
            msg = waiter["msg"]
        finally:
            if tail:
                tail.stop()
            self.busy = None
            self.busy_cmd = None
            self.busy_since = None
            if self._conn:
                self._set_state("idle")
            self._busy_lock.release()
        if not msg.get("ok"):
            raise ApiError(msg.get("error", "MATLAB error"), 422, report=msg.get("report", ""),
                           output=msg.get("output", ""))
        return msg.get("result")

    # ---------------- a headless MATLAB ----------------
    def start_headless(self):
        if self._conn:
            return self.status()
        if self.proc and self.proc.poll() is None:
            return self.status()
        require_memory("a headless MATLAB", 3)
        exe = find_matlab()
        if not exe:
            raise ApiError("No MATLAB found (set STUDIO_MATLAB to its bin/matlab)", 404)
        lib = str(STUDIO_DIR.parent).replace("'", "''")
        rt = str(root()).replace("'", "''")
        cmd = f"addpath('{lib}'); studio.serve({self.port}, '{self.token}', '{rt}', {os.getpid()})"
        log = open(cache() / "matlab_headless.log", "w")
        self.proc = subprocess.Popen([exe, "-batch", cmd], stdout=log, stderr=subprocess.STDOUT,
                                     cwd=str(root()), start_new_session=True)
        self._set_state("starting")
        hub.log(f"Starting headless MATLAB ({exe})", "info", "matlab")
        threading.Thread(target=self._watch_proc, args=(self.proc,), daemon=True).start()
        return self.status()

    def _watch_proc(self, proc):
        code = proc.wait()
        if self.state == "starting":
            self._set_state("offline")
        hub.log(f"Headless MATLAB exited ({code}); its log: .studio_cache/matlab_headless.log",
                "warn" if code else "info", "matlab")

    def stop_headless(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
        return self.status()


class _Tail(threading.Thread):
    """Stream a growing diary file to the browser as 'matlab-output' events."""

    def __init__(self, path: Path, run_id):
        super().__init__(daemon=True)
        self.path, self.run_id = path, run_id
        self._stop = threading.Event()
        self._pos = 0

    def run(self):
        while not self._stop.wait(0.3):
            self._read()

    def _read(self):
        try:
            with open(self.path, "rb") as f:
                f.seek(self._pos)
                chunk = f.read()
        except OSError:
            return
        if chunk:
            self._pos += len(chunk)
            hub.publish("matlab-output", {"run": self.run_id, "text": chunk.decode(errors="replace")})

    def stop(self):
        self._stop.set()
        time.sleep(0.05)
        self._read()


matlab = MatlabLink()
