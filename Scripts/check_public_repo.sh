#!/bin/bash
# Fast repository-boundary and metadata checks for contributors and CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Kinolet maintains its runtime sources directly in this public fork. The
# inherited .khua-managed-source.sha256 belongs to upstream's private export
# workflow and is not a source-of-truth gate here. Git review, the source-layout
# checks in verify_public_surface.py, and the reproducible dependency recipes
# apply to fork changes without requiring a private upstream repository.

FORBIDDEN_PATHS=(
  BenchResults
  BuildGenerated
  CLAUDE.md
  TestMedia
  Tests
  docs
)
for path in "${FORBIDDEN_PATHS[@]}"; do
  if [ -n "$(git ls-files -- "$path")" ]; then
    echo "error: private or generated path is tracked: $path" >&2
    exit 1
  fi
done

TRACKED_RELEASE_ARTIFACTS="$(git ls-files | \
  grep -E '(^|/)((Khua|Kinolet|Кинолёт)[^/]*\.app/|(Khua|Kinolet|Кинолёт)[^/]*\.(dmg|zip)$|[^/]+\.(dSYM|xcarchive)/)' || true)"
if [ -n "$TRACKED_RELEASE_ARTIFACTS" ]; then
  echo "error: generated release artifacts are tracked:" >&2
  printf '%s\n' "$TRACKED_RELEASE_ARTIFACTS" >&2
  exit 1
fi

OLD_BRAND_RE='speed[[:space:]_.-]*player|spee[[:space:]_.-]*player'
if git grep -niE "$OLD_BRAND_RE" >/dev/null 2>&1; then
  echo "error: previous product branding remains in the public repository" >&2
  git grep -niE "$OLD_BRAND_RE" >&2 || true
  exit 1
fi

if git grep -n '/Users/' -- . ':(exclude)Scripts/check_public_repo.sh' >/dev/null 2>&1; then
  echo "error: a personal absolute path is present" >&2
  git grep -n '/Users/' -- . ':(exclude)Scripts/check_public_repo.sh' >&2 || true
  exit 1
fi

ENGLISH_FILES=(
  .gitignore
  CHANGELOG.md
  CONTRIBUTING.md
  Design/AppIcon/README.md
  Design/AppIcon/asset-manifest.txt
  Design/AppIcon/check_appicon.py
  Design/AppIcon/export_static_appicon.py
  Design/AppIcon/prepare_icon_composer_layers.py
  Design/AppIcon/requirements.txt
  LICENSE
  PRIVACY.md
  README.md
  RELEASING.md
  REPOSITORY_LAYOUT.md
  Apps/Mobile/README.md
  Apps/Mac/Scripts/build.sh
  Scripts/lib/runtime_source.py
  SECURITY.md
  THIRD_PARTY_NOTICES.md
  Apps/Mac/project.yml
  Apps/Mac/project.sparkle.yml
  Scripts/build.sh
  Scripts/build_dav1d.sh
  Scripts/build_speex.sh
  Scripts/lib/ffmpeg_capabilities.c
  Scripts/lib/sp_dovi_rpu.c
  Scripts/lib/sp_dovi_rpu.h
  Scripts/build_ffmpeg_min.sh
  Scripts/build_subtitle_libs.sh
  Scripts/build_sparkle.sh
  Scripts/bundle_libs.sh
  Scripts/create_developer_id_dmg.sh
  Scripts/archive_developer_id.sh
  Scripts/archive_app_store.sh
  Scripts/export_app_store.sh
  Scripts/notarize_developer_id.sh
  Scripts/notarize_developer_id_dmg.sh
  Scripts/smoke_app_store_unsigned.sh
  Scripts/run.sh
  Scripts/verify_app_bundle.sh
  Scripts/verify_public_surface.py
  Scripts/lib/build_common.sh
  Scripts/lib/verify_developer_id_app.sh
  Scripts/lib/verify_developer_id_dmg.sh
  Scripts/lib/verify_app_store_archive.sh
  Scripts/l10n.py
  Scripts/patches/README.md
  ThirdParty/README.md
)
for path in "${ENGLISH_FILES[@]}"; do
  [ -f "$path" ] || {
    echo "error: required public file is missing: $path" >&2
    exit 1
  }
  if LC_ALL=en_US.UTF-8 grep -n '[一-龥]' "$path" >/dev/null 2>&1; then
    echo "error: non-English public documentation or build output: $path" >&2
    LC_ALL=en_US.UTF-8 grep -n '[一-龥]' "$path" >&2 || true
    exit 1
  fi
done

if grep -nE 'window\.title[[:space:]]*=[[:space:]]*"(Khua|KhuaPlayer)"' \
     Apps/Mac/UI/PlayerWindowController.swift >/dev/null 2>&1; then
  echo "error: bootstrap window title must use the public display name Кинолёт" >&2
  exit 1
fi
# Full product names are valid in About metadata and documentation. App chrome
# retains the short name, independently of the full product name.
python3 - <<'PY'
import json
from pathlib import Path

catalog = json.loads(Path('Apps/Mac/Resources/Localizable.xcstrings').read_text())
names = catalog['strings']['app.displayName']['localizations']
if not names or any(record.get('stringUnit', {}).get('value') != 'Кинолёт'
                    for record in names.values()):
    raise SystemExit('error: every app.displayName translation must be Кинолёт')
text = Path('Apps/Mac/Resources/Localizable.xcstrings').read_text()
if 'KhuaPlayer' in text or 'Khua Player' in text:
    raise SystemExit('error: app chrome must use the name Кинолёт')
PY

while IFS= read -r script; do
  /bin/bash -n "$script"
done < <(find Scripts Apps/Mac/Scripts -type f -name '*.sh' | sort)

python3 -m json.tool ThirdParty/deps.lock.json >/dev/null
python3 -m json.tool Design/AppIcon/KhuaPlayer.icon/icon.json >/dev/null
python3 -m json.tool Design/AppIcon/export-manifest.json >/dev/null
python3 -m json.tool Apps/Mac/Resources/Localizable.xcstrings >/dev/null
python3 -m json.tool Apps/Mac/Resources/Assets.xcassets/Contents.json >/dev/null
python3 -m json.tool Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json >/dev/null
python3 Scripts/check_torrent_worker_version.py
python3 Design/AppIcon/check_appicon.py \
  --shipping Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset
python3 Scripts/l10n.py check --full
python3 Scripts/verify_public_surface.py

plutil -lint Apps/Mac/Info.plist >/dev/null
plutil -lint Apps/Mac/KhuaPlayer.entitlements >/dev/null
plutil -lint Apps/Mac/QuickLook/Info.plist >/dev/null
plutil -lint Apps/Mac/QuickLook/KhuaPlayerQuickLook.entitlements >/dev/null
plutil -lint Apps/Mac/Resources/PrivacyInfo.xcprivacy >/dev/null

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' Apps/Mac/Info.plist)" = "Кинолёт" ] || {
  echo "error: main CFBundleName must be Кинолёт" >&2
  exit 1
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' Apps/Mac/Info.plist)" = "Кинолёт" ] || {
  echo "error: main CFBundleDisplayName must be Кинолёт" >&2
  exit 1
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :SPProductName' Apps/Mac/Info.plist)" = "Кинолёт" ] || {
  echo "error: About product name must be Кинолёт" >&2
  exit 1
}
grep -Eq '^[[:space:]]+SPProductName:[[:space:]]+Кинолёт$' Apps/Mac/project.yml || {
  echo "error: project About product name must be Кинолёт" >&2
  exit 1
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' Apps/Mac/QuickLook/Info.plist)" = "Кинолёт Quick Look" ] || {
  echo "error: Quick Look CFBundleDisplayName must be Кинолёт Quick Look" >&2
  exit 1
}
grep -Eq '^[[:space:]]+PRODUCT_NAME:[[:space:]]+Kinolet$' Apps/Mac/project.yml || {
  echo "error: main PRODUCT_NAME must be Kinolet" >&2
  exit 1
}

grep -Eq '^[[:space:]]+KHUA_BUNDLE_ID:[[:space:]]+app\.kinolet\.player$' Apps/Mac/project.yml || {
  echo "error: the default application identifier must be app.kinolet.player" >&2
  exit 1
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :SPEnableDistributionUpdates' Apps/Mac/Info.plist)" = "false" ] || {
  echo "error: source distribution updates must default to false" >&2
  exit 1
}
python3 - <<'PYCHANNEL'
import json
from pathlib import Path
from urllib.parse import urlsplit
channel = json.loads(Path('Distribution/sparkle.json').read_text())
feed, key = channel.get('feedUrl'), channel.get('publicKey')
if not isinstance(feed, str) or not isinstance(key, str) or bool(feed) != bool(key):
    raise SystemExit('error: distribution feed and key must be supplied together')
host = (urlsplit(feed).hostname or '').lower().rstrip('.') if feed else ''
if host == 'khua.app' or host.endswith('.khua.app'):
    raise SystemExit('error: the fork must not inherit the upstream update feed')
if key == 'd8nyI3ZvaY4fTRHzcLYyygiRagGoGRdObweyoAARQ+0=':
    raise SystemExit('error: the fork must not inherit the upstream update public key')
PYCHANNEL

echo "Public repository checks passed."
