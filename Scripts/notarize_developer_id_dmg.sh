#!/bin/bash
# Submit the signed DMG, staple the accepted ticket, and publish the final DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: Scripts/notarize_developer_id_dmg.sh \
  --release-dir PATH \
  --team-id TEAM_ID \
  --keychain-profile PROFILE

Create PROFILE once with `xcrun notarytool store-credentials`. Passwords and
API private keys must remain in Keychain and are never accepted by this script.
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
TEAM_ID=""
PROFILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-dir)
      require_argument "$@"
      RELEASE_DIR="$2"
      shift 2
      ;;
    --team-id)
      require_argument "$@"
      TEAM_ID="$2"
      shift 2
      ;;
    --keychain-profile)
      require_argument "$@"
      PROFILE="$2"
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
[ -n "$TEAM_ID" ] || die "--team-id is required"
[ -n "$PROFILE" ] || die "--keychain-profile is required"
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

STATE_STAGE=""
FINAL_STAGE=""
RESULT_TMP=""
LOG_TMP=""
CHECKSUM_TMP=""
cleanup() {
  [ -z "$STATE_STAGE" ] || rm -rf "$STATE_STAGE"
  [ -z "$FINAL_STAGE" ] || rm -rf "$FINAL_STAGE"
  [ -z "$RESULT_TMP" ] || rm -f "$RESULT_TMP"
  [ -z "$LOG_TMP" ] || rm -f "$LOG_TMP"
  [ -z "$CHECKSUM_TMP" ] || rm -f "$CHECKSUM_TMP"
}
trap cleanup EXIT

APP="$RELEASE_DIR/Kinolet.app"
SUBMISSION_DMG="$RELEASE_DIR/Kinolet-notarization.dmg"
SUBMISSION_CHECKSUM="$RELEASE_DIR/Kinolet-notarization.dmg.sha256"
STATE_DIR="$RELEASE_DIR/DmgNotarization"
[ -d "$APP" ] || die "prepared app is missing: $APP"
[ -f "$SUBMISSION_DMG" ] || \
  die "submission disk image is missing: $SUBMISSION_DMG"
[ -f "$SUBMISSION_CHECKSUM" ] || \
  die "submission checksum is missing: $SUBMISSION_CHECKSUM"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$APP/Contents/Info.plist")"
MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c \
  'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || \
  die "app has an invalid bundle identifier: $BUNDLE_ID"
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
  die "app has an invalid marketing version: $MARKETING_VERSION"
FINAL_DMG="$RELEASE_DIR/Kinolet-$MARKETING_VERSION.dmg"
FINAL_CHECKSUM="$FINAL_DMG.sha256"

SUBMISSION_SHA256="$(shasum -a 256 "$SUBMISSION_DMG" | awk '{print $1}')"
(cd "$RELEASE_DIR" && shasum -a 256 -c \
  "$(basename "$SUBMISSION_CHECKSUM")") >/dev/null || \
  die "submission disk image does not match its archived checksum"
"$ROOT/Scripts/lib/verify_developer_id_dmg.sh" \
  --dmg "$SUBMISSION_DMG" \
  --team-id "$TEAM_ID" \
  --bundle-id "$BUNDLE_ID" \
  --source-app "$APP"

verify_public_dmg_content() {
  local dmg="$1"
  local spctl_output

  [ -f "$dmg" ] || die "final disk image is missing: $dmg"
  xcrun stapler validate -v "$dmg"
  "$ROOT/Scripts/lib/verify_developer_id_dmg.sh" \
    --dmg "$dmg" \
    --team-id "$TEAM_ID" \
    --bundle-id "$BUNDLE_ID" \
    --source-app "$APP"
  spctl_output="$(spctl --assess --type open \
    --context context:primary-signature --verbose=4 "$dmg" 2>&1)" || {
      printf '%s\n' "$spctl_output" >&2
      die "Gatekeeper rejected the final disk image"
    }
  printf '%s\n' "$spctl_output"
  grep -Fq 'source=Notarized Developer ID' <<<"$spctl_output" || \
    die "Gatekeeper did not report Notarized Developer ID"
}

verify_public_dmg() {
  local dmg="$1"
  local checksum="$2"

  [ -f "$checksum" ] || die "final checksum is missing: $checksum"
  (cd "$(dirname "$dmg")" && \
    shasum -a 256 -c "$(basename "$checksum")") >/dev/null || \
    die "final disk image does not match its checksum"
  verify_public_dmg_content "$dmg"
}

if [ -e "$FINAL_CHECKSUM" ] && [ ! -f "$FINAL_DMG" ]; then
  die "final checksum exists without its disk image: $FINAL_CHECKSUM"
fi
if [ -e "$FINAL_DMG" ]; then
  [ -f "$FINAL_DMG" ] || \
    die "final disk image is not a regular file: $FINAL_DMG"
  if [ ! -e "$FINAL_CHECKSUM" ]; then
    verify_public_dmg_content "$FINAL_DMG"
    echo "==> Recovering checksum for the verified final disk image"
    CHECKSUM_TMP="$(mktemp "$RELEASE_DIR/.final-dmg-checksum.XXXXXX")"
    (cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$FINAL_DMG")") \
      >"$CHECKSUM_TMP"
    mv "$CHECKSUM_TMP" "$FINAL_CHECKSUM"
    CHECKSUM_TMP=""
  fi
  verify_public_dmg "$FINAL_DMG" "$FINAL_CHECKSUM"
  echo "==> Notarized and stapled release already ready: $FINAL_DMG"
  exit 0
fi

if [ -e "$STATE_DIR" ] && [ ! -d "$STATE_DIR" ]; then
  die "notarization state path is not a directory: $STATE_DIR"
fi

echo "==> Validating Notary Service Keychain profile"
xcrun notarytool history \
  --keychain-profile "$PROFILE" \
  --output-format plist \
  --no-progress >/dev/null

if [ ! -d "$STATE_DIR" ]; then
  STATE_STAGE="$(mktemp -d "$RELEASE_DIR/.dmg-notary-state.XXXXXX")"
  echo "==> Submitting signed DMG to Apple Notary Service"
  set +e
  xcrun notarytool submit "$SUBMISSION_DMG" \
    --keychain-profile "$PROFILE" \
    --no-wait \
    --output-format plist \
    --no-progress >"$STATE_STAGE/Submission.plist"
  SUBMIT_STATUS=$?
  set -e
  [ "$SUBMIT_STATUS" -eq 0 ] || \
    die "notarytool submit failed with status $SUBMIT_STATUS"
  [ -s "$STATE_STAGE/Submission.plist" ] || \
    die "notarytool returned no submission result"
  plutil -lint "$STATE_STAGE/Submission.plist" >/dev/null || \
    die "notarytool returned invalid plist"
  plutil -extract id raw -o - "$STATE_STAGE/Submission.plist" >/dev/null \
    2>&1 || die "Notary Service result has no submission ID"
  printf '%s\n' "$SUBMISSION_SHA256" \
    >"$STATE_STAGE/SubmittedArchive.sha256"
  mv "$STATE_STAGE" "$STATE_DIR"
  STATE_STAGE=""
fi

RESULT="$STATE_DIR/Submission.plist"
SUBMITTED_CHECKSUM="$STATE_DIR/SubmittedArchive.sha256"
LOG="$STATE_DIR/Log.json"
[ -f "$RESULT" ] || die "saved submission result is missing: $RESULT"
[ -f "$SUBMITTED_CHECKSUM" ] || \
  die "saved submission checksum is missing: $SUBMITTED_CHECKSUM"
plutil -lint "$RESULT" >/dev/null || \
  die "saved submission result is not a valid plist: $RESULT"
IFS= read -r SUBMITTED_SHA256 <"$SUBMITTED_CHECKSUM"
[ "$SUBMITTED_SHA256" = "$SUBMISSION_SHA256" ] || \
  die "saved submission belongs to a different disk image"

SUBMISSION_ID="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
NOTARY_STATUS="$(plutil -extract status raw -o - "$RESULT" \
  2>/dev/null || true)"
[ -n "$SUBMISSION_ID" ] || die "Notary Service result has no submission ID"
if [ "$NOTARY_STATUS" != "Accepted" ] && \
   [ "$NOTARY_STATUS" != "Invalid" ]; then
  echo "==> Resuming Notary Service wait: $SUBMISSION_ID"
  RESULT_TMP="$(mktemp "$STATE_DIR/.Submission.XXXXXX")"
  set +e
  xcrun notarytool wait "$SUBMISSION_ID" \
    --keychain-profile "$PROFILE" \
    --timeout 2h \
    --output-format plist \
    --no-progress >"$RESULT_TMP"
  WAIT_STATUS=$?
  set -e
  [ -s "$RESULT_TMP" ] || die "notarytool wait returned no result"
  plutil -lint "$RESULT_TMP" >/dev/null || \
    die "notarytool wait returned invalid plist"
  if [ "$WAIT_STATUS" -ne 0 ]; then
    WAIT_RESULT_STATUS="$(plutil -extract status raw -o - "$RESULT_TMP" \
      2>/dev/null || true)"
    [ "$WAIT_RESULT_STATUS" = "Invalid" ] || \
      die "notarytool wait failed with status $WAIT_STATUS"
  fi
  mv -f "$RESULT_TMP" "$RESULT"
  RESULT_TMP=""
  SUBMISSION_ID="$(plutil -extract id raw -o - "$RESULT" \
    2>/dev/null || true)"
  NOTARY_STATUS="$(plutil -extract status raw -o - "$RESULT" \
    2>/dev/null || true)"
fi
[ "$NOTARY_STATUS" != "In Progress" ] || \
  die "notarization is still in progress; retry to resume $SUBMISSION_ID"

LOG_TMP="$(mktemp "$STATE_DIR/.Log.XXXXXX")"
xcrun notarytool log "$SUBMISSION_ID" "$LOG_TMP" \
  --keychain-profile "$PROFILE" >/dev/null
python3 -m json.tool "$LOG_TMP" >/dev/null || \
  die "Notary Service returned an invalid JSON log"
LOG_SHA256="$(python3 -c \
  'import json, sys; print(json.load(open(sys.argv[1])).get("sha256", ""))' \
  "$LOG_TMP")"
[ "$LOG_SHA256" = "$SUBMISSION_SHA256" ] || \
  die "Apple notarized a different disk image SHA-256: $LOG_SHA256"
mv -f "$LOG_TMP" "$LOG"
LOG_TMP=""
[ "$NOTARY_STATUS" = "Accepted" ] || \
  die "notarization status is $NOTARY_STATUS; inspect $RESULT and $LOG"

FINAL_STAGE="$(mktemp -d "$RELEASE_DIR/.final-dmg.XXXXXX")"
FINAL_TMP="$FINAL_STAGE/$(basename "$FINAL_DMG")"
cp -p "$SUBMISSION_DMG" "$FINAL_TMP"
[ "$(shasum -a 256 "$FINAL_TMP" | awk '{print $1}')" = \
  "$SUBMISSION_SHA256" ] || die "staged final disk image differs before staple"

echo "==> Stapling accepted ticket to the public DMG"
xcrun stapler staple -v "$FINAL_TMP"
xcrun stapler validate -v "$FINAL_TMP"
"$ROOT/Scripts/lib/verify_developer_id_dmg.sh" \
  --dmg "$FINAL_TMP" \
  --team-id "$TEAM_ID" \
  --bundle-id "$BUNDLE_ID" \
  --source-app "$APP"

SPCTL_OUTPUT="$(spctl --assess --type open \
  --context context:primary-signature --verbose=4 "$FINAL_TMP" 2>&1)" || {
    printf '%s\n' "$SPCTL_OUTPUT" >&2
    die "Gatekeeper rejected the stapled disk image"
  }
printf '%s\n' "$SPCTL_OUTPUT"
grep -Fq 'source=Notarized Developer ID' <<<"$SPCTL_OUTPUT" || \
  die "Gatekeeper did not report Notarized Developer ID"

(cd "$FINAL_STAGE" && shasum -a 256 "$(basename "$FINAL_DMG")" \
  >"$(basename "$FINAL_CHECKSUM")")
mv "$FINAL_TMP" "$FINAL_DMG"
mv "$FINAL_STAGE/$(basename "$FINAL_CHECKSUM")" "$FINAL_CHECKSUM"
rmdir "$FINAL_STAGE"
FINAL_STAGE=""
verify_public_dmg "$FINAL_DMG" "$FINAL_CHECKSUM"

echo "==> Notarized and stapled release ready: $FINAL_DMG"
