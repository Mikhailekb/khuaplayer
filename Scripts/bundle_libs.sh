#!/bin/bash
# Package the self-built libass, embed a deterministic build manifest, sign in
# a clean temporary directory, and fail closed on any incomplete bundle.
set -euo pipefail

APP="${1:?usage: bundle_libs.sh <path-to-Kinolet.app>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/build_common.sh
source "$ROOT/Scripts/lib/build_common.sh"

# This is the local-development packaging lane and always signs ad hoc. The
# Mac App Store lane never runs this bundler; Xcode owns its sandbox
# entitlements and distribution signature. A future Developer ID/notarization
# lane needs its own explicit, inside-out signing and validation flow.
SP_SIGN_ID="-"
SP_SIGN_OPTS=""

# A SIGKILL can stop a previous publication after the old app was moved to
# its durable backup. Recover that state before inspecting the app: in the
# interrupted state SOURCE_BIN is intentionally absent.
APP_PARENT="$(cd "$(dirname "$APP")" && pwd -P)"
APP="$APP_PARENT/$(basename "$APP")"
sp_recover_atomic_directory "$APP" "$APP_PARENT"

SOURCE_INFO="$APP/Contents/Info.plist"
[ -f "$SOURCE_INFO" ] || { echo "Main Info.plist not found: $SOURCE_INFO" >&2; exit 1; }
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SOURCE_INFO")"
case "$APP_EXECUTABLE" in
  ''|*/*) echo "Invalid CFBundleExecutable: $APP_EXECUTABLE" >&2; exit 1 ;;
esac
SOURCE_BIN="$APP/Contents/MacOS/$APP_EXECUTABLE"
LIBASS="$ROOT/ThirdParty/subtitles-min/lib/libass.9.dylib"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
LOCK="$ROOT/ThirdParty/deps.lock.json"
DAV1D_STAMP="$ROOT/ThirdParty/dav1d-min/.build-stamp.json"
SPEEX_STAMP="$ROOT/ThirdParty/speex-min/.build-stamp.json"
FFMPEG_STAMP="$ROOT/ThirdParty/ffmpeg-min/.build-stamp.json"
SUBTITLE_STAMP="$ROOT/ThirdParty/subtitles-min/.build-stamp.json"
SPARKLE_STAMP="$ROOT/ThirdParty/sparkle-min/.build-stamp.json"

[ -f "$SOURCE_BIN" ] || { echo "Main executable not found: $SOURCE_BIN" >&2; exit 1; }
[ -d "$SPARKLE_FRAMEWORK" ] || {
  echo "Sparkle.framework is missing from the direct-distribution build" >&2
  exit 1
}
[ -f "$LIBASS" ] || {
  echo "Self-built libass is missing; refusing a Homebrew fallback. Run Scripts/build_subtitle_libs.sh first." >&2
  exit 1
}
for stamp in "$DAV1D_STAMP" "$SPEEX_STAMP" "$FFMPEG_STAMP" "$SUBTITLE_STAMP" "$SPARKLE_STAMP"; do
  [ -f "$stamp" ] || { echo "Dependency build stamp is missing: $stamp" >&2; exit 1; }
done

# The self-built libass must have only Apple system dynamic dependencies. Its
# remaining subtitle dependencies are static by design.
if ! LIBASS_DEPS="$(otool -L "$LIBASS" 2>&1)"; then
  printf '%s\n' "$LIBASS_DEPS" >&2
  echo "Self-built libass is not a readable Mach-O; refusing to package it" >&2
  exit 1
fi
if printf '%s\n' "$LIBASS_DEPS" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local|/opt/X11'; then
  printf '%s\n' "$LIBASS_DEPS" >&2
  echo "Self-built libass has an external dynamic dependency; refusing to package it" >&2
  exit 1
fi

# Copy the unmodified Xcode product to a clean transaction directory first.
# Every Mach-O rewrite below is confined to this copy, so a packaging or
# verification failure leaves the caller's original app byte-for-byte intact.
CLEAN_DIR="$(mktemp -d)"
PUBLISH_DIR=""
cleanup() {
  rm -rf "$CLEAN_DIR"
  [ -z "$PUBLISH_DIR" ] || rm -rf "$PUBLISH_DIR"
}
trap cleanup EXIT
CLEAN_APP="$CLEAN_DIR/$(basename "$APP")"
ditto --norsrc --noextattr --noqtn "$APP" "$CLEAN_APP"
xattr -cr "$CLEAN_APP" 2>/dev/null || true
BIN="$CLEAN_APP/Contents/MacOS/$APP_EXECUTABLE"
FW="$CLEAN_APP/Contents/Frameworks"
MAIN_INFO="$CLEAN_APP/Contents/Info.plist"

# Kinolet has no inherited update service. This explicit opt-in plus an own
# feed/key pair is required before the clean, unsigned bundle gains SU keys.
# KHUA_* variables are intentionally ignored to prevent upstream configuration
# in a contributor's environment from changing the fork's update authority.
SPARKLE_FEED_URL="${KINOLET_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${KINOLET_SPARKLE_PUBLIC_ED_KEY:-}"
UPDATE_OPT_IN="${KINOLET_ENABLE_AUTOMATIC_UPDATES:-false}"
python3 - "$MAIN_INFO" "$UPDATE_OPT_IN" "$SPARKLE_FEED_URL" "$SPARKLE_PUBLIC_ED_KEY" <<'PYUPDATES'
import base64
from pathlib import Path
import plistlib
import sys
from urllib.parse import urlsplit

path = Path(sys.argv[1])
opt_in, feed, key = sys.argv[2:]
if opt_in not in ('true', 'false'):
    raise SystemExit('KINOLET_ENABLE_AUTOMATIC_UPDATES must be true or false')
if bool(feed) != bool(key):
    raise SystemExit('KINOLET_SPARKLE_FEED_URL and KINOLET_SPARKLE_PUBLIC_ED_KEY must be supplied together')
if feed:
    try:
        url = urlsplit(feed)
        host = (url.hostname or '').lower().rstrip('.')
        url.port
    except ValueError:
        raise SystemExit('invalid Kinolet update feed URL')
    if url.scheme != 'https' or not host or url.username or url.password or url.fragment:
        raise SystemExit('the Kinolet update feed must be an HTTPS URL without credentials or a fragment')
    if host == 'khua.app' or host.endswith('.khua.app'):
        raise SystemExit('the upstream Khua update feed cannot be used by Kinolet')
    if key == 'd8nyI3ZvaY4fTRHzcLYyygiRagGoGRdObweyoAARQ+0=':
        raise SystemExit('the upstream Khua update key cannot be used by Kinolet')
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid_key = False
    if not valid_key:
        raise SystemExit('the Kinolet update public key must encode a 32-byte Ed25519 key')
if opt_in == 'true' and not feed:
    raise SystemExit('automatic updates require an explicitly configured Kinolet feed and public key')
with path.open('rb') as handle:
    info = plistlib.load(handle)
for name in ('SUFeedURL', 'SUPublicEDKey', 'SUEnableAutomaticChecks', 'SPUpdateUsageEnabled',
             'SUEnableSystemProfiling', 'SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed'):
    info.pop(name, None)
info['SPEnableDistributionUpdates'] = opt_in == 'true'
if opt_in == 'true':
    info.update(SUFeedURL=feed, SUPublicEDKey=key, SUEnableAutomaticChecks=True,
                SUEnableSystemProfiling=False, SUVerifyUpdateBeforeExtraction=True,
                SURequireSignedFeed=True)
with path.open('wb') as handle:
    plistlib.dump(info, handle, fmt=plistlib.FMT_XML, sort_keys=False)
PYUPDATES

# The fork does not collect update usage statistics. A custom update service
# does not implicitly opt a distributor into the original service's analytics.
cp "$ROOT/Apps/Mac/Resources/PrivacyInfo.xcprivacy" \
   "$CLEAN_APP/Contents/Resources/PrivacyInfo.xcprivacy"

# Assemble loose dylibs from empty so stale libraries cannot survive a
# rebuild. Xcode-embedded frameworks (KhuaPlayerMediaCore) are kept: the
# source app copy is a fresh build product, so they cannot be stale.
mkdir -p "$FW"
find "$FW" -maxdepth 1 -type f -delete
cp "$LIBASS" "$FW/libass.9.dylib"
chmod u+w "$FW/libass.9.dylib"
install_name_tool -id "@rpath/libass.9.dylib" "$FW/libass.9.dylib"
BIN_RPATHS="$(otool -l "$BIN" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  ')"
case "$BIN_RPATHS" in
  *'@executable_path/../Frameworks'*) ;;
  *) install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" ;;
esac

# Sign every nested Mach-O before creating the manifest. The outer app signing
# happens afterwards and does not mutate these recorded artifact bytes.
# App extensions are excluded here: signing an .appex executable as a bare
# Mach-O strips its entitlements and breaks the nested-bundle seal, so they
# get a proper bundle-level signature below instead.
while IFS= read -r -d '' candidate; do
  [ "$candidate" = "$BIN" ] && continue
  case "$candidate" in
    "$CLEAN_APP/Contents/PlugIns/"*) continue ;;
    *.framework/*) continue ;; # frameworks get bundle-level signatures below
  esac
  if /usr/bin/file -b "$candidate" | grep -q 'Mach-O'; then
    codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force "$candidate"
  fi
done < <(find "$CLEAN_APP/Contents" -type f -print0)

# Sign embedded frameworks as whole bundles (inside-out: before the appex
# that links them and before the outer app).
for framework in "$FW"/*.framework; do
  [ -e "$framework" ] || continue
  if codesign --verify --strict "$framework" >/dev/null 2>&1; then
    continue
  fi
  codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force "$framework"
done

# Sign nested app extensions as whole bundles with their entitlements (the
# sandbox entitlement is mandatory for extension processes). A bundle that
# already carries a valid signature (signed build lane) is left untouched.
for appex in "$CLEAN_APP/Contents/PlugIns"/*.appex; do
  [ -e "$appex" ] || continue
  if codesign --verify --strict "$appex" >/dev/null 2>&1; then
    continue
  fi
  APPEX_EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$appex/Contents/Info.plist")"
  APPEX_EXEC="$appex/Contents/MacOS/$APPEX_EXEC_NAME"
  # Inside-out: nested dylibs (e.g. Xcode's Debug preview split) first, the
  # bundle-level signature (which covers the main executable) last.
  while IFS= read -r -d '' candidate; do
    [ "$candidate" = "$APPEX_EXEC" ] && continue
    if /usr/bin/file -b "$candidate" | grep -q 'Mach-O'; then
      codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force "$candidate"
    fi
  done < <(find "$appex/Contents" -type f -print0)
  APPEX_ENTITLEMENTS="$ROOT/Apps/Mac/QuickLook/$(basename "$appex" .appex).entitlements"
  if [ -f "$APPEX_ENTITLEMENTS" ]; then
    codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force --entitlements "$APPEX_ENTITLEMENTS" "$appex"
  else
    codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force "$appex"
  fi
done

python3 "$ROOT/Scripts/lib/build_manifest.py" write \
  --app "$CLEAN_APP" \
  --lock "$LOCK" \
  --stamp "dav1d=$DAV1D_STAMP" \
  --stamp "speex=$SPEEX_STAMP" \
  --stamp "ffmpeg=$FFMPEG_STAMP" \
  --stamp "subtitles=$SUBTITLE_STAMP" \
  --stamp "sparkle=$SPARKLE_STAMP"

# Debug/Release host apps are intentionally unsandboxed. Do not pass the main
# app's sandbox entitlements here; AppStore archives apply them in Xcode and do
# not contain this bundler's BuildManifest.json.
codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force "$CLEAN_APP"
"$ROOT/Scripts/verify_app_bundle.sh" "$CLEAN_APP"

# Stage publication beside the target, then use the same serialized,
# crash-recoverable rename transaction as third-party dependency publication.
PUBLISH_DIR="$(mktemp -d "$APP_PARENT/.kinolet-publish.XXXXXX")"
PUBLISH_APP="$PUBLISH_DIR/$(basename "$APP")"
ditto "$CLEAN_APP" "$PUBLISH_APP"
sp_atomic_replace_directory "$PUBLISH_APP" "$APP" "$APP_PARENT"
rm -rf "$PUBLISH_DIR"
PUBLISH_DIR=""
echo "==> Complete: $APP"
