#!/bin/bash
# Package a prepared Developer ID app into a signed, read-only disk image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: Scripts/create_developer_id_dmg.sh \
  --release-dir PATH \
  --identity "Developer ID Application: Name (TEAM_ID)" \
  --team-id TEAM_ID

The release directory must contain the signed Kinolet.app produced by
archive_developer_id.sh, notarized and stapled by notarize_developer_id.sh.
The output is Kinolet-notarization.dmg; it is not a final
public download until notarize_developer_id_dmg.sh accepts and staples it.
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

RELEASE_DIR=""
IDENTITY=""
TEAM_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-dir)
      require_argument "$@"
      RELEASE_DIR="$2"
      shift 2
      ;;
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$RELEASE_DIR" ] || die "--release-dir is required"
[ -n "$IDENTITY" ] || die "--identity is required"
[ -n "$TEAM_ID" ] || die "--team-id is required"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || \
  die "--team-id must be a 10-character Apple Team ID"
[ -d "$RELEASE_DIR" ] || die "release directory does not exist: $RELEASE_DIR"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd -P)"

LOCK_ROOT="$ROOT/.build/DeveloperID/.notary-locks"
mkdir -p "$LOCK_ROOT"
LOCK_KEY="$(printf '%s' "$RELEASE_DIR" | shasum -a 256 | awk '{print $1}')"
LOCK_FILE="$LOCK_ROOT/$LOCK_KEY.lock"
exec 9>>"$LOCK_FILE"
/usr/bin/lockf -s -t 0 9 || \
  die "another release process is using this release directory"

STAGE=""
OUTPUT_STAGE=""
cleanup() {
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  [ -z "$OUTPUT_STAGE" ] || rm -rf "$OUTPUT_STAGE"
}
trap cleanup EXIT

APP="$RELEASE_DIR/Kinolet.app"
SUBMISSION_DMG="$RELEASE_DIR/Kinolet-notarization.dmg"
SUBMISSION_CHECKSUM="$RELEASE_DIR/Kinolet-notarization.dmg.sha256"
[ -d "$APP" ] || die "prepared app is missing: $APP"
security find-identity -v -p codesigning | grep -Fq "$IDENTITY" || \
  die "code-signing identity is not available: $IDENTITY"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$APP/Contents/Info.plist")"
MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c \
  'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || \
  die "app has an invalid bundle identifier: $BUNDLE_ID"
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
  die "app has an invalid marketing version: $MARKETING_VERSION"
[ ! -e "$RELEASE_DIR/Kinolet-$MARKETING_VERSION.dmg" ] || \
  die "final disk image already exists for version $MARKETING_VERSION"

"$ROOT/Scripts/lib/verify_developer_id_app.sh" \
  --app "$APP" \
  --team-id "$TEAM_ID" \
  --bundle-id "$BUNDLE_ID"

# The extracted app must retain its own ticket, independently of the container.
xcrun stapler validate -q "$APP" || \
  die "app has no valid stapled ticket; run Scripts/notarize_developer_id.sh first"

if [ -e "$SUBMISSION_CHECKSUM" ] && [ ! -f "$SUBMISSION_DMG" ]; then
  die "submission checksum exists without its disk image: $SUBMISSION_CHECKSUM"
fi
if [ -e "$SUBMISSION_DMG" ]; then
  [ -f "$SUBMISSION_DMG" ] || \
    die "submission disk image is not a regular file: $SUBMISSION_DMG"
  "$ROOT/Scripts/lib/verify_developer_id_dmg.sh" \
    --dmg "$SUBMISSION_DMG" \
    --team-id "$TEAM_ID" \
    --bundle-id "$BUNDLE_ID" \
    --source-app "$APP"
  if [ -e "$SUBMISSION_CHECKSUM" ]; then
    [ -f "$SUBMISSION_CHECKSUM" ] || \
      die "submission checksum is not a regular file: $SUBMISSION_CHECKSUM"
    (cd "$RELEASE_DIR" && shasum -a 256 -c \
      "$(basename "$SUBMISSION_CHECKSUM")") >/dev/null || \
      die "submission disk image does not match its checksum"
  else
    echo "==> Recovering checksum for the verified disk image"
    OUTPUT_STAGE="$(mktemp -d "$RELEASE_DIR/.dmg-output.XXXXXX")"
    (cd "$RELEASE_DIR" && shasum -a 256 \
      "$(basename "$SUBMISSION_DMG")") \
      >"$OUTPUT_STAGE/$(basename "$SUBMISSION_CHECKSUM")"
    mv "$OUTPUT_STAGE/$(basename "$SUBMISSION_CHECKSUM")" \
      "$SUBMISSION_CHECKSUM"
    rmdir "$OUTPUT_STAGE"
    OUTPUT_STAGE=""
  fi
  echo "==> Signed DMG already ready for notarization: $SUBMISSION_DMG"
  exit 0
fi

STAGE="$(mktemp -d "$RELEASE_DIR/.dmg-payload.XXXXXX")"
OUTPUT_STAGE="$(mktemp -d "$RELEASE_DIR/.dmg-output.XXXXXX")"
DMG_TMP="$OUTPUT_STAGE/Kinolet-notarization.dmg"
CHECKSUM_TMP="$OUTPUT_STAGE/Kinolet-notarization.dmg.sha256"

echo "==> Staging Kinolet.app and the Applications shortcut"
ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/Kinolet.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating compressed read-only disk image"
hdiutil create \
  -quiet \
  -fs HFS+ \
  -format UDZO \
  -volname Kinolet \
  -srcfolder "$STAGE" \
  "$DMG_TMP"

echo "==> Signing disk image with Developer ID"
codesign \
  --sign "$IDENTITY" \
  --force \
  --timestamp \
  --identifier "$BUNDLE_ID.dmg" \
  "$DMG_TMP"

"$ROOT/Scripts/lib/verify_developer_id_dmg.sh" \
  --dmg "$DMG_TMP" \
  --team-id "$TEAM_ID" \
  --bundle-id "$BUNDLE_ID" \
  --source-app "$APP"

(cd "$OUTPUT_STAGE" && \
  shasum -a 256 Kinolet-notarization.dmg >Kinolet-notarization.dmg.sha256)
mv "$DMG_TMP" "$SUBMISSION_DMG"
mv "$CHECKSUM_TMP" "$SUBMISSION_CHECKSUM"
rmdir "$OUTPUT_STAGE"
OUTPUT_STAGE=""

echo "==> Signed DMG ready for notarization: $SUBMISSION_DMG"
echo "==> This is an internal submission artifact, not the public download."
