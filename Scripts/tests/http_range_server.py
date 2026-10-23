#!/usr/bin/env python3
"""Loopback-only HTTP byte-range fixture for the native HTTPRangeIO tests."""

import base64
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


RESOURCE_SIZE = 2 * 1024 * 1024 + 17
MAX_RANGE_SIZE = 256 * 1024
STALL_SECONDS = 10
_PATTERN = bytes((offset * 37 + 11) % 256 for offset in range(256))
_RANGE = re.compile(r"bytes=(\d+)-(\d*)\Z")
_AUTHORIZATION = "Basic " + base64.b64encode(b"user name:p:ass word").decode("ascii")
_PATHS = {
    "/ok", "/head405", "/bad-origin", "/bad-total", "/truncated",
    "/bad-length", "/ignore-range", "/stall", "/timeout", "/empty",
    "/short-valid", "/auth",
}


def resource_bytes(offset, count):
    """Produce any slice without retaining a multi-megabyte fixture file."""
    start = offset % len(_PATTERN)
    return (_PATTERN * ((start + count + 255) // 256))[start:start + count]


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), RangeHandler)
        self.stats_lock = threading.Lock()
        self.stats = {}

    def record(self, path, method, requested_count):
        with self.stats_lock:
            entry = self.stats.setdefault(path, {
                "head": 0, "get": 0, "max_range": 0, "requested_counts": [],
            })
            entry[method.lower()] += 1
            if requested_count is not None:
                entry["max_range"] = max(entry["max_range"], requested_count)
                entry["requested_counts"].append(requested_count)


class RangeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # Keep stdout reserved for the startup JSON consumed by the harness.
        pass

    def _headers(self, status, length, content_range=None, content_type=None):
        self.send_response(status)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Connection", "close")
        self.send_header("Content-Type", content_type or "application/octet-stream")
        if content_range is not None:
            self.send_header("Content-Range", content_range)
        self.end_headers()
        self.close_connection = True

    def _write(self, body):
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # Malformed-response and timeout tests deliberately disconnect.
            pass

    def do_HEAD(self):
        path = urlsplit(self.path).path
        if path not in _PATHS:
            self._headers(404, 0)
            return
        self.server.record(path, "HEAD", None)
        if path == "/auth" and self.headers.get("Authorization") != _AUTHORIZATION:
            self._headers(401, 0)
            return
        if path == "/head405":
            self._headers(405, 0)
            return
        self._headers(200, 0 if path == "/empty" else RESOURCE_SIZE)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/stats":
            with self.server.stats_lock:
                body = json.dumps(self.server.stats, sort_keys=True).encode("utf-8")
            self._headers(200, len(body), content_type="application/json")
            self._write(body)
            return
        if path not in _PATHS:
            self._headers(404, 0)
            return
        if path == "/auth" and self.headers.get("Authorization") != _AUTHORIZATION:
            self.server.record(path, "GET", None)
            self._headers(401, 0)
            return

        raw_range = self.headers.get("Range")
        match = _RANGE.fullmatch(raw_range or "")
        if match is None:
            self.server.record(path, "GET", None)
            self._headers(416, 0, f"bytes */{RESOURCE_SIZE}")
            return

        start = int(match.group(1))
        requested_end = int(match.group(2)) if match.group(2) else RESOURCE_SIZE - 1
        requested_count = requested_end - start + 1
        self.server.record(path, "GET", max(0, requested_count))
        if path == "/empty":
            self._headers(416, 0, "bytes */0")
            return
        if start >= RESOURCE_SIZE or requested_end < start:
            self._headers(416, 0, f"bytes */{RESOURCE_SIZE}")
            return
        if requested_count > MAX_RANGE_SIZE:
            # Large client reads must be split into bounded HTTP requests.
            self._headers(400, 0)
            return

        end = min(requested_end, RESOURCE_SIZE - 1)
        if path == "/short-valid":
            end = min(end, start + 10)
        count = end - start + 1
        if path == "/ignore-range":
            self._headers(200, RESOURCE_SIZE)
            # A range reader must reject 200 before consuming this response.
            self._write(resource_bytes(0, min(64 * 1024, RESOURCE_SIZE)))
            return

        origin = start + 1 if path == "/bad-origin" else start
        range_end = end + 1 if path == "/bad-origin" else end
        total = 0 if path == "/bad-total" else RESOURCE_SIZE
        content_range = f"bytes {origin}-{range_end}/{total}"
        content_length = count + 1 if path == "/bad-length" else count
        self._headers(206, content_length, content_range)
        if path in {"/stall", "/timeout"} and (start != 0 or end != 0):
            time.sleep(STALL_SECONDS)
        if path == "/truncated":
            count //= 2
        self._write(resource_bytes(start, count))


def main():
    server = FixtureServer()
    print(json.dumps({"port": server.server_port, "pid": os.getpid()}), flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
