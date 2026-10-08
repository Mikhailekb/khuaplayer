#!/usr/bin/env python3
"""Check shipping source and optional app bundles against the public surface."""
import argparse
from pathlib import Path
import re
from lib.runtime_source import runtime_files

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = re.compile(
    rb'SP_(?:DUST|RESILIENT)_PROBE|SP_MEMC_\w+|SP_(?:INTERPOLATION|WELCOMECLICK)\b|'
    rb'SP_TEST_(?:ROTATE|MIRROR)\b|'
    rb'SP_(?:VIDEO_DECODER_(?:SCAN|OUTPUT)|FFMPEG_DECODER_OUTPUT|DOVI_DECODER)_TESTING',
    re.I,
)
SOURCE_TOKEN = re.compile(r'R"([^ ()\\\t\r\n]{0,16})\(.*?\)\1"|""".*?"""|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*(?:\n[ \t]*//[^\n]*)*|/\*.*?\*/', re.S)
NON_ENGLISH = re.compile(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]')


def check_source_comments(path):
    if path.suffix not in ('.h', '.hpp', '.cpp', '.mm', '.metal', '.swift'): return
    source = path.read_text()
    for match in SOURCE_TOKEN.finditer(source):
        token = match.group()
        if token.startswith(('//', '/*')) and NON_ENGLISH.search(token):
            raise SystemExit(f'Non-English source comment in {path}')
    for match in re.finditer(r'^#pragma mark - (.*)$', source, re.M):
        if NON_ENGLISH.search(match[1]):
            raise SystemExit(f'Non-English section label in {path}')


def check_file(path):
    match = EXCLUDED.search(path.name.encode()) or EXCLUDED.search(path.read_bytes())
    if match:
        raise SystemExit(f'Excluded surface found in {path}: {match.group().decode(errors="replace")}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='also inspect a built .app bundle')
    args = parser.parse_args()
    count = 0
    for path in runtime_files(ROOT).values():
        check_file(path)
        check_source_comments(path)
        count += 1
    if args.app:
        if not (args.app / 'Contents/Info.plist').is_file():
            raise SystemExit('Expected a built .app bundle')
        # Inspect resources as well as executable bytes. Removed shader libraries
        # can otherwise survive an incremental build as stale copied resources.
        for path in sorted(args.app.rglob('*')):
            if path.is_file() and not path.is_symlink():
                check_file(path)
        libraries = sorted({p.name for p in args.app.rglob('*.metallib')})
        if libraries != ['FrameBudget.metallib', 'default.metallib']:
            raise SystemExit(f'Unexpected bundled shader libraries: {libraries}')
    print(f'Public surface checks passed ({count} runtime files).')


if __name__ == '__main__':
    main()
