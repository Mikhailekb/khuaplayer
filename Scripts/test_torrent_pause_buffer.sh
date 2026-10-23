#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-torrent-pause.XXXXXX")"
FIXTURE_PID=""
cleanup() {
  if [[ -n "$FIXTURE_PID" ]]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
  fi
  rm -rf "$CHECK_DIR"
}
trap cleanup EXIT
python3 "$ROOT/Scripts/tests/torrent_pause_buffer_fixture.py" \
  --port-file "$CHECK_DIR/port" --events "$CHECK_DIR/events.jsonl" \
  >"$CHECK_DIR/fixture.log" 2>&1 &
FIXTURE_PID=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -f "$CHECK_DIR/port" ]] && break
  kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$CHECK_DIR/fixture.log"; exit 1; }
  sleep 0.02
done
[[ -f "$CHECK_DIR/port" ]] || { cat "$CHECK_DIR/fixture.log"; exit 1; }
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentPauseBuffer.swift" \
  "$ROOT/Scripts/tests/torrent_pause_buffer.swift" \
  -o "$CHECK_DIR/torrent-pause-checks"
"$CHECK_DIR/torrent-pause-checks" "$(cat "$CHECK_DIR/port")" "$CHECK_DIR/events.jsonl"
[[ ! -s "$CHECK_DIR/fixture.log" ]] || { cat "$CHECK_DIR/fixture.log"; exit 1; }
