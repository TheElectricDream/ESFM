"""Server-sent events: everything the browser should hear about without asking."""
import json
import queue
import threading
import time
from collections import deque


class Hub:
    def __init__(self):
        self._subs = set()
        self._lock = threading.Lock()
        self._log = deque(maxlen=400)
        self.listeners = []          # called with every log entry (the journal)

    def subscribe(self):
        q = queue.Queue(maxsize=2000)
        with self._lock:
            self._subs.add(q)
        return q

    def unsubscribe(self, q):
        with self._lock:
            self._subs.discard(q)

    def publish(self, kind, data):
        msg = json.dumps({"type": kind, "data": data, "t": time.time()})
        with self._lock:
            subs = list(self._subs)
        for q in subs:
            try:
                q.put_nowait(msg)
            except queue.Full:
                pass

    def log(self, text, level="info", source="studio"):
        entry = {"text": text, "level": level, "source": source, "t": time.time()}
        self._log.append(entry)
        self.publish("log", entry)
        for fn in self.listeners:
            try:
                fn(entry)
            except Exception:  # noqa: BLE001 - a listener must never break logging
                pass

    def history(self):
        return list(self._log)


hub = Hub()
