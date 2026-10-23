#!/bin/bash
# Build dependencies, generate the Xcode project, archive, then verify read-only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: Scripts/archive_app_store.sh \
  --team-id TEAM_ID \
  --bundle-id FINAL_BUNDLE_ID \
  --marketing-version VERSION \
  --build-number BUILD \
  [--archive-path PATH] \
  [--derived-data-path PATH] \
  [--allow-provisioning-updates]

The four release identity/version values are mandatory and have no defaults.
Relative output paths are resolved from the repository root.
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

TEAM_ID=""
BUNDLE_ID=""
MARKETING_VERSION=""
BUILD_NUMBER=""
ARCHIVE_PATH=".build/AppStore/Kinolet.xcarchive"
DERIVED_DATA_PATH=".build/AppStore/DerivedData"
ALLOW_PROVISIONING_UPDATES=0

while [ "$#" -gt 0 ]; do
  case "$1" in
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
    --allow-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=1
      shift
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

[ -n "$TEAM_ID" ] || die "--team-id is required"
[ -n "$BUNDLE_ID" ] || die "--bundle-id is required"
[ -n "$MARKETING_VERSION" ] || die "--marketing-version is required"
[ -n "$BUILD_NUMBER" ] || die "--build-number is required"

[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || \
  die "--team-id must be a 10-character Apple Team ID"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || \
  die "--bundle-id must be a concrete reverse-DNS identifier"
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
  die "--marketing-version must contain one to three numeric components"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || \
  die "--build-number must be a positive integer"

case "$ARCHIVE_PATH" in
  *.xcarchive) ;;
  *) die "--archive-path must end in .xcarchive" ;;
esac

ARCHIVE_PATH="$(absolute_output_path "$ARCHIVE_PATH")"
DERIVED_DATA_PATH="$(absolute_output_path "$DERIVED_DATA_PATH")"
[ ! -e "$ARCHIVE_PATH" ] || \
  die "archive path already exists; move it aside or choose a new path: $ARCHIVE_PATH"

# Xcode's archive action registers its installation product even when
# REGISTER_WITH_LAUNCH_SERVICES is disabled. Remove only those archive paths on
# exit so signing failures and successful archives cannot pollute Quick Look.
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

XCODEBUILD_ARGS=(
  -project "$ROOT/Apps/Mac/KhuaPlayer.xcodeproj"
  -scheme KhuaPlayer
  -configuration AppStore
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA_PATH"
  KHUA_DEVELOPMENT_TEAM="$TEAM_ID"
  DEVELOPMENT_TEAM="$TEAM_ID"
  KHUA_BUNDLE_ID="$BUNDLE_ID"
  MARKETING_VERSION="$MARKETING_VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  CODE_SIGN_STYLE=Automatic
  CODE_SIGN_IDENTITY="Apple Distribution"
)
if [ "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]; then
  XCODEBUILD_ARGS+=( -allowProvisioningUpdates )
fi
XCODEBUILD_ARGS+=( archive )

echo "==> Archiving App Store build"
/usr/bin/xcodebuild "${XCODEBUILD_ARGS[@]}"

# Nothing below this point may modify, re-sign, or add files to the archive.
echo "==> Verifying archive without modifying it"
"$ROOT/Scripts/lib/verify_app_store_archive.sh" \
  --archive-path "$ARCHIVE_PATH" \
  --team-id "$TEAM_ID" \
  --bundle-id "$BUNDLE_ID" \
  --marketing-version "$MARKETING_VERSION" \
  --build-number "$BUILD_NUMBER"

echo "==> App Store archive ready: $ARCHIVE_PATH"
