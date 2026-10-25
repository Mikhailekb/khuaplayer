#!/usr/bin/env python3
"""Loopback byte-range fault fixture; never contacts a torrent or remote host."""

import argparse
import json
import os
import re
import signal
import socket
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


FIXTURE_AUTH = "Basic dXNlcjpzZWNyZXQ="  # Fixture-only user:secret.
DEFAULT_LENGTH = 8 * 1024 * 1024 * 1024
CHUNK = bytes(range(256)) * 256
RANGE = re.compile(r"bytes=(\d+)-(\d+)\Z")


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, events):
        self.events = events
        self.events_lock = threading.Lock()
        self.request_count = 0
        self.capacity = {}
        self.attempts = {}
        super().__init__(("127.0.0.1", 0), Handler)

    def begin_request(self, **fields):
        with self.events_lock:
            self.request_count += 1
            count = self.request_count
            self.write_event_locked(kind="request", count=count, monotonic=time.monotonic(), **fields)
            return count

    def attempt(self, tag):
        with self.events_lock:
            value = self.attempts.get(tag, 0) + 1
            self.attempts[tag] = value
            return value

    def write_event_locked(self, **fields):
        with self.events.open("a", encoding="utf-8") as output:
            output.write(json.dumps(fields, separators=(",", ":")) + "\n")

    def record_finished(self, **fields):
        with self.events_lock:
            self.write_event_locked(kind="finished", **fields)

    def record_gate(self, **fields):
        with self.events_lock:
            self.write_event_locked(kind="gated", **fields)

    def capacity_state(self, tag, upper=None):
        with self.events_lock:
            state = self.capacity.setdefault(tag, {"upper": 1024 * 1024, "revision": 1})
            if upper is not None:
                state["upper"] = upper
                state["revision"] += 1
            return dict(state)

    def capacity_stopped(self, tag, **fields):
        with self.events_lock:
            state = self.capacity[tag]
            state["prefetch_stop"] = dict(reason="capacity", revision=state["revision"], **fields)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *unused):
        pass

    def answer(self, status, size=0, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.send_header("Connection", "close")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.close_connection = True

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path == "/fixture-capacity":
            query = urllib.parse.parse_qs(url.query)
            upper = int(query["upper"][0]) if "upper" in query else None
            state = self.server.capacity_state(query["capacity_tag"][0], upper)
            body = json.dumps(state, separators=(",", ":")).encode("ascii")
            self.answer(200, size=len(body))
            self.wfile.write(body)
            return
        supplied_auth = self.headers.get("Authorization")
        # Only fixture credentials are retained in the audit log.
        auth = FIXTURE_AUTH if supplied_auth == FIXTURE_AUTH else (
            "other" if supplied_auth is not None else None
        )
        fields = {"path": url.path, "requestTarget": self.path,
                  "auth": auth, "range": self.headers.get("Range"),
                  "acceptEncoding": self.headers.get("Accept-Encoding"),
                  "cacheControl": self.headers.get("Cache-Control")}
        count = self.server.begin_request(**fields)
        self.bytes_sent = 0
        try:
            self.serve_range(url)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True
        finally:
            self.server.record_finished(count=count, byteCount=self.bytes_sent,
                                        **fields)

    def serve_range(self, url):
        endpoint = url.path
        query_suffix = "?" + url.query if url.query else ""
        if endpoint == "/redirect-same":
            self.answer(302, headers={"Location": "/valid" + query_suffix})
            return
        if endpoint in {"/redirect-unmanaged", "/redirect-wrong-consumer", "/redirect-drop-prefetch",
                        "/redirect-drop-request", "/redirect-wrong-request"}:
            removed = "playback_prefetch" if endpoint == "/redirect-drop-prefetch" else (
                "playback_prefetch_request" if endpoint in {"/redirect-drop-request", "/redirect-wrong-request"}
                else "playback_consumer")
            query = [(name, value) for name, value in urllib.parse.parse_qsl(url.query)
                     if name != removed]
            if endpoint == "/redirect-wrong-consumer":
                query.append(("playback_consumer", "another-consumer"))
            if endpoint == "/redirect-wrong-request":
                query.append(("playback_prefetch_request", "another-request"))
            self.answer(302, headers={"Location": "/valid?" + urllib.parse.urlencode(query)})
            return
        if endpoint == "/redirect-loop":
            self.answer(302, headers={"Location": "/redirect-loop" + query_suffix})
            return
        if endpoint == "/redirect-other":
            target = "http://localhost:%d/redirect-target%s" % (
                self.server.server_port, query_suffix)
            self.answer(302, headers={"Location": target})
            return
        if endpoint == "/error":
            self.answer(503)
            return
        if endpoint == "/auth" and self.headers.get("Authorization") != FIXTURE_AUTH:
            self.answer(401, headers={"WWW-Authenticate": 'Basic realm="fixture"'})
            return
        if endpoint not in {
            "/valid", "/slow", "/gated-growth", "/short", "/recover-short", "/preheaders", "/slow-short", "/quota-shrink", "/capacity-cycle", "/wrong-start", "/wrong-end",
            "/wrong-total", "/no-range", "/encoded", "/missing-range",
            "/oversize", "/auth", "/redirect-target", "/delay-headers",
        }:
            self.answer(404)
            return

        try:
            query = urllib.parse.parse_qs(url.query)
            tag = query.get("tag", [""])[0]
            attempt = self.server.attempt(tag)
            if endpoint == "/preheaders" and self.server.events.with_name("hold-preheaders-" + tag).exists():
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            file_length = int(query.get("length", [str(DEFAULT_LENGTH)])[0])
            match = RANGE.fullmatch(self.headers.get("Range", ""))
            if match is None or file_length <= 0:
                raise ValueError
            start, end = map(int, match.groups())
            if not 0 <= start <= end < file_length:
                self.answer(416, headers={"Content-Range": "bytes */%d" % file_length})
                return
        except (ValueError, OverflowError):
            self.answer(400)
            return

        expected = end - start + 1
        range_start = start + (endpoint == "/wrong-start")
        range_end = end - (endpoint == "/wrong-end")
        range_total = file_length + (endpoint == "/wrong-total")
        headers = {"Accept-Ranges": "bytes"}
        if endpoint != "/missing-range" and endpoint != "/no-range":
            headers["Content-Range"] = "bytes %d-%d/%d" % (
                range_start, range_end, range_total)
        if endpoint == "/encoded":
            headers["Content-Encoding"] = "gzip"

        declared_size = expected + (endpoint == "/oversize")
        if endpoint == "/delay-headers":
            time.sleep(0.3)
        self.answer(200 if endpoint == "/no-range" else 206,
                    size=declared_size, headers=headers)
        truncated = endpoint in {"/short", "/slow-short"} or (endpoint == "/quota-shrink" and start == 0) or (
            endpoint == "/recover-short" and attempt == 1)
        body_size = expected // 2 if truncated else declared_size
        remaining = body_size
        tag = query.get("tag", [""])[0]
        while remaining:
            size = min(remaining, len(CHUNK))
            if endpoint == "/capacity-cycle":
                upper = self.server.capacity_state(tag)["upper"]
                size = min(size, max(upper - start - self.bytes_sent, 0))
                if not size:
                    self.server.capacity_stopped(tag,
                        request_id=query.get("playback_prefetch_request", [None])[0],
                        file_index=7, range_start=start, range_end=end + 1,
                        next_offset=start + self.bytes_sent)
                    if query.get("delay_close") == ["1"]:
                        time.sleep(0.3)
                    break
            self.wfile.write(CHUNK[:size])
            self.wfile.flush()
            self.bytes_sent += size
            remaining -= size
            if endpoint == "/gated-growth" and self.bytes_sent == size:
                gate = self.server.events.with_name("hold-growing-target")
                if gate.exists():
                    self.server.record_gate(requestTarget=self.path, byteCount=self.bytes_sent)
                    # The test releases this owned gate only after all window
                    # updates, so scheduler delays cannot finish the first body.
                    while gate.exists():
                        time.sleep(0.005)
            if endpoint in {"/slow", "/slow-short", "/quota-shrink", "/capacity-cycle"}:
                time.sleep(0.005)
        if endpoint == "/recover-short" and attempt == 1 and "close_gate" in query:
            # The test acknowledges an actual delegate progress callback before
            # permitting this deliberately truncated response to close.
            name = query["close_gate"][0]
            if Path(name).name != name:
                raise ValueError("invalid fixture close gate")
            gate = self.server.events.with_name(name)
            self.server.record_gate(requestTarget=self.path, byteCount=self.bytes_sent)
            while gate.exists():
                time.sleep(0.005)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port-file", required=True, type=Path)
    parser.add_argument("--events", required=True, type=Path)
    args = parser.parse_args()
    if not args.port_file.is_absolute() or not args.events.is_absolute():
        parser.error("--port-file and --events must be absolute paths")
    server = FixtureServer(args.events)
    temporary = args.port_file.with_name(args.port_file.name + ".%d.tmp" % os.getpid())
    temporary.write_text(str(server.server_port), encoding="ascii")
    temporary.replace(args.port_file)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(
        target=server.shutdown, daemon=True).start())
    try:
        server.serve_forever(poll_interval=0.05)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
