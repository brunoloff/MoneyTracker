"""Monotonic inactivity timer, independent of wall-clock changes."""
import threading
import time
from http.server import ThreadingHTTPServer


class IdleServer(ThreadingHTTPServer):
    def __init__(self, *args, idle_seconds=1800, clock=time.monotonic, busy=lambda: False, **kwargs):
        super().__init__(*args, **kwargs)
        self.idle_seconds = idle_seconds
        self.clock = clock
        self.busy = busy
        self.last_activity = clock()
        self.activity_lock = threading.Lock()
        self.stopping = False

    def touch(self):
        with self.activity_lock:
            self.last_activity = self.clock()

    def service_actions(self):
        if self.busy():
            self.touch()
            return
        with self.activity_lock:
            expired = self.clock() - self.last_activity >= self.idle_seconds
            if not expired or self.stopping:
                return
            self.stopping = True
        # shutdown() must run outside the serve_forever thread.
        threading.Thread(target=self.shutdown, daemon=True).start()
