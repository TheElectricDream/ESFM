"""The remote camera: a DVXplorer plugged into another computer (a Jetson Orin).

Over one SSH connection (paramiko): upload remote/agent.py and the setup
script to the remote folder, set up the agent's Python environment there
(once; later only checked), start the agent, and read its event stream from
the agent's stdout. Camera settings go back on its stdin. Every stage is
reported so the page can say what is happening.
"""
import json
import posixpath
import struct
import threading
from pathlib import Path

import numpy as np

from .common import ApiError
from .hub import hub

HERE = Path(__file__).resolve().parent.parent
FILES = {"agent.py": HERE / "remote" / "agent.py", "setup_env.py": HERE / "setup_env.py",
         "requirements.txt": HERE / "remote" / "requirements.txt"}


def _paramiko():
    try:
        import paramiko
        return paramiko
    except ImportError:
        raise ApiError("The remote camera needs the paramiko package; run studio.setup (it installs it) and restart the Studio")


def connect(cfg, timeout=8):
    pm = _paramiko()
    c = pm.SSHClient()
    c.set_missing_host_key_policy(pm.AutoAddPolicy())   # lab network: accept the camera computer's key
    kw = {"hostname": cfg["host"], "port": int(cfg["port"] or 22), "username": cfg["user"], "timeout": timeout,
          "banner_timeout": timeout, "auth_timeout": timeout}
    if cfg.get("key_file"):
        kw["key_filename"] = str(Path(cfg["key_file"]).expanduser())
    if cfg.get("password"):
        kw["password"] = cfg["password"]
    try:
        c.connect(**kw, look_for_keys=not cfg.get("password"), allow_agent=not cfg.get("password"))
    except Exception as e:  # noqa: BLE001
        raise ApiError(f"Could not log in to {cfg['user']}@{cfg['host']}:{cfg['port']}: {e}", 502)
    return c


def run(client, cmd, timeout=30):
    _, out, err = client.exec_command(cmd, timeout=timeout)
    code = out.channel.recv_exit_status()
    return code, out.read().decode(errors="replace"), err.read().decode(errors="replace")


def test(cfg):
    c = connect(cfg)
    try:
        code, out, _ = run(c, "uname -nm; (command -v " + cfg["python"] + " >/dev/null && " + cfg["python"]
                           + " --version) 2>&1; (lsusb 2>/dev/null | grep -i 152a || echo 'no iniVation USB device')")
        lines = [ln for ln in out.strip().splitlines() if ln]
        return {"ok": True, "host": lines[0] if lines else "", "python": lines[1] if len(lines) > 1 else "",
                "usb": lines[2:] or []}
    finally:
        c.close()


class RemoteStream:
    """One running agent: setup, start, and the event reader."""

    def __init__(self, cfg, on_events, on_message, on_stage):
        self.cfg, self.on_events, self.on_message, self.on_stage = cfg, on_events, on_message, on_stage
        self.client = self.chan = None
        self.running = False
        self.failed = False          # the agent reported its own error (keep that message)

    def stage(self, text, level="info"):
        self.on_stage(text)
        hub.log(text, level, "remote")

    def start(self, serial=None, replay=None):
        cfg = self.cfg
        self.stage(f"Connecting to {cfg['user']}@{cfg['host']}…")
        self.client = connect(cfg)
        _, home, _ = run(self.client, "echo $HOME")
        rdir = cfg["remote_dir"].replace("~", home.strip(), 1)
        self.stage(f"Copying the camera agent to {cfg['host']}:{rdir}")
        sftp = self.client.open_sftp()
        try:
            run(self.client, f"mkdir -p '{rdir}'")
            for name, local in FILES.items():
                sftp.put(str(local), posixpath.join(rdir, name))
        finally:
            sftp.close()
        self.stage(f"Setting up Python on {cfg['host']} (the first time takes a minute: it installs numpy and dv-processing)")
        report = posixpath.join(rdir, "report.json")
        cmd = (f"cd '{rdir}' && PYTHONNOUSERSITE=1 {cfg['python']} -u setup_env.py --requirements requirements.txt "
               f"--min-python 3.8 --report '{report}' 2>&1")
        _, out, _ = self.client.exec_command(cmd, timeout=900)
        for line in iter(out.readline, ""):
            line = line.rstrip()
            if line:
                hub.log(line.replace("[Event Studio] ", ""), "info", "remote")
                if line.startswith("[Event Studio]"):
                    self.on_stage(line.replace("[Event Studio] ", f"{cfg['host']}: "))
        if out.channel.recv_exit_status() != 0:
            raise ApiError(f"Setting up Python on {cfg['host']} failed (the Log on the MATLAB page has its messages)", 502)
        code, rep, _ = run(self.client, f"cat '{report}'")
        py = json.loads(rep)["python"]
        args = ""
        if serial:
            args += f" --serial '{serial}'"
        if replay:
            args += f" --replay '{replay}'"
        self.stage(f"Starting the camera on {cfg['host']}…")
        stdin, stdout, stderr = self.client.exec_command(f"cd '{rdir}' && PYTHONNOUSERSITE=1 '{py}' -u agent.py{args}")
        self.chan, self.stdin = stdout.channel, stdin
        self.running = True
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._errors, args=(stderr,), daemon=True).start()

    def _recv(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.chan.recv(min(1 << 20, n - len(buf)))
            if not chunk:
                raise EOFError
            buf += chunk
        return bytes(buf)

    def _read(self):
        try:
            while self.running:
                kind = self._recv(1)
                (n,) = struct.unpack("<I", self._recv(4))
                if kind == b"E":
                    t = np.frombuffer(self._recv(8 * n), np.int64)
                    x = np.frombuffer(self._recv(2 * n), np.uint16)
                    y = np.frombuffer(self._recv(2 * n), np.uint16)
                    p = np.frombuffer(self._recv(n), np.uint8)
                    self.on_events(t, x, y, p)
                elif kind == b"J":
                    m = json.loads(self._recv(n))
                    self.failed = self.failed or m.get("type") == "error"
                    self.on_message(m)
                else:
                    raise ValueError(f"unexpected data from the agent ({kind!r})")
        except EOFError:
            if self.running and not self.failed:
                self.on_message({"type": "error", "message": "The remote camera agent stopped"})
        except Exception as e:  # noqa: BLE001
            self.on_message({"type": "error", "message": f"Remote stream: {e}"})
        self.running = False

    def _errors(self, stderr):
        for line in iter(stderr.readline, ""):
            if line.strip():
                hub.log(line.rstrip(), "warn", "remote")

    def send(self, obj):
        if self.running:
            self.stdin.write(json.dumps(obj) + "\n")
            self.stdin.flush()

    def stop(self):
        try:
            self.send({"cmd": "stop"})
        except Exception:  # noqa: BLE001
            pass
        self.running = False
        if self.client:
            self.client.close()
