#!/bin/bash
# Compile and inspect the AppStore configuration without signing credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: Scripts/smoke_app_store_unsigned.sh \
  [--archive-path PATH] \
  [--derived-data-path PATH]

Builds the AppStore configuration with Xcode's code-signing phases fully
disabled. This is a compile/package smoke test for CI; it is not a
distributable App Store archive. Relative output paths are resolved from the
repository root.
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

absolute_output_path() {
  local requested="$1"
  local candidate
  local parent

  case "$requested" in
    /*) candidate="$requested" ;;
    *) candidate="$ROOT/$requested" ;;
  esac
  parent="$(dirname "$candidate")"
  /bin/mkdir -p "$parent"
  parent="$(cd "$parent" && pwd -P)"
  printf '%s/%s\n' "$parent" "$(basename "$candidate")"
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || \
    die "missing $key in $plist"
}

assert_equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  [ "$actual" = "$expected" ] || \
    die "$label mismatch: expected '$expected', got '$actual'"
}

ARCHIVE_PATH=".build/AppStoreSmoke/Kinolet.xcarchive"
DERIVED_DATA_PATH=".build/AppStoreSmoke/DerivedData"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive-path)
      require_argument "$@"
      ARCHIVE_PATH="$2"
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

case "$ARCHIVE_PATH" in
  *.xcarchive) ;;
  *) die "--archive-path must end in .xcarchive" ;;
esac

ARCHIVE_PATH="$(absolute_output_path "$ARCHIVE_PATH")"
DERIVED_DATA_PATH="$(absolute_output_path "$DERIVED_DATA_PATH")"
[ ! -e "$ARCHIVE_PATH" ] || \
  die "archive path already exists; move it aside or choose a new path: $ARCHIVE_PATH"

# Xcode's archive action always registers its installation product. Remove only
# the generated archive paths on exit so repeated smoke tests stay invisible to
# Quick Look and LaunchServices.
unregister_archive_products() {
  local app
  local lsregister
  lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  for app in \
    "$DERIVED_DATA_PATH/Build/Intermediates.noindex/ArchiveIntermediates/KhuaPlayer/InstallationBuildProductsLocation/Applications/Kinolet.app" \
    "$ARCHIVE_PATH/Products/Applications/Kinolet.app"; do
    pluginkit -r "$app/Contents/PlugIns/KhuaPlayerQuickLook.appex" 2>/dev/null || true
    "$lsregister" -u "$app" 2>/dev/null || true
  done
}
trap unregister_archive_products EXIT

XCODEGEN_BIN="${XCODEGEN:-/opt/homebrew/bin/xcodegen}"
if [ ! -x "$XCODEGEN_BIN" ]; then
  XCODEGEN_BIN="$(command -v xcodegen 2>/dev/null || true)"
fi
[ -n "$XCODEGEN_BIN" ] && [ -x "$XCODEGEN_BIN" ] || \
  die "xcodegen is required"

echo "==> Building pinned FFmpeg and dav1d dependencies"
"$ROOT/Scripts/build_ffmpeg_min.sh"
echo "==> Building pinned subtitle dependencies"
"$ROOT/Scripts/build_subtitle_libs.sh"
echo "==> Generating Apps/Mac/KhuaPlayer.xcodeproj"
KHUA_ENABLE_SPARKLE=false \
KINOLET_ENABLE_AUTOMATIC_UPDATES=false \
KINOLET_SPARKLE_FEED_URL= \
KINOLET_SPARKLE_PUBLIC_ED_KEY= \
  "$XCODEGEN_BIN" generate --spec Apps/Mac/project.yml --project Apps/Mac --quiet

echo "==> Archiving unsigned AppStore configuration"
/usr/bin/xcodebuild \
  -project "$ROOT/Apps/Mac/KhuaPlayer.xcodeproj" \
  -scheme KhuaPlayer \
  -configuration AppStore \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  EXPANDED_CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  KHUA_DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  archive

# Nothing below this point writes to, signs, or otherwise mutates the archive.
APP="$ARCHIVE_PATH/Products/Applications/Kinolet.app"
APPEX="$APP/Contents/PlugIns/KhuaPlayerQuickLook.appex"
FRAMEWORK="$APP/Contents/Frameworks/KhuaPlayerMediaCore.framework"
LIBASS="$APP/Contents/Frameworks/libass.9.dylib"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
MAIN_PRIVACY="$APP/Contents/Resources/PrivacyInfo.xcprivacy"
APPEX_PRIVACY="$APPEX/Contents/Resources/PrivacyInfo.xcprivacy"

[ -d "$APP" ] || die "archive has no Kinolet.app: $APP"
[ -d "$APPEX" ] || die "Quick Look extension is missing: $APPEX"
[ -d "$FRAMEWORK" ] || die "media framework is missing: $FRAMEWORK"
[ -f "$LIBASS" ] || die "bundled libass is missing: $LIBASS"
[ ! -e "$SPARKLE" ] || die "App Store archive must not contain Sparkle: $SPARKLE"
for update_key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks \
                  SUEnableSystemProfiling \
                  SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
  if /usr/libexec/PlistBuddy -c "Print :$update_key" \
       "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    die "App Store Info.plist must not contain $update_key"
  fi
done

for privacy_manifest in "$MAIN_PRIVACY" "$APPEX_PRIVACY"; do
  [ -f "$privacy_manifest" ] || \
    die "PrivacyInfo.xcprivacy is missing: $privacy_manifest"
  /usr/bin/plutil -lint "$privacy_manifest" >/dev/null || \
    die "invalid privacy manifest: $privacy_manifest"
done

MAIN_ID="$(plist_value "$APP/Contents/Info.plist" CFBundleIdentifier)"
assert_equal "main bundle name" \
  "$(plist_value "$APP/Contents/Info.plist" CFBundleName)" "Кинолёт"
assert_equal "main display name" \
  "$(plist_value "$APP/Contents/Info.plist" CFBundleDisplayName)" "Кинолёт"
assert_equal "main executable name" \
  "$(plist_value "$APP/Contents/Info.plist" CFBundleExecutable)" "Kinolet"
assert_equal "Quick Look display name" \
  "$(plist_value "$APPEX/Contents/Info.plist" CFBundleDisplayName)" "Кинолёт Quick Look"
assert_equal "Quick Look bundle identifier" \
  "$(plist_value "$APPEX/Contents/Info.plist" CFBundleIdentifier)" \
  "$MAIN_ID.QuickLook"
assert_equal "media framework bundle identifier" \
  "$(plist_value "$FRAMEWORK/Resources/Info.plist" CFBundleIdentifier)" \
  "$MAIN_ID.MediaCore"

FOUND_MANIFEST="$(/usr/bin/find "$ARCHIVE_PATH" -name BuildManifest.json -print -quit)"
[ -z "$FOUND_MANIFEST" ] || \
  die "unsigned App Store archive must not contain BuildManifest.json: $FOUND_MANIFEST"

# The arm64 linker can attach a linker-signed ad-hoc CodeDirectory even when
# Xcode signing is disabled. A provisioning profile or resource signature
# directory, however, would mean a signing phase unexpectedly ran.
FOUND_PROFILE="$(/usr/bin/find "$ARCHIVE_PATH" -name embedded.provisionprofile -print -quit)"
[ -z "$FOUND_PROFILE" ] || \
  die "unsigned smoke archive contains a provisioning profile: $FOUND_PROFILE"
FOUND_RESOURCE_SIGNATURE="$(/usr/bin/find "$ARCHIVE_PATH" -type d -name _CodeSignature -print -quit)"
[ -z "$FOUND_RESOURCE_SIGNATURE" ] || \
  die "unsigned smoke archive contains a resource signature: $FOUND_RESOURCE_SIGNATURE"

"$ROOT/Scripts/lib/verify_app_store_archive.sh" \
  --archive-path "$ARCHIVE_PATH" \
  --runtime-boundary-only

python3 "$ROOT/Scripts/lib/verify_app_bundle.py" \
  --app "$APP" \
  --lock "$ROOT/ThirdParty/deps.lock.json" \
  --stamp "dav1d=$ROOT/ThirdParty/dav1d-min/.build-stamp.json" \
  --stamp "speex=$ROOT/ThirdParty/speex-min/.build-stamp.json" \
  --stamp "ffmpeg=$ROOT/ThirdParty/ffmpeg-min/.build-stamp.json" \
  --stamp "subtitles=$ROOT/ThirdParty/subtitles-min/.build-stamp.json" \
  --skip-codesign \
  --skip-manifest

echo "==> Unsigned AppStore smoke test passed: $ARCHIVE_PATH"
