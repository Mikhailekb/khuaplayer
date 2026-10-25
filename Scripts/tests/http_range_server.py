#!/usr/bin/env python3
"""Loopback-only HTTP byte-range fixture for the native HTTPRangeIO tests."""

import base64
import json
import os
import re
import select
import socket
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
    "/short-valid", "/auth", "/cache-interleaved", "/cache-lru",
    "/retry-once", "/retry-twice", "/retry-persistent", "/retry-deadline",
    "/retry-cancel", "/retry-slow", "/retry-reset", "/retry-reset-changed",
    "/retry-total-changed", "/changed-etag", "/invalid-body", "/not-found", "/forbidden",
    "/cache-small-block", "/admission-probe", "/admission-cancel", "/admission-mid",
    "/admission-many", "/admission-mixed", "/admission-entity-change",
    "/admission-conflict-once", "/admission-conflict-repeat", "/admission-conflict-plain",
    "/conflict-default", "/admission-invalid-overbody",
}


def resource_size(path):
    return 8 * 1024 * 1024 + 17 if path.startswith("/cache-") else RESOURCE_SIZE


def cache_resource_bytes(offset, count):
    # Include high position bits so distant windows cannot pass byte checks by
    # accidentally returning the same repeated 256-byte pattern.
    return bytes(((p * 37 + 11) ^ (p >> 8) ^ ((p >> 16) * 13)) & 255
                 for p in range(offset, offset + count))


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
        self.releases = set()

    def mark(self, path, key):
        with self.stats_lock:
            entry = self.stats[path]
            entry[key] = entry.get(key, 0) + 1

    def record(self, path, method, requested_count, start=None, if_range=None):
        with self.stats_lock:
            entry = self.stats.setdefault(path, {
                "head": 0, "get": 0, "max_range": 0, "requested_counts": [], "requests": [],
            })
            entry[method.lower()] += 1
            if requested_count is not None:
                entry["max_range"] = max(entry["max_range"], requested_count)
                entry["requested_counts"].append(requested_count)
            if method == "GET":
                entry["requests"].append({"first": start, "count": requested_count, "if_range": if_range})
            return sum(item["first"] == start for item in entry["requests"])


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
        self._headers(200, 0 if path == "/empty" else resource_size(path))

    def do_GET(self):
        path = urlsplit(self.path).path
        if path.startswith("/release/"):
            _, _, target, attempt = path.split("/")
            with self.server.stats_lock:
                self.server.releases.add(("/" + target, int(attempt)))
            self._headers(200, 0)
            return
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
        size = resource_size(path)
        match = _RANGE.fullmatch(raw_range or "")
        if match is None:
            self.server.record(path, "GET", None)
            self._headers(416, 0, f"bytes */{size}")
            return

        start = int(match.group(1))
        requested_end = int(match.group(2)) if match.group(2) else size - 1
        requested_count = requested_end - start + 1
        attempt = self.server.record(path, "GET", max(0, requested_count), start, self.headers.get("If-Range"))
        if path in {"/not-found", "/forbidden"}:
            self._headers(404 if path == "/not-found" else 403, 0)
            return
        if start != 0 and path.startswith("/retry-"):
            status = 0
            if path in {"/retry-once", "/retry-cancel"} and attempt == 1:
                status = 503
            elif path == "/retry-twice" and attempt <= 2:
                status = 502 if attempt == 1 else 504
            elif path in {"/retry-persistent", "/retry-deadline"}:
                status = 503
            elif path == "/retry-slow" and attempt <= 2:
                status = 503
            if path == "/retry-deadline":
                time.sleep(0.08)
            if path == "/retry-slow":
                time.sleep(0.15 if status else 0.3)
            if status:
                self._headers(status, 0)
                return
        if path == "/empty":
            self._headers(416, 0, "bytes */0")
            return
        if start >= size or requested_end < start:
            self._headers(416, 0, f"bytes */{size}")
            return
        if requested_count > MAX_RANGE_SIZE:
            # Large client reads must be split into bounded HTTP requests.
            self._headers(400, 0)
            return

        if start != 0 and path in {"/conflict-default", "/admission-conflict-plain"}:
            self._headers(409, 0)
            return
        controlled = start != 0 and (path == "/admission-conflict-repeat" or
            path == "/admission-invalid-overbody" or (path == "/admission-conflict-once" and attempt == 1))
        if controlled:
            self.server.mark(path, "response_pending")
            until = time.monotonic() + 3
            while time.monotonic() < until:
                with self.server.stats_lock:
                    released = (path, attempt) in self.server.releases
                if released:
                    break
                time.sleep(0.001)
            if path != "/admission-invalid-overbody":
                self.server.mark(path, "conflicts_sent")
                self._headers(409, 0)
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{requested_end}/{size}")
            self.send_header("ETag", '\"fixture-v1\"')
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            payload = resource_bytes(start, requested_count + 1)
            self._write(f"{len(payload):x}\r\n".encode() + payload + b"\r\n0\r\n\r\n")
            return
        end = min(requested_end, size - 1)
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
        total = 0 if path == "/bad-total" else size
        content_range = f"bytes {origin}-{range_end}/{total}"
        content_length = count + 1 if path == "/bad-length" else count
        if path == "/invalid-body" and start != 0:
            self.send_response(206)
            self.send_header("Content-Range", content_range)
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            self._write(b"4\r\noops\r\n0\r\n\r\n")
            return
        if path.startswith("/admission-"):
            if path == "/admission-mixed" and start != 0 and attempt in {5, 6}:
                self._headers(503 if attempt == 5 else 502, 0)
                return
            self.send_response(206)
            self.send_header("Content-Length", str(content_length))
            self.send_header("Content-Range", content_range)
            self.send_header("ETag", '"fixture-v2"' if path == "/admission-entity-change" and start != 0 and attempt > 1 else '"fixture-v1"')
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            partial = ((path == "/admission-mid" and start != 0 and attempt == 1) or
                       (path in {"/admission-many", "/admission-mixed"} and start != 0 and attempt <= 4) or
                       (path == "/admission-entity-change" and start != 0 and attempt == 1))
            if partial:
                prefix = min(1024, count - 1)
                self._write(resource_bytes(start, prefix))
                self.server.mark(path, "partial_started")
                until = time.monotonic() + 3
                while time.monotonic() < until:
                    readable, _, _ = select.select([self.connection], [], [], 0.005)
                    if readable:
                        try:
                            closed = self.connection.recv(1, socket.MSG_PEEK) == b""
                        except (ConnectionResetError, OSError):
                            closed = True
                        if closed:
                            self.server.mark(path, "disconnected")
                            return
                self.server.mark(path, "not_preempted")
                self._write(resource_bytes(start + prefix, count - prefix))
                return
        elif path.startswith("/retry-") or path == "/changed-etag":
            if path == "/retry-total-changed" and start != 0 and attempt > 1:
                content_range = f"bytes {origin}-{range_end}/{size + 1}"
            self.send_response(206)
            self.send_header("Content-Length", str(content_length))
            self.send_header("Content-Range", content_range)
            changed = (path == "/changed-etag" and start != 0) or (path == "/retry-reset-changed" and start != 0 and attempt > 1)
            self.send_header("ETag", '"fixture-v2"' if changed else '"fixture-v1"')
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            if path in {"/retry-reset", "/retry-reset-changed", "/retry-total-changed"} and start != 0 and attempt == 1:
                self._write(resource_bytes(start, 128))
                return
        else:
            self._headers(206, content_length, content_range)
        if path in {"/stall", "/timeout"} and (start != 0 or end != 0):
            time.sleep(STALL_SECONDS)
        if path == "/truncated":
            count //= 2
        self._write(cache_resource_bytes(start, count) if path.startswith("/cache-")
                    else resource_bytes(start, count))


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
