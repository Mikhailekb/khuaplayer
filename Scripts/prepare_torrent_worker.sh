#!/bin/bash
# Build or reuse the verified source-plus-patch torrent worker.
set -euo pipefail
TORRENT_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$TORRENT_REPO_ROOT/Scripts/build_torrent_worker.py" "$@"
