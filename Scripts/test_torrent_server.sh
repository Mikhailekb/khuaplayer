#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-torrent-server.XXXXXX")"
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    for log in "$CHECK_DIR/fixture-stderr.log" "$CHECK_DIR/fixture-events.jsonl"; do
      if [ -s "$log" ]; then
        echo "==> Torrent protocol fixture diagnostics: $(basename "$log")" >&2
        tail -n 100 "$log" >&2
      fi
    done
  fi
  rm -rf "$CHECK_DIR"
  return "$status"
}
trap cleanup EXIT
# The production launcher discards worker stderr. Keep fixture diagnostics
# outside the Swift test's disposable worker directories so CI failures retain
# the child error and HTTP readiness/authentication sequence.
export KINOLET_TORRENT_FIXTURE_DIAGNOSTICS="$CHECK_DIR/fixture-events.jsonl"
python3 - "$CHECK_DIR/fixture-worker" "$ROOT/Scripts/tests/torrent_worker_fixture.py" \
  "$CHECK_DIR/fixture-stderr.log" <<'PY'
from pathlib import Path
import shlex
import sys

wrapper, fixture, log = map(Path, sys.argv[1:])
wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' -u '
                   + shlex.quote(str(fixture)) + ' "$@" 2>>' + shlex.quote(str(log)) + '\n')
wrapper.chmod(0o700)
print('Torrent fixture Python:', sys.version.split()[0], sys.executable, flush=True)
PY
python3 "$ROOT/Scripts/tests/torrent_fixture_startup.py" \
  "$ROOT/Scripts/tests/torrent_worker_fixture.py"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentModels.swift" \
  "$ROOT/Apps/Mac/UI/TorrentPreferences.swift" \
  "$ROOT/Apps/Mac/UI/TorrentServer.swift" \
  "$ROOT/Scripts/tests/torrent_server.swift" \
  -o "$CHECK_DIR/torrent-server-checks"
"$CHECK_DIR/torrent-server-checks" "$CHECK_DIR/fixture-worker"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Apps/Mac/UI/TorrentPreferences.swift" \
  "$ROOT/Scripts/tests/torrent_preferences.swift" \
  -o "$CHECK_DIR/torrent-preferences-checks"
"$CHECK_DIR/torrent-preferences-checks"
