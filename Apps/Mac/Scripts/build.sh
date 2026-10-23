#!/bin/bash
# Kinolet Mac product build. Usage: Apps/Mac/Scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/../../.."

CONFIG="${1:-Debug}"
case "$CONFIG" in
  Debug|Release) ;;
  AppStore)
    echo "error: AppStore builds must use Scripts/smoke_app_store_unsigned.sh or Scripts/archive_app_store.sh" >&2
    exit 2
    ;;
  *)
    echo "error: configuration must be Debug or Release" >&2
    exit 2
    ;;
esac
XCODEGEN="${XCODEGEN:-/opt/homebrew/bin/xcodegen}"
[ -x "$XCODEGEN" ] || XCODEGEN="$(command -v xcodegen 2>/dev/null || true)"
[ -n "$XCODEGEN" ] && [ -x "$XCODEGEN" ] || { echo "xcodegen is required" >&2; exit 1; }

# Every dependency recipe validates its lock, recipe inputs, patches, and
# toolchain. A matching stamp is a cheap no-op; existence alone is never enough.
# The FFmpeg recipe ensures and fingerprints dav1d and Speex itself. Avoid
# repeating their toolchain and recipe probes here without relying on mtimes
# for SDK, compiler, or patch changes.
echo "==> Verifying/building minimal static FFmpeg (including dav1d and Speex)"
./Scripts/build_ffmpeg_min.sh
echo "==> Verifying/building the self-contained subtitle stack"
./Scripts/build_subtitle_libs.sh
echo "==> Verifying/building Sparkle for optional direct-distribution updates"
./Scripts/build_sparkle.sh

SPARKLE_FEED_URL="${KINOLET_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${KINOLET_SPARKLE_PUBLIC_ED_KEY:-}"
if { [ -n "$SPARKLE_FEED_URL" ] && [ -z "$SPARKLE_PUBLIC_ED_KEY" ]; } ||
   { [ -z "$SPARKLE_FEED_URL" ] && [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; }; then
  echo "error: KINOLET_SPARKLE_FEED_URL and KINOLET_SPARKLE_PUBLIC_ED_KEY must be supplied together" >&2
  exit 2
fi
export KHUA_ENABLE_SPARKLE=true
export KINOLET_SPARKLE_FEED_URL="$SPARKLE_FEED_URL"
export KINOLET_SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"

echo "==> Generating the Xcode project (xcodegen)"
"$XCODEGEN" generate --spec Apps/Mac/project.yml --project Apps/Mac --quiet

echo "==> Building ($CONFIG)"
xcodebuild -project Apps/Mac/KhuaPlayer.xcodeproj \
           -scheme KhuaPlayer \
           -configuration "$CONFIG" \
           -derivedDataPath .build \
           REGISTER_WITH_LAUNCH_SERVICES=NO \
           build

APP=.build/Build/Products/$CONFIG/Kinolet.app

# Bundle libass and its dependency stack. FFmpeg is linked statically, so the
# resulting app is self-contained.
./Scripts/bundle_libs.sh "$APP"
python3 Scripts/verify_public_surface.py --app "$APP"

echo "==> Complete: $APP"

# Release builds are deployed to the repository root for direct use.
# The clean-room flow is necessary because File Provider can continuously
# restore FinderInfo in an iCloud-synced directory. Clear extended attributes
# and verify outside the synced volume before moving the app back.
# Debug builds are not deployed, preserving the root-level Release app.
if [ "$CONFIG" = "Release" ]; then
  # Two-stage deployment:
  #  1) Clear extended attributes and verify the signature in a clean directory
  #     under $TMPDIR, outside the iCloud volume. In-place cleanup races with
  #     File Provider restoring FinderInfo and therefore fails intermittently.
  #  2) Move the verified bundle into a staging directory on the repository
  #     volume, then use the same serialized, crash-recoverable atomic publish
  #     transaction as bundle_libs.sh. Verify the final path under its lock;
  #     retain and restore the previous app if final-path validation fails.
  # shellcheck source=Scripts/lib/build_common.sh
  source "$(pwd)/Scripts/lib/build_common.sh"
  ROOT_DIR="$(pwd -P)"
  verify_deployed_app() { codesign --verify --deep --strict "$1"; }
  sp_recover_atomic_directory "$ROOT_DIR/Kinolet.app" "$ROOT_DIR" verify_deployed_app
  CLEANROOM="$(mktemp -d)"
  DEPLOY_TMP="$(mktemp -d "$ROOT_DIR/.khuaplayer-deploy.XXXXXX")"
  trap 'rm -rf "$CLEANROOM" "$DEPLOY_TMP"' EXIT
  cp -R "$APP" "$CLEANROOM/"
  xattr -cr "$CLEANROOM/Kinolet.app"
  codesign --verify --strict "$CLEANROOM/Kinolet.app" || { echo "Signature verification failed before deployment"; exit 1; }
  mv "$CLEANROOM/Kinolet.app" "$DEPLOY_TMP/Kinolet.app"
  sp_atomic_replace_directory "$DEPLOY_TMP/Kinolet.app" "$ROOT_DIR/Kinolet.app" "$ROOT_DIR" verify_deployed_app
  rm -rf "$CLEANROOM" "$DEPLOY_TMP"
  trap - EXIT

  # Xcode build products and archive intermediates must not accumulate as
  # duplicate Quick Look registrations. Keep only the published root app.
  QL_IDENTIFIER="app.kinolet.player.QuickLook"
  QL_APPEX="$ROOT_DIR/Kinolet.app/Contents/PlugIns/KhuaPlayerQuickLook.appex"
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  registered_ql_paths() {
    pluginkit -m -A -D -vvv -i "$QL_IDENTIFIER" 2>/dev/null |
      sed -n 's/^[[:space:]]*Path = //p' | sort -u
  }

  remove_other_ql_copies() {
    local registered_appex registered_app
    while IFS= read -r registered_appex; do
      [ -n "$registered_appex" ] || continue
      [ "$registered_appex" = "$QL_APPEX" ] && continue
      pluginkit -r "$registered_appex" 2>/dev/null || true
      registered_app="${registered_appex%%/Contents/PlugIns/*}"
      if [ "$registered_app" != "$registered_appex" ]; then
        "$LSREGISTER" -u "$registered_app" 2>/dev/null || true
      fi
    done < <(registered_ql_paths)
  }

  register_release_app() {
    "$LSREGISTER" -f -R -trusted "$ROOT_DIR/Kinolet.app"
    pluginkit -a "$QL_APPEX"
    pluginkit -e use -i "$QL_IDENTIFIER" 2>/dev/null || true
  }

  # LaunchServices may asynchronously rediscover Xcode's build product after
  # xcodebuild exits. Prune and re-register twice, then require an exact result.
  remove_other_ql_copies
  register_release_app
  sleep 2
  remove_other_ql_copies
  register_release_app
  sleep 12
  remove_other_ql_copies
  register_release_app
  sleep 2
  REGISTERED_QL_PATHS="$(registered_ql_paths)"
  if [ "$REGISTERED_QL_PATHS" != "$QL_APPEX" ]; then
    echo "Quick Look registration assertion failed; registered paths:" >&2
    printf '%s\n' "$REGISTERED_QL_PATHS" >&2
    exit 1
  fi
  echo "==> Deployed: $ROOT_DIR/Kinolet.app"
fi
