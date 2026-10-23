#!/bin/bash
# Validate packaged architecture, minos, signatures, Mach-O closure, shaders,
# third-party notice bytes, and the embedded deterministic BuildManifest.json.
# Never launches the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: verify_app_bundle.sh <path-to-Kinolet.app>}"
LOCK="$ROOT/ThirdParty/deps.lock.json"
STAMPS=(
  --stamp "dav1d=$ROOT/ThirdParty/dav1d-min/.build-stamp.json"
  --stamp "speex=$ROOT/ThirdParty/speex-min/.build-stamp.json"
  --stamp "ffmpeg=$ROOT/ThirdParty/ffmpeg-min/.build-stamp.json"
  --stamp "subtitles=$ROOT/ThirdParty/subtitles-min/.build-stamp.json"
  --stamp "sparkle=$ROOT/ThirdParty/sparkle-min/.build-stamp.json"
)

python3 "$ROOT/Scripts/lib/verify_app_bundle.py" \
  --app "$APP" \
  --lock "$LOCK" \
  --licenses "$ROOT/ThirdParty/Licenses" \
  "${STAMPS[@]}"
python3 "$ROOT/Scripts/verify_public_surface.py" --app "$APP"
echo "==> Bundle verification passed: $APP"
