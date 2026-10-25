#!/usr/bin/env python3
"""Compile and run isolated native HTTP range checks against a loopback server."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.request import urlopen


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    include = Path(os.environ.get("FFMPEG_INCLUDE_DIR", "/opt/homebrew/include"))
    if not (include / "libavformat/avio.h").is_file():
        raise SystemExit("Set FFMPEG_INCLUDE_DIR to the FFmpeg public include directory.")
    with tempfile.TemporaryDirectory(prefix="khua-http-range-checks-") as temporary:
        executable = Path(temporary) / "http-range-io-checks"
        source = Path(os.environ.get("HTTP_RANGE_IO_SOURCE", root / "Modules/MediaCore/Core/HTTPRangeIO.mm")).resolve()
        subprocess.run(
            ["xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-fobjc-arc", "-pthread",
             "-idirafter", str(include), "-I", str(root / "Modules/MediaCore/Core"),
             str(source), str(Path(__file__).with_suffix(".mm")),
             "-framework", "Foundation", "-o", str(executable)],
            cwd=root, check=True,
        )
        server = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("http_range_server.py"))],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        try:
            assert server.stdout is not None
            startup = json.loads(server.stdout.readline())
            base_url = f"http://127.0.0.1:{startup['port']}"
            subprocess.run([str(executable), base_url], check=True, timeout=30)
            with urlopen(base_url + "/stats", timeout=2) as response:
                stats = json.load(response)
            if os.environ.get("HTTP_RANGE_STATS_OUTPUT"):
                Path(os.environ["HTTP_RANGE_STATS_OUTPUT"]).write_text(json.dumps(stats, indent=2) + "\n")
            # Assert server-observed requests independently of the client's own counters.
            if stats.get("/ok", {}).get("get", 0) < 2:
                raise SystemExit("Loopback server did not observe the expected range requests.")
            largest_range = max(entry["max_range"] for entry in stats.values())
            if not 0 < largest_range <= 256 * 1024:
                raise SystemExit(f"Client requested an unbounded HTTP range: {largest_range} bytes")
            if stats.get("/cache-interleaved", {}).get("get") != 3:
                raise SystemExit("Interleaved cached reads fetched a resident window again instead of reusing it.")
            if stats.get("/cache-lru", {}).get("get") != 11:
                raise SystemExit("Cache eviction did not retain exactly the eight most recently used windows.")
            expected_reads = {"/retry-once": 2, "/retry-twice": 3, "/retry-persistent": 3,
                              "/retry-cancel": 1, "/retry-reset": 2, "/retry-reset-changed": 2,
                              "/retry-total-changed": 2, "/changed-etag": 1, "/invalid-body": 1,
                              "/retry-slow": 3}
            for path, expected in expected_reads.items():
                requests = [r for r in stats[path]["requests"] if r["first"] == 16]
                assert len(requests) == expected, (path, requests, expected)
                assert all(r["count"] == 256 * 1024 for r in requests), (path, requests)
                assert all(r["if_range"] == '"fixture-v1"' for r in requests
                           if path.startswith("/retry-") or path == "/changed-etag"), (path, requests)
            for path in ["/not-found", "/forbidden", "/bad-origin", "/bad-total", "/bad-length", "/ignore-range"]:
                assert stats[path]["get"] == 1, (path, stats[path])
            assert 1 <= len([r for r in stats["/retry-deadline"]["requests"] if r["first"] == 16]) <= 2
            small = stats["/cache-small-block"]
            assert small["get"] == 14, small
            assert small["requested_counts"].count(1) == 1, small
            assert small["requested_counts"].count(32 * 1024) == 12, small
            assert small["requested_counts"].count(64 * 1024) == 1, small
            for path, bodies in {"/admission-mid": 2, "/admission-many": 5, "/admission-mixed": 7}.items():
                entry = stats[path]
                requests = [r for r in entry["requests"] if r["first"] == 16]
                assert len(requests) == bodies, (path, entry)
                assert all(r["count"] == 32 * 1024 and r["if_range"] == '\"fixture-v1\"' for r in requests), (path, entry)
                assert entry.get("not_preempted", 0) == 0, (path, entry)
                assert entry["disconnected"] == (1 if path == "/admission-mid" else 4), (path, entry)
            assert stats["/admission-probe"]["get"] == 1
            assert stats.get("/admission-cancel", {}).get("get", 0) == 0
            changed = [r for r in stats["/admission-entity-change"]["requests"] if r["first"] == 16]
            assert len(changed) == 2 and all(r["count"] == 256 * 1024 for r in changed), changed
            assert all(r["if_range"] == '\"fixture-v1\"' for r in changed), changed
            for path, expected in {"/conflict-default": 1, "/admission-conflict-plain": 1,
                                   "/admission-conflict-once": 2, "/admission-conflict-repeat": 3,
                                   "/admission-invalid-overbody": 1}.items():
                bodies = [r for r in stats[path]["requests"] if r["first"] == 16]
                assert len(bodies) == expected, (path, bodies)
            assert stats["/admission-conflict-repeat"]["conflicts_sent"] == 3
            print("Loopback server observed bounded requests.")
            print("Loopback observed 3 interleaved fetches, 11 bounded LRU fetches and exact bounded retry counts.")
        finally:
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    main()
