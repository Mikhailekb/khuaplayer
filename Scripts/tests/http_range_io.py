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
        subprocess.run(
            ["xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-fobjc-arc", "-pthread",
             "-idirafter", str(include), "-I", str(root / "Modules/MediaCore/Core"),
             str(root / "Modules/MediaCore/Core/HTTPRangeIO.mm"), str(Path(__file__).with_suffix(".mm")),
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
            # Assert server-observed requests independently of the client's own counters.
            if stats.get("/ok", {}).get("get", 0) < 2:
                raise SystemExit("Loopback server did not observe the expected range requests.")
            largest_range = max(entry["max_range"] for entry in stats.values())
            if not 0 < largest_range <= 256 * 1024:
                raise SystemExit(f"Client requested an unbounded HTTP range: {largest_range} bytes")
            print("Loopback server observed bounded requests.")
        finally:
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    main()
