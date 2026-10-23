#!/bin/bash
# Build and run Kinolet, optionally opening a media file.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build.sh Debug

APP=.build/Build/Products/Debug/Kinolet.app
if [ $# -ge 1 ]; then
    # Deliver a normal macOS document-open event so a sandboxed build receives
    # the user-selected file grant instead of treating the path as a CLI flag.
    open -a "$APP" "$1"
else
    open -a "$APP"
fi
