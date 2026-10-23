#!/bin/bash
# Verify a signed direct-distribution disk image and the app it contains.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"

usage() {
  cat <<'EOF'
Usage: Scripts/lib/verify_developer_id_dmg.sh \
  --dmg PATH \
  --team-id TEAM_ID \
  [--bundle-id BUNDLE_ID] \
  [--source-app PATH]
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

DMG=""
TEAM_ID=""
BUNDLE_ID=""
SOURCE_APP=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dmg)
      require_argument "$@"
      DMG="$2"
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
    --source-app)
      require_argument "$@"
      SOURCE_APP="$2"
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

[ -n "$DMG" ] || die "--dmg is required"
[ -n "$TEAM_ID" ] || die "--team-id is required"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || \
  die "--team-id must be a 10-character Apple Team ID"
[ -f "$DMG" ] || die "disk image does not exist: $DMG"
DMG="$(cd "$(dirname "$DMG")" && pwd -P)/$(basename "$DMG")"

if [ -n "$SOURCE_APP" ]; then
  [ -d "$SOURCE_APP" ] || die "source app does not exist: $SOURCE_APP"
  SOURCE_APP="$(cd "$(dirname "$SOURCE_APP")" && pwd -P)/$(basename "$SOURCE_APP")"
fi

TMP="$(mktemp -d)"
MOUNT_POINT="$TMP/mount"
mkdir "$MOUNT_POINT"
ATTACHED=0
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cleanup() {
  if [ "$ATTACHED" -eq 1 ]; then
    pluginkit -r \
      "$MOUNT_POINT/Kinolet.app/Contents/PlugIns/KhuaPlayerQuickLook.appex" \
      >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$MOUNT_POINT/Kinolet.app" >/dev/null 2>&1 || true
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || \
      hdiutil detach "$MOUNT_POINT" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> Verifying disk image structure and signature"
IMAGE_INFO="$TMP/ImageInfo.plist"
hdiutil imageinfo -stdinpass -plist "$DMG" </dev/null >"$IMAGE_INFO"
plutil -lint "$IMAGE_INFO" >/dev/null || \
  die "hdiutil returned invalid disk image metadata"
[ "$(plutil -extract Format raw -o - "$IMAGE_INFO")" = "UDZO" ] || \
  die "disk image must use the compressed read-only UDZO format"
[ "$(plutil -extract Properties.Compressed raw -o - "$IMAGE_INFO")" = \
  "true" ] || die "disk image is not compressed"
[ "$(plutil -extract Properties.Encrypted raw -o - "$IMAGE_INFO")" = \
  "false" ] || die "disk image must not be encrypted"
hdiutil verify "$DMG" >/dev/null
codesign --verify --strict --verbose=4 "$DMG" >/dev/null 2>&1 || \
  die "invalid disk image signature: $DMG"
DMG_DETAILS="$(codesign -dv --verbose=4 "$DMG" 2>&1)"
grep -Fq 'Authority=Developer ID Application:' <<<"$DMG_DETAILS" || \
  die "disk image is not signed by Developer ID Application"
grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$DMG_DETAILS" || \
  die "disk image signature does not belong to team $TEAM_ID"
grep -Eq '^Timestamp=' <<<"$DMG_DETAILS" || \
  die "disk image signature has no secure timestamp"

hdiutil attach "$DMG" \
  -readonly \
  -nobrowse \
  -noautoopen \
  -owners off \
  -mountpoint "$MOUNT_POINT" \
  -quiet
ATTACHED=1

[ "$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print | \
      wc -l | tr -d ' ')" = "2" ] || \
  die "disk image root must contain only Kinolet.app and Applications"
[ -d "$MOUNT_POINT/Kinolet.app" ] || \
  die "disk image does not contain Kinolet.app"
[ -L "$MOUNT_POINT/Applications" ] || \
  die "disk image Applications entry is not a symbolic link"
[ "$(readlink "$MOUNT_POINT/Applications")" = "/Applications" ] || \
  die "disk image Applications link does not target /Applications"

CONTAINED_APP="$MOUNT_POINT/Kinolet.app"
if [ -z "$BUNDLE_ID" ]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$CONTAINED_APP/Contents/Info.plist")"
fi
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || \
  die "contained app has an invalid bundle identifier: $BUNDLE_ID"
grep -Fxq "Identifier=$BUNDLE_ID.dmg" <<<"$DMG_DETAILS" || \
  die "disk image signing identifier must be $BUNDLE_ID.dmg"

"$ROOT/Scripts/verify_app_bundle.sh" "$CONTAINED_APP"
"$ROOT/Scripts/lib/verify_developer_id_app.sh" \
  --app "$CONTAINED_APP" \
  --team-id "$TEAM_ID" \
  --bundle-id "$BUNDLE_ID"

# A valid outer ticket does not make the app's standalone ticket check pass.
xcrun stapler validate -q "$CONTAINED_APP" || \
  die "contained app has no valid stapled notarization ticket"

code_directory_hash() {
  codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p'
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

if [ -n "$SOURCE_APP" ]; then
  SOURCE_CDHASH="$(code_directory_hash "$SOURCE_APP")"
  CONTAINED_CDHASH="$(code_directory_hash "$CONTAINED_APP")"
  [ -n "$SOURCE_CDHASH" ] && \
    [ "$SOURCE_CDHASH" = "$CONTAINED_CDHASH" ] || \
    die "contained app CodeDirectory differs from the source app"
  for plist_key in \
    CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
    [ "$(plist_value "$SOURCE_APP" "$plist_key")" = \
      "$(plist_value "$CONTAINED_APP" "$plist_key")" ] || \
      die "$plist_key differs between the source and contained app"
  done
  [ "$(shasum -a 256 \
      "$SOURCE_APP/Contents/Resources/BuildManifest.json" | awk '{print $1}')" = \
    "$(shasum -a 256 \
      "$CONTAINED_APP/Contents/Resources/BuildManifest.json" | awk '{print $1}')" ] || \
    die "BuildManifest differs between the source and contained app"
fi

echo "==> Developer ID disk image verification passed: $DMG"
