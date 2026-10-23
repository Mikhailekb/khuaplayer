#!/bin/bash
# Submit a prepared Developer ID ZIP, staple the accepted ticket to the exact
# app that was submitted, and create the final transport ZIP.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: Scripts/notarize_developer_id.sh \
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

APP="$RELEASE_DIR/Kinolet.app"
SUBMISSION_ZIP="$RELEASE_DIR/Kinolet-notarization.zip"
SUBMISSION_CHECKSUM="$RELEASE_DIR/Kinolet-notarization.zip.sha256"
FINAL_ZIP="$RELEASE_DIR/Kinolet.zip"
FINAL_CHECKSUM="$RELEASE_DIR/Kinolet.zip.sha256"
RESULT="$RELEASE_DIR/NotarizationSubmission.plist"
LOG="$RELEASE_DIR/NotarizationLog.json"
[ -d "$APP" ] || die "prepared app is missing: $APP"
[ -f "$SUBMISSION_ZIP" ] || die "submission ZIP is missing: $SUBMISSION_ZIP"
[ -f "$SUBMISSION_CHECKSUM" ] || \
  die "submission checksum is missing: $SUBMISSION_CHECKSUM"
[ ! -e "$FINAL_ZIP" ] || die "final ZIP already exists: $FINAL_ZIP"
[ ! -e "$FINAL_CHECKSUM" ] || \
  die "final ZIP checksum already exists: $FINAL_CHECKSUM"

# Serialize every network/staple attempt for this release directory. lockf
# keeps the lock on descriptor 9, so signals and SIGKILL cannot leave it stale.
LOCK_ROOT="$ROOT/.build/DeveloperID/.notary-locks"
mkdir -p "$LOCK_ROOT"
LOCK_KEY="$(printf '%s' "$RELEASE_DIR" | shasum -a 256 | awk '{print $1}')"
LOCK_FILE="$LOCK_ROOT/$LOCK_KEY.lock"
exec 9>>"$LOCK_FILE"
/usr/bin/lockf -s -t 0 9 || \
  die "another notarization process is using this release directory"

RESULT_TMP="$(mktemp "$RELEASE_DIR/.NotarizationSubmission.XXXXXX")"
LOG_STAGE="$(mktemp -d "$RELEASE_DIR/.notary-log.XXXXXX")"
LOG_TMP="$LOG_STAGE/NotarizationLog.json"
FINAL_STAGE="$(mktemp -d "$RELEASE_DIR/.final-zip.XXXXXX")"
FINAL_ZIP_TMP="$FINAL_STAGE/Kinolet.zip"
SUBMISSION_CHECK="$(mktemp -d)"
TRANSPORT_CHECK=""
cleanup() {
  rm -f "$RESULT_TMP"
  rm -rf "$LOG_STAGE" "$FINAL_STAGE" "$SUBMISSION_CHECK"
  [ -z "$TRANSPORT_CHECK" ] || rm -rf "$TRANSPORT_CHECK"
}
trap cleanup EXIT

(cd "$RELEASE_DIR" && shasum -a 256 -c \
  "$(basename "$SUBMISSION_CHECKSUM")") >/dev/null || \
  die "submission ZIP does not match its archived checksum"
"$ROOT/Scripts/lib/verify_developer_id_app.sh" \
  --app "$APP" --team-id "$TEAM_ID"

code_directory_hash() {
  codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p'
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

ditto -x -k "$SUBMISSION_ZIP" "$SUBMISSION_CHECK"
[ "$(find "$SUBMISSION_CHECK" -mindepth 1 -maxdepth 1 -print | \
      wc -l | tr -d ' ')" = "1" ] || \
  die "submission ZIP must contain only Kinolet.app"
[ -d "$SUBMISSION_CHECK/Kinolet.app" ] || \
  die "submission ZIP does not contain Kinolet.app"
"$ROOT/Scripts/lib/verify_developer_id_app.sh" \
  --app "$SUBMISSION_CHECK/Kinolet.app" --team-id "$TEAM_ID"
ARCHIVED_APP="$SUBMISSION_CHECK/Kinolet.app"
APP_CDHASH="$(code_directory_hash "$APP")"
ARCHIVED_CDHASH="$(code_directory_hash "$ARCHIVED_APP")"
[ -n "$APP_CDHASH" ] && [ "$APP_CDHASH" = "$ARCHIVED_CDHASH" ] || \
  die "Kinolet.app CodeDirectory differs from the app in the submission ZIP"
for plist_key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
  [ "$(plist_value "$APP" "$plist_key")" = \
    "$(plist_value "$ARCHIVED_APP" "$plist_key")" ] || \
    die "$plist_key differs from the app in the submission ZIP"
done
[ "$(shasum -a 256 "$APP/Contents/Resources/BuildManifest.json" | awk '{print $1}')" = \
  "$(shasum -a 256 "$ARCHIVED_APP/Contents/Resources/BuildManifest.json" | awk '{print $1}')" ] || \
  die "BuildManifest differs from the app in the submission ZIP"

echo "==> Validating Notary Service Keychain profile"
xcrun notarytool history \
  --keychain-profile "$PROFILE" \
  --output-format plist \
  --no-progress >/dev/null

if [ ! -e "$RESULT" ]; then
  echo "==> Submitting Developer ID archive to Apple Notary Service"
  set +e
  xcrun notarytool submit "$SUBMISSION_ZIP" \
    --keychain-profile "$PROFILE" \
    --no-wait \
    --output-format plist \
    --no-progress >"$RESULT_TMP"
  set -e
  [ -s "$RESULT_TMP" ] || die "notarytool returned no submission result"
  plutil -lint "$RESULT_TMP" >/dev/null || \
    die "notarytool returned invalid plist"
  mv -f "$RESULT_TMP" "$RESULT"
else
  plutil -lint "$RESULT" >/dev/null || \
    die "saved submission result is not a valid plist: $RESULT"
fi

SUBMISSION_ID="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
NOTARY_STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"
[ -n "$SUBMISSION_ID" ] || die "Notary Service result has no submission ID"
if [ "$NOTARY_STATUS" != "Accepted" ] && \
   [ "$NOTARY_STATUS" != "Invalid" ]; then
  echo "==> Resuming Notary Service wait: $SUBMISSION_ID"
  set +e
  xcrun notarytool wait "$SUBMISSION_ID" \
    --keychain-profile "$PROFILE" \
    --timeout 2h \
    --output-format plist \
    --no-progress >"$RESULT_TMP"
  set -e
  [ -s "$RESULT_TMP" ] || die "notarytool wait returned no result"
  plutil -lint "$RESULT_TMP" >/dev/null || \
    die "notarytool wait returned invalid plist"
  mv -f "$RESULT_TMP" "$RESULT"
  SUBMISSION_ID="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
  NOTARY_STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"
fi
[ "$NOTARY_STATUS" != "In Progress" ] || \
  die "notarization is still in progress; retry this command to resume $SUBMISSION_ID"

# Fetch every completed job log into a private staging directory, validate it,
# then publish it atomically. The log binds an existing result to this ZIP hash.
xcrun notarytool log "$SUBMISSION_ID" "$LOG_TMP" \
  --keychain-profile "$PROFILE" >/dev/null
python3 -m json.tool "$LOG_TMP" >/dev/null || \
  die "Notary Service returned an invalid JSON log"
mv -f "$LOG_TMP" "$LOG"
LOG_SHA256="$(python3 -c \
  'import json, sys; print(json.load(open(sys.argv[1])).get("sha256", ""))' \
  "$LOG")"
ARCHIVE_SHA256="$(shasum -a 256 "$SUBMISSION_ZIP" | awk '{print $1}')"
[ "$LOG_SHA256" = "$ARCHIVE_SHA256" ] || \
  die "Apple notarized a different archive SHA-256: $LOG_SHA256"
[ "$NOTARY_STATUS" = "Accepted" ] || \
  die "notarization status is $NOTARY_STATUS; inspect $RESULT and $LOG"

echo "==> Stapling accepted ticket to Kinolet.app"
if ! xcrun stapler validate -q "$APP" >/dev/null 2>&1; then
  xcrun stapler staple -v "$APP"
fi
xcrun stapler validate -v "$APP"
"$ROOT/Scripts/verify_app_bundle.sh" "$APP"
"$ROOT/Scripts/lib/verify_developer_id_app.sh" \
  --app "$APP" --team-id "$TEAM_ID"

SPCTL_OUTPUT="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1)" || {
  printf '%s\n' "$SPCTL_OUTPUT" >&2
  die "Gatekeeper rejected the stapled app"
}
printf '%s\n' "$SPCTL_OUTPUT"
grep -Fq 'source=Notarized Developer ID' <<<"$SPCTL_OUTPUT" || \
  die "Gatekeeper did not report Notarized Developer ID"

# ZIP files cannot carry a staple ticket themselves. Create the final archive
# only after the app has been stapled and independently accepted by Gatekeeper.
ditto -c -k --keepParent "$APP" "$FINAL_ZIP_TMP"
TRANSPORT_CHECK="$(mktemp -d)"
ditto -x -k "$FINAL_ZIP_TMP" "$TRANSPORT_CHECK"
xcrun stapler validate -q "$TRANSPORT_CHECK/Kinolet.app"
"$ROOT/Scripts/verify_app_bundle.sh" "$TRANSPORT_CHECK/Kinolet.app"
"$ROOT/Scripts/lib/verify_developer_id_app.sh" \
  --app "$TRANSPORT_CHECK/Kinolet.app" --team-id "$TEAM_ID"
spctl --assess --type execute --verbose=4 \
  "$TRANSPORT_CHECK/Kinolet.app" >/dev/null
rm -rf "$TRANSPORT_CHECK"
TRANSPORT_CHECK=""
mv "$FINAL_ZIP_TMP" "$FINAL_ZIP"
(cd "$RELEASE_DIR" && shasum -a 256 Kinolet.zip >Kinolet.zip.sha256)

echo "==> Notarized and stapled release ready: $FINAL_ZIP"
