#!/bin/bash
# Build, package, sign, and transport-check a Developer ID release without
# contacting Apple's Notary service. Notarize and staple the app first, then
# package and notarize the final DMG containing that stapled app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: Scripts/archive_developer_id.sh \
  --identity "Developer ID Application: Name (TEAM_ID)" \
  --team-id TEAM_ID \
  --bundle-id FINAL_BUNDLE_ID \
  --marketing-version VERSION \
  --build-number BUILD \
  --output-dir PATH \
  [--derived-data-path PATH]

The output directory must not exist. Automatic updates are disabled by default.
To enable an own channel, set KINOLET_ENABLE_AUTOMATIC_UPDATES=true and supply
KINOLET_SPARKLE_FEED_URL plus KINOLET_SPARKLE_PUBLIC_ED_KEY together.
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

require_argument() {
  [ "$#" -ge 2 ] || die "missing value for $1"
  [ -n "$2" ] || die "empty value for $1"
}

absolute_path() {
  local requested="$1"
  local candidate
  local parent

  case "$requested" in
    /*) candidate="$requested" ;;
    *) candidate="$ROOT/$requested" ;;
  esac
  parent="$(dirname "$candidate")"
  mkdir -p "$parent"
  parent="$(cd "$parent" && pwd -P)"
  printf '%s/%s\n' "$parent" "$(basename "$candidate")"
}

IDENTITY=""
TEAM_ID=""
BUNDLE_ID=""
MARKETING_VERSION=""
BUILD_NUMBER=""
OUTPUT_DIR=""
DERIVED_DATA_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity)
      require_argument "$@"
      IDENTITY="$2"
      shift 2
      ;;
    --team-id)
      require_argument "$@"
      TEAM_ID="$2"
      shift 2
      ;;
    --bundle-id)
      require_argument "$@"
      BUNDLE_ID="$2"
      shift 2
      ;;
    --marketing-version)
      require_argument "$@"
      MARKETING_VERSION="$2"
      shift 2
      ;;
    --build-number)
      require_argument "$@"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --output-dir)
      require_argument "$@"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --derived-data-path)
      require_argument "$@"
      DERIVED_DATA_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$IDENTITY" ] || die "--identity is required"
[ -n "$TEAM_ID" ] || die "--team-id is required"
[ -n "$BUNDLE_ID" ] || die "--bundle-id is required"
[ -n "$MARKETING_VERSION" ] || die "--marketing-version is required"
[ -n "$BUILD_NUMBER" ] || die "--build-number is required"
[ -n "$OUTPUT_DIR" ] || die "--output-dir is required"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || \
  die "--team-id must be a 10-character Apple Team ID"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || \
  die "--bundle-id must be a concrete reverse-DNS identifier"
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
  die "--marketing-version must contain one to three numeric components"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || \
  die "--build-number must be a positive integer"

OUTPUT_DIR="$(absolute_path "$OUTPUT_DIR")"
[ ! -e "$OUTPUT_DIR" ] || \
  die "output directory already exists: $OUTPUT_DIR"
security find-identity -v -p codesigning | grep -Fq "$IDENTITY" || \
  die "code-signing identity is not available: $IDENTITY"

OUTPUT_PARENT="$(dirname "$OUTPUT_DIR")"
WORK_DIR="$(mktemp -d "$OUTPUT_PARENT/.khua-developer-id.XXXXXX")"
TRANSPORT_CHECK="$(mktemp -d)"
REMOVE_DERIVED_DATA=0
if [ -n "$DERIVED_DATA_PATH" ]; then
  DERIVED_DATA_PATH="$(absolute_path "$DERIVED_DATA_PATH")"
else
  DERIVED_DATA_PATH="$(mktemp -d "$OUTPUT_PARENT/.khua-derived-data.XXXXXX")"
  REMOVE_DERIVED_DATA=1
fi
SOURCE_APP="$DERIVED_DATA_PATH/Build/Products/Release/Kinolet.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cleanup() {
  rm -rf "$WORK_DIR" "$TRANSPORT_CHECK"
  pluginkit -r "$SOURCE_APP/Contents/PlugIns/KhuaPlayerQuickLook.appex" \
    >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$SOURCE_APP" >/dev/null 2>&1 || true
  if [ "$REMOVE_DERIVED_DATA" -eq 1 ]; then
    rm -rf "$DERIVED_DATA_PATH"
  fi
}
trap cleanup EXIT

XCODEGEN_BIN="${XCODEGEN:-/opt/homebrew/bin/xcodegen}"
if [ ! -x "$XCODEGEN_BIN" ]; then
  XCODEGEN_BIN="$(command -v xcodegen 2>/dev/null || true)"
fi
[ -n "$XCODEGEN_BIN" ] && [ -x "$XCODEGEN_BIN" ] || \
  die "xcodegen is required"

SPARKLE_FEED_URL="${KINOLET_SPARKLE_FEED_URL-$(plutil -extract feedUrl raw -o - "$ROOT/Distribution/sparkle.json")}"
SPARKLE_PUBLIC_ED_KEY="${KINOLET_SPARKLE_PUBLIC_ED_KEY-$(plutil -extract publicKey raw -o - "$ROOT/Distribution/sparkle.json")}"
if { [ -n "$SPARKLE_FEED_URL" ] && [ -z "$SPARKLE_PUBLIC_ED_KEY" ]; } ||
   { [ -z "$SPARKLE_FEED_URL" ] && [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; }; then
  die "KINOLET_SPARKLE_FEED_URL and KINOLET_SPARKLE_PUBLIC_ED_KEY must be supplied together"
fi

echo "==> Building pinned FFmpeg and dav1d dependencies"
"$ROOT/Scripts/build_ffmpeg_min.sh"
echo "==> Building pinned subtitle dependencies"
"$ROOT/Scripts/build_subtitle_libs.sh"
echo "==> Building pinned Sparkle framework and release tools"
"$ROOT/Scripts/build_sparkle.sh"
echo "==> Generating direct-distribution Xcode project"
KHUA_ENABLE_SPARKLE=true \
KINOLET_SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
KINOLET_SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  "$XCODEGEN_BIN" generate --spec Apps/Mac/project.yml --project Apps/Mac --quiet

echo "==> Building unsigned Release product"
xcodebuild \
  -project "$ROOT/Apps/Mac/KhuaPlayer.xcodeproj" \
  -scheme KhuaPlayer \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  KHUA_BUNDLE_ID="$BUNDLE_ID" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  REGISTER_WITH_LAUNCH_SERVICES=NO \
  build

[ -d "$SOURCE_APP" ] || die "Release build product is missing: $SOURCE_APP"
KINOLET_SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
KINOLET_SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  "$ROOT/Scripts/bundle_libs.sh" "$SOURCE_APP"

APP="$WORK_DIR/Kinolet.app"
ditto --norsrc --noextattr --noqtn "$SOURCE_APP" "$APP"
xattr -cr "$APP" 2>/dev/null || true

# Keep symbol files beside the release artifact, never inside the notarization
# ZIP. Refuse mismatched dSYMs so a published crash can always be symbolicated.
DSYMS_DIR="$WORK_DIR/dSYMs"
mkdir -p "$DSYMS_DIR"
for dsym_name in \
  Kinolet.app.dSYM \
  KhuaPlayerMediaCore.framework.dSYM \
  KhuaPlayerCaptionsUI.framework.dSYM \
  KhuaPlayerQuickLook.appex.dSYM; do
  DSYM_SOURCE="$DERIVED_DATA_PATH/Build/Products/Release/$dsym_name"
  [ -d "$DSYM_SOURCE" ] || die "release dSYM is missing: $DSYM_SOURCE"
  ditto --norsrc --noextattr --noqtn "$DSYM_SOURCE" "$DSYMS_DIR/$dsym_name"
done

uuid_for() {
  dwarfdump --uuid "$1" | awk 'NR == 1 { print $2 }'
}
[ "$(uuid_for "$APP/Contents/MacOS/Kinolet")" = \
  "$(uuid_for "$DSYMS_DIR/Kinolet.app.dSYM")" ] || \
  die "main app dSYM UUID does not match"
[ "$(uuid_for "$APP/Contents/Frameworks/KhuaPlayerMediaCore.framework/Versions/A/KhuaPlayerMediaCore")" = \
  "$(uuid_for "$DSYMS_DIR/KhuaPlayerMediaCore.framework.dSYM")" ] || \
  die "media framework dSYM UUID does not match"
[ "$(uuid_for "$APP/Contents/Frameworks/KhuaPlayerCaptionsUI.framework/Versions/A/KhuaPlayerCaptionsUI")" = \
  "$(uuid_for "$DSYMS_DIR/KhuaPlayerCaptionsUI.framework.dSYM")" ] || \
  die "caption UI framework dSYM UUID does not match"
[ "$(uuid_for "$APP/Contents/PlugIns/KhuaPlayerQuickLook.appex/Contents/MacOS/KhuaPlayerQuickLook")" = \
  "$(uuid_for "$DSYMS_DIR/KhuaPlayerQuickLook.appex.dSYM")" ] || \
  die "Quick Look dSYM UUID does not match"

MAIN_INFO="$APP/Contents/Info.plist"
APPEX="$APP/Contents/PlugIns/KhuaPlayerQuickLook.appex"
APPEX_INFO="$APPEX/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MAIN_INFO")" = \
  "$BUNDLE_ID" ] || die "Xcode did not apply the requested bundle identifier"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MAIN_INFO")" = \
  "$MARKETING_VERSION" ] || die "Xcode did not apply the requested marketing version"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MAIN_INFO")" = \
  "$BUILD_NUMBER" ] || die "Xcode did not apply the requested build number"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPEX_INFO")" = \
  "$BUNDLE_ID.QuickLook" ] || die "Quick Look bundle identifier mismatch"

sign_code() {
  local code="${!#}"
  echo "==> Signing: ${code#"$APP/"}"
  codesign --sign "$IDENTITY" --force --options runtime --timestamp "$@"
}

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE/Versions/B"
MEDIA_CORE="$APP/Contents/Frameworks/KhuaPlayerMediaCore.framework"
CAPTIONS_UI="$APP/Contents/Frameworks/KhuaPlayerCaptionsUI.framework"
LIBASS="$APP/Contents/Frameworks/libass.9.dylib"

sign_code "$SPARKLE_VERSION/Autoupdate"
sign_code "$SPARKLE_VERSION/Updater.app"
sign_code "$SPARKLE"
sign_code "$LIBASS"
sign_code "$MEDIA_CORE"
sign_code "$CAPTIONS_UI"
sign_code --entitlements \
  "$ROOT/Apps/Mac/QuickLook/KhuaPlayerQuickLook.entitlements" "$APPEX"

# The manifest hashes framework signatures and CodeResources. Recreate it only
# after every nested component is final, then seal the host app last.
python3 "$ROOT/Scripts/lib/build_manifest.py" write \
  --app "$APP" \
  --lock "$ROOT/ThirdParty/deps.lock.json" \
  --stamp "dav1d=$ROOT/ThirdParty/dav1d-min/.build-stamp.json" \
  --stamp "speex=$ROOT/ThirdParty/speex-min/.build-stamp.json" \
  --stamp "ffmpeg=$ROOT/ThirdParty/ffmpeg-min/.build-stamp.json" \
  --stamp "subtitles=$ROOT/ThirdParty/subtitles-min/.build-stamp.json" \
  --stamp "sparkle=$ROOT/ThirdParty/sparkle-min/.build-stamp.json"
sign_code "$APP"

"$ROOT/Scripts/verify_app_bundle.sh" "$APP"
"$ROOT/Scripts/lib/verify_developer_id_app.sh" \
  --app "$APP" \
  --team-id "$TEAM_ID" \
  --bundle-id "$BUNDLE_ID"

SUBMISSION_ZIP="$WORK_DIR/Kinolet-notarization.zip"
ditto -c -k --keepParent "$APP" "$SUBMISSION_ZIP"
(cd "$WORK_DIR" && \
  shasum -a 256 Kinolet-notarization.zip >Kinolet-notarization.zip.sha256)
ditto -x -k "$SUBMISSION_ZIP" "$TRANSPORT_CHECK"
"$ROOT/Scripts/lib/verify_developer_id_app.sh" \
  --app "$TRANSPORT_CHECK/Kinolet.app" \
  --team-id "$TEAM_ID" \
  --bundle-id "$BUNDLE_ID"

mv "$WORK_DIR" "$OUTPUT_DIR"
WORK_DIR=""
echo "==> Developer ID archive ready: $OUTPUT_DIR/Kinolet-notarization.zip"
echo "==> Matching dSYMs: $OUTPUT_DIR/dSYMs"
echo "==> Notarize and staple the app with Scripts/notarize_developer_id.sh"
echo "==> Then package the stapled app with Scripts/create_developer_id_dmg.sh"
