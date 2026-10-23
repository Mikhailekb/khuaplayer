#!/bin/bash
# Xcode's application target runs this before its final CodeSign operation.
# The verified reproducible-build cache stays unsigned; only its copy is signed.
set -euo pipefail

TORRENT_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TORRENT_MANIFEST="$TORRENT_REPO_ROOT/Apps/Mac/Resources/Torrent/worker-manifest.json"
TORRENT_VERSION="$(/usr/bin/plutil -extract worker_version raw -o - "$TORRENT_MANIFEST")"
TORRENT_SOURCE_NAME="$(/usr/bin/plutil -extract source_name raw -o - "$TORRENT_MANIFEST")"
TORRENT_PATCH_NAME="$(/usr/bin/plutil -extract patch_name raw -o - "$TORRENT_MANIFEST")"
TORRENT_DEPENDENCY_NAME="$(/usr/bin/plutil -extract dependency_source_name raw -o - "$TORRENT_MANIFEST")"
TORRENT_DEPENDENCY_PATCH_NAME="$(/usr/bin/plutil -extract dependency_patch_name raw -o - "$TORRENT_MANIFEST")"
TORRENT_CACHE_DIR="$TORRENT_REPO_ROOT/.build/torrent-worker/$TORRENT_VERSION/Resources/Torrent"
TORRENT_ENTITLEMENTS="$TORRENT_REPO_ROOT/Apps/Mac/TorrentWorker.entitlements"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 0 ] || fail "embed_torrent_worker.sh accepts Xcode build settings, not arguments"
[ -n "${TARGET_BUILD_DIR:-}" ] || fail "TARGET_BUILD_DIR is required"
[ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ] || fail "UNLOCALIZED_RESOURCES_FOLDER_PATH is required"
case "$UNLOCALIZED_RESOURCES_FOLDER_PATH" in
  /*|../*|*/../*|*/..) fail "UNLOCALIZED_RESOURCES_FOLDER_PATH must be product relative" ;;
esac

TORRENT_RESOURCES_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
TORRENT_DESTINATION="$TORRENT_RESOURCES_DIR/Torrent"
[ ! -L "$TORRENT_DESTINATION" ] || fail "torrent resource directory must not be a symlink"
[ ! -e "$TORRENT_DESTINATION" ] || [ -d "$TORRENT_DESTINATION" ] || fail "torrent resource path is not a directory"
[ -f "$TORRENT_ENTITLEMENTS" ] || fail "torrent worker entitlements are missing"

# Always verify the pinned cache. Never verify the signed bundle copy against
# its unsigned hash: signing legitimately changes the executable's bytes.
"$TORRENT_REPO_ROOT/Scripts/prepare_torrent_worker.sh" --output-directory "$TORRENT_CACHE_DIR"
mkdir -p "$TORRENT_RESOURCES_DIR"
TORRENT_STAGING="$(mktemp -d "$TORRENT_RESOURCES_DIR/.embed-torrent-worker.XXXXXX")"
trap 'rm -rf "$TORRENT_STAGING"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TORRENT_FILES=(TorrServer LICENSE NOTICE "$TORRENT_SOURCE_NAME" "$TORRENT_PATCH_NAME"
  "$TORRENT_DEPENDENCY_NAME" "$TORRENT_DEPENDENCY_PATCH_NAME" worker-manifest.json build_torrent_worker.py)
for TORRENT_NAME in "${TORRENT_FILES[@]}"; do
  [ -f "$TORRENT_CACHE_DIR/$TORRENT_NAME" ] && [ ! -L "$TORRENT_CACHE_DIR/$TORRENT_NAME" ] || \
    fail "verified torrent payload is missing: $TORRENT_NAME"
  [ ! -L "$TORRENT_DESTINATION/$TORRENT_NAME" ] && [ ! -d "$TORRENT_DESTINATION/$TORRENT_NAME" ] || \
    fail "torrent output file must be a regular file: $TORRENT_NAME"
  /usr/bin/install -m 0644 "$TORRENT_CACHE_DIR/$TORRENT_NAME" "$TORRENT_STAGING/$TORRENT_NAME"
done
chmod 0755 "$TORRENT_STAGING/TorrServer"

TORRENT_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] || [ -z "$TORRENT_IDENTITY" ]; then
  TORRENT_IDENTITY="-"
fi
TORRENT_SIGN_ARGS=(--force --sign "$TORRENT_IDENTITY" --identifier "${PRODUCT_BUNDLE_IDENTIFIER:-app.kinolet.player}.TorrentServer")
if [ "$TORRENT_IDENTITY" = "-" ]; then
  TORRENT_SIGN_ARGS+=(--timestamp=none)
else
  TORRENT_SIGN_ARGS+=(--timestamp)
fi
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
  TORRENT_SIGN_ARGS+=(--options runtime)
fi

TORRENT_SANDBOXED=NO
if [ "${CONFIGURATION:-}" = "AppStore" ] || [ "${ENABLE_APP_SANDBOX:-NO}" = "YES" ]; then
  TORRENT_SANDBOXED=YES
elif [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -n "${CODE_SIGN_ENTITLEMENTS:-}" ]; then
  TORRENT_PARENT_ENTITLEMENTS="$CODE_SIGN_ENTITLEMENTS"
  case "$TORRENT_PARENT_ENTITLEMENTS" in
    /*) ;;
    *) TORRENT_PARENT_ENTITLEMENTS="${SRCROOT:-$TORRENT_REPO_ROOT/Apps/Mac}/$TORRENT_PARENT_ENTITLEMENTS" ;;
  esac
  [ -f "$TORRENT_PARENT_ENTITLEMENTS" ] || fail "application signing entitlements are missing"
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$TORRENT_PARENT_ENTITLEMENTS" 2>/dev/null || true)" = "true" ]; then
    TORRENT_SANDBOXED=YES
  fi
fi
if [ "$TORRENT_SANDBOXED" = "YES" ]; then
  # A child inherits the parent's static rights, including network access.
  # Apple's sandbox inheritance contract permits exactly these two keys.
  TORRENT_SIGN_ARGS+=(--entitlements "$TORRENT_ENTITLEMENTS" --generate-entitlement-der)
fi

/usr/bin/codesign "${TORRENT_SIGN_ARGS[@]}" "$TORRENT_STAGING/TorrServer"
/usr/bin/codesign --verify --strict "$TORRENT_STAGING/TorrServer"
mkdir -p "$TORRENT_DESTINATION"
for TORRENT_NAME in "${TORRENT_FILES[@]}"; do
  mv -f "$TORRENT_STAGING/$TORRENT_NAME" "$TORRENT_DESTINATION/$TORRENT_NAME"
done
/usr/bin/codesign --verify --strict "$TORRENT_DESTINATION/TorrServer"
printf '==> Embedded TorrServer %s (sandbox inheritance: %s): %s\n' \
  "$TORRENT_VERSION" "$TORRENT_SANDBOXED" "$TORRENT_DESTINATION"
