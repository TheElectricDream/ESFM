#!/usr/bin/env python3
"""Event Studio remote camera agent.

Runs on the computer the DVXplorer is plugged into (a Jetson Orin, say);
Event Studio copies it there over SSH, sets up its Python environment and
starts it. It opens the camera with dv_processing and writes its events to
stdout, which travels back over the same SSH connection (no ports, no
firewall rules). Commands arrive on stdin, one JSON object per line.

stdout frames:
    b"E" + uint32 n + int64[n] t_us + uint16[n] x + uint16[n] y + uint8[n] p
    b"J" + uint32 len + UTF-8 JSON   (hello, status, error)
stdin:
    {"cmd": "set", "key": "ContrastThresholdOn", "value": 20}
    {"cmd": "stop"}

    python3 agent.py [--serial SN] [--replay recording.aedat4] [--batch-ms 10]
"""
import argparse
import json
import struct
import sys
import threading
import time

import numpy as np

OUT = sys.stdout.buffer
LOCK = threading.Lock()
CONTROLS = [("ContrastThresholdOn", "ON Threshold", "int"), ("ContrastThresholdOff", "OFF Threshold", "int"),
            ("FlipHorizontal", "Flip Horizontal", "bool"), ("FlipVertical", "Flip Vertical", "bool")]


def send_json(obj):
    data = json.dumps(obj).encode()
    with LOCK:
        OUT.write(b"J" + struct.pack("<I", len(data)) + data)
        OUT.flush()


def send_events(t, x, y, p):
    n = len(t)
    if not n:
        return
    with LOCK:
        OUT.write(b"E" + struct.pack("<I", n))
        OUT.write(np.ascontiguousarray(t, np.int64).tobytes())
        OUT.write(np.ascontiguousarray(x, np.uint16).tobytes())
        OUT.write(np.ascontiguousarray(y, np.uint16).tobytes())
        OUT.write(np.ascontiguousarray(p, np.uint8).tobytes())
        OUT.flush()


def controls(cam):
    out = []
    for key, label, kind in CONTROLS:
        g = getattr(cam, "get" + key, None)
        if g:
            try:
                out.append({"key": key, "label": label, "kind": kind, "value": g()})
            except Exception:  # noqa: BLE001
                pass
    return out


def commands(state):
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("cmd") == "stop":
            state["run"] = False
            break
        if msg.get("cmd") == "set" and state.get("cam") is not None:
            cam = state["cam"]
            key = msg.get("key")
            if key in {k for k, _, _ in CONTROLS} and hasattr(cam, "set" + key):
                try:
                    v = msg["value"]
                    getattr(cam, "set" + key)(bool(v) if isinstance(v, bool) else int(v))
                    send_json({"type": "controls", "controls": controls(cam)})
                except Exception as e:  # noqa: BLE001
                    send_json({"type": "error", "message": f"{key}: {e}"})
    state["run"] = False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial")
    ap.add_argument("--replay")
    ap.add_argument("--batch-ms", type=float, default=10.0)
    a = ap.parse_args()
    import dv_processing as dv
    state = {"run": True, "cam": None}
    threading.Thread(target=commands, args=(state,), daemon=True).start()
    if a.replay:
        src = dv.io.MonoCameraRecording(a.replay)
        name = "Replay of " + a.replay.rsplit("/", 1)[-1]
    else:
        try:
            src = dv.io.camera.open(a.serial) if a.serial else dv.io.camera.open()
        except Exception as e:  # noqa: BLE001
            found = [str(getattr(d, "serialNumber", d)) for d in dv.io.camera.discover()]
            send_json({"type": "error", "message": f"No camera could be opened on this computer: {e}. "
                       f"Devices found: {found or 'none'}. Is the DVXplorer plugged in, and the iniVation udev "
                       "rule installed?"})
            return 2
        state["cam"] = src
        name = src.getCameraName()
    w, h = src.getEventResolution()
    send_json({"type": "hello", "name": name, "width": w, "height": h, "host": __import__("socket").gethostname(),
               "controls": controls(src) if state["cam"] is not None else []})
    chunks, last, wall0, t_first = [], time.time(), time.time(), None
    try:
        while state["run"] and src.isRunning():
            b = src.getNextEventBatch()
            if b is None:
                time.sleep(0.001)
                continue
            a_ = b.numpy()
            if not len(a_):
                continue
            if a.replay:               # pace a replay in real time
                if t_first is None:
                    t_first = int(a_["timestamp"][0])
                ahead = (int(a_["timestamp"][-1]) - t_first) / 1e6 - (time.time() - wall0)
                if ahead > 0:
                    time.sleep(ahead)
            chunks.append(a_)
            if (time.time() - last) * 1000 >= a.batch_ms:
                c = np.concatenate(chunks)
                send_events(c["timestamp"], c["x"], c["y"], (c["polarity"] > 0).astype(np.uint8))
                chunks, last = [], time.time()
    except BrokenPipeError:
        return 0
    send_json({"type": "status", "message": "stopped"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
