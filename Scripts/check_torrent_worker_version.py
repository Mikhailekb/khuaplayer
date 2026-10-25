#!/usr/bin/env python3
"""Check the Swift handshake and protocol fixture against the bundled worker pin."""
import ast
import json
from pathlib import Path
import re


def main():
    root = Path(__file__).resolve().parent.parent
    manifest = json.loads((root / 'Apps/Mac/Resources/Torrent/worker-manifest.json').read_text())
    expected = manifest['worker_version']
    source = (root / 'Apps/Mac/UI/TorrentServer.swift').read_text()
    versions = re.findall(r'nonisolated\s+static\s+let\s+workerVersion\s*=\s*"([^"\n]+)"', source)
    if versions != [expected]:
        raise SystemExit(f'error: Swift torrent handshake version {versions!r} differs from worker pin {expected!r}')
    fixture = ast.parse((root / 'Scripts/tests/torrent_worker_fixture.py').read_text())
    fixture_versions = [node.value.value for node in fixture.body
                        if isinstance(node, ast.Assign) and len(node.targets) == 1
                        and isinstance(node.targets[0], ast.Name) and node.targets[0].id == 'WORKER_VERSION'
                        and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)]
    if fixture_versions != [expected]:
        raise SystemExit(f'error: protocol fixture version {fixture_versions!r} differs from worker pin {expected!r}')
    print('Torrent handshake versions match source pin:', expected)


if __name__ == '__main__':
    main()
