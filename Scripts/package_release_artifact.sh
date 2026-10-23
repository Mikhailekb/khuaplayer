#!/bin/bash
# Archive the verified canonical Release product without launching or modifying it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Build/Products/Release/Kinolet.app"
OUTPUT="${1:?usage: package_release_artifact.sh <empty-output-directory>}"
mkdir -p "$OUTPUT"
[ -z "$(ls -A "$OUTPUT")" ] || { echo "Release artifact output must be empty" >&2; exit 1; }
OUTPUT="$(cd "$OUTPUT" && pwd -P)"
"$ROOT/Scripts/verify_app_bundle.sh" "$APP"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

python3 - "$ROOT" "$APP" "$STAGING/build-info.json" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root, app, output = map(Path, sys.argv[1:])
assert not any(path.name == '.DS_Store' or path.name.endswith('.dSYM') for path in app.rglob('*'))
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'app.kinolet.player'
assert info['CFBundleExecutable'] == 'Kinolet'
assert info['LSMinimumSystemVersion'] == '14.0'
version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
assert re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', version)
assert re.fullmatch(r'[0-9]+', build)
project = (root / 'Apps/Mac/project.yml').read_text()
expected_versions = re.findall(r'^\s+MARKETING_VERSION:\s*"?([0-9.]+)"?\s*$', project, re.MULTILINE)
expected_builds = re.findall(r'^\s+CURRENT_PROJECT_VERSION:\s*"?([0-9]+)"?\s*$', project, re.MULTILINE)
assert expected_versions == [version] and expected_builds == [build], 'Release app differs from source version/build'
extension = app / 'Contents/PlugIns/KhuaPlayerQuickLook.appex/Contents/Info.plist'
quicklook = plistlib.loads(extension.read_bytes())
assert quicklook['CFBundleIdentifier'] == 'app.kinolet.player.QuickLook'
assert quicklook['CFBundleShortVersionString'] == version and quicklook['CFBundleVersion'] == build
main = app / 'Contents/MacOS/Kinolet'
assert subprocess.check_output(['lipo', '-archs', str(main)], text=True).split() == ['arm64']
loads = subprocess.check_output(['otool', '-l', str(main)], text=True)
minos = re.findall(r'^\s*minos\s+([0-9.]+)\s*$', loads, re.MULTILINE)
assert minos and all(tuple((list(map(int, value.split('.'))) + [0, 0])[:3]) <= (14, 0, 0) for value in minos)
signing = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True).stdout
assert 'Signature=adhoc' in signing and 'TeamIdentifier=not set' in signing
commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
assert re.fullmatch(r'[0-9a-f]{40}', commit)
assert not os.environ.get('GITHUB_SHA') or os.environ['GITHUB_SHA'] == commit
assert not subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'], text=True).strip()
resources = app / 'Contents/Resources'
for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
    assert (resources / name).read_bytes() == (root / name).read_bytes(), name
torrent = resources / 'Torrent'
manifest = json.loads((torrent / 'worker-manifest.json').read_text())
for key in ('source', 'patch', 'dependency_source', 'dependency_patch'):
    name = manifest[key + '_name']
    assert Path(name).name == name
    data = (torrent / name).read_bytes()
    assert len(data) == manifest[key + '_bytes']
    assert hashlib.sha256(data).hexdigest() == manifest[key + '_sha256']
for name in ('LICENSE', 'NOTICE', 'worker-manifest.json'):
    assert (torrent / name).read_bytes() == (root / 'Apps/Mac/Resources/Torrent' / name).read_bytes(), name
assert (torrent / 'build_torrent_worker.py').read_bytes() == (root / 'Scripts/build_torrent_worker.py').read_bytes()
record = dict(schema=1, product='Кинолёт', archive=f'Kinolet-{version}-build{build}-macos-arm64.zip',
              source_archive=f'Kinolet-{version}-source.tar.gz',
              version=version, build=build, bundle_identifier=info['CFBundleIdentifier'],
              architecture='arm64', minimum_macos='14.0', source_commit=commit,
              source_repository='https://github.com/Mikhailekb/kinolet',
              signing=dict(type='ad-hoc', developer_id=False, notarized=False),
              torrent_worker=manifest['worker_version'],
              verification=['canonical Release bundle', 'ZIP extraction roundtrip'],
              ci_run_id=os.environ.get('GITHUB_RUN_ID'))
output.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
PY
ARCHIVE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive"])' "$STAGING/build-info.json")"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/$ARCHIVE"
mkdir "$STAGING/roundtrip"
ditto -x -k "$STAGING/$ARCHIVE" "$STAGING/roundtrip"
"$ROOT/Scripts/verify_app_bundle.sh" "$STAGING/roundtrip/Kinolet.app"
mv "$STAGING/$ARCHIVE" "$STAGING/build-info.json" "$OUTPUT/"
python3 - "$OUTPUT" "$ARCHIVE" <<'PY'
import hashlib
from pathlib import Path
import sys

output = Path(sys.argv[1])
names = (sys.argv[2], 'build-info.json')
(output / 'SHA256SUMS').write_text(''.join(
    hashlib.sha256((output / name).read_bytes()).hexdigest() + '  ' + name + '\n'
    for name in names))
PY
echo "==> Verified release ZIP, SHA256SUMS and build-info.json prepared"
