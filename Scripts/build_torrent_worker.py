#!/usr/bin/env python3
"""Prepare a hash-pinned source-plus-patch TorrServer build; never launch it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


def verified(path, size, digest):
    return (path.is_file() and not path.is_symlink() and path.stat().st_size == size
            and hashlib.sha256(path.read_bytes()).hexdigest() == digest)


def run(arguments, **options):
    subprocess.run(arguments, check=True, **options)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-directory', type=Path)
    parser.add_argument('--rebuild', action='store_true', help='build from verified source even if a verified binary is cached')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    resources = root / 'Apps/Mac/Resources/Torrent'
    if not (resources / 'worker-manifest.json').exists():
        # The same build script accompanies the source in an app's Torrent
        # resource folder, so a copied resource bundle is independently usable.
        resources = Path(__file__).resolve().parent
        root = resources.parent
    manifest_path = resources / 'worker-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    version = manifest['worker_version']
    source_name, patch_name = manifest['source_name'], manifest['patch_name']
    dependency_name = manifest['dependency_source_name']
    dependency_patch_name = manifest['dependency_patch_name']
    for name in (source_name, patch_name, dependency_name, dependency_patch_name):
        if Path(name).name != name or name in ('', '.', '..'):
            raise ValueError('manifest source filenames must be simple basenames')
    patch = resources / patch_name
    if not verified(patch, manifest['patch_bytes'], manifest['patch_sha256']):
        raise ValueError('source patch failed its pinned size/SHA-256 verification')
    dependency_patch = resources / dependency_patch_name
    if not verified(dependency_patch, manifest['dependency_patch_bytes'], manifest['dependency_patch_sha256']):
        raise ValueError('dependency patch failed its pinned size/SHA-256 verification')
    output = args.output_directory or root / '.build/torrent-worker' / version / 'Resources/Torrent'
    output.mkdir(parents=True, exist_ok=True)
    output = output.resolve()
    names = ['TorrServer', source_name, patch_name, dependency_name, dependency_patch_name,
             'worker-manifest.json', 'build_torrent_worker.py', 'LICENSE', 'NOTICE']
    for name in names:
        target = output / name
        if target.is_symlink() or target.is_dir():
            raise ValueError('output must be a regular file: ' + str(target))
    for name in ('LICENSE', 'NOTICE'):
        if not (resources / name).is_file():
            raise ValueError('missing source resource: ' + name)
    with tempfile.TemporaryDirectory(prefix='.prepare-torrent-worker.', dir=output) as temporary:
        staging = Path(temporary)
        source = staging / source_name
        cached_sources = [output / source_name, resources / source_name,
                          root / '.build/torrent-worker/MatriX.147/Resources/Torrent' / source_name]
        for cached in cached_sources:
            if verified(cached, manifest['source_bytes'], manifest['source_sha256']):
                shutil.copyfile(cached, source)
                break
        else:
            run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3',
                 '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
                 '--output', str(source), manifest['source_url']])
        if not verified(source, manifest['source_bytes'], manifest['source_sha256']):
            raise ValueError('upstream source failed its pinned size/SHA-256 verification')
        dependency = staging / dependency_name
        default_cache = root / '.build/torrent-worker' / version / 'Resources/Torrent'
        for cached in (output / dependency_name, resources / dependency_name, default_cache / dependency_name):
            if verified(cached, manifest['dependency_source_bytes'], manifest['dependency_source_sha256']):
                shutil.copyfile(cached, dependency)
                break
        else:
            run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3',
                 '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2', '--output', str(dependency),
                 manifest['dependency_source_url']])
        if not verified(dependency, manifest['dependency_source_bytes'], manifest['dependency_source_sha256']):
            raise ValueError('pinned torrent dependency source failed its size/SHA-256 verification')
        worker = staging / 'TorrServer'
        for cached in (() if args.rebuild else (output / 'TorrServer', default_cache / 'TorrServer')):
            if verified(cached, manifest['worker_bytes'], manifest['worker_sha256']):
                shutil.copyfile(cached, worker)
                break
        if not worker.exists():
            if not shutil.which('go'):
                raise ValueError('Go is required to rebuild the pinned torrent worker')
            environment = dict(os.environ, GOTOOLCHAIN=manifest['go_toolchain'], GOWORK='off',
                               GOFLAGS='', GOEXPERIMENT='', CGO_ENABLED='0', GOOS=manifest['goos'],
                               GOARCH=manifest['goarch'], GOARM64='v8.0')
            toolchain = subprocess.check_output(['go', 'env', 'GOVERSION'], env=environment, text=True).strip()
            if toolchain != manifest['go_toolchain']:
                raise ValueError('unexpected Go toolchain: ' + toolchain)
            extracted = staging / 'source'
            extracted.mkdir()
            run(['tar', '-xzf', str(source), '-C', str(extracted)])
            source_root = extracted / ('TorrServer-' + manifest['source_commit'])
            server = source_root / 'server'
            original = {name: (server / name).read_bytes() for name in ('go.mod', 'go.sum')}
            with patch.open('rb') as patch_input:
                run(['patch', '--batch', '--forward', '-p1', '-d', str(source_root)], stdin=patch_input)
            if any((server / name).read_bytes() != data for name, data in original.items()):
                raise ValueError('worker patch changed pinned Go dependency manifests')
            dependency_root = source_root / 'khua-torrent'
            prefix = manifest['dependency_module'] + '@' + manifest['dependency_version'] + '/'
            with zipfile.ZipFile(dependency) as archive:
                for entry in archive.infolist():
                    if not entry.filename.startswith(prefix):
                        raise ValueError('unexpected dependency archive layout')
                    relative = Path(entry.filename[len(prefix):])
                    if relative.is_absolute() or '..' in relative.parts:
                        raise ValueError('invalid dependency archive path')
                    target = dependency_root / relative
                    if entry.is_dir():
                        target.mkdir(parents=True, exist_ok=True)
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(archive.read(entry))
            with dependency_patch.open('rb') as patch_input:
                run(['patch', '--batch', '--forward', '-p1', '-d', str(dependency_root)], stdin=patch_input)
            pinned_replace = b'github.com/anacrolix/torrent v1.59.1 => github.com/tsynik/torrent v1.2.32'
            if original['go.mod'].count(pinned_replace) != 1:
                raise ValueError('expected pinned torrent dependency replacement is missing')
            expected_mod = original['go.mod'].replace(pinned_replace,
                b'github.com/anacrolix/torrent v1.59.1 => ../khua-torrent')
            (server / 'go.mod').write_bytes(expected_mod)
            run(['go', 'build', '-mod=readonly', '-trimpath', '-buildvcs=false', '-tags=nosqlite',
                 '-ldflags=-s -w -checklinkname=0 -buildid= -X server/version.Version=' + version,
                 '-o', str(worker), './cmd'], cwd=server, env=environment)
            if (server / 'go.mod').read_bytes() != expected_mod or (server / 'go.sum').read_bytes() != original['go.sum']:
                raise ValueError('building changed dependencies beyond the declared local source replacement')
            if not verified(worker, manifest['worker_bytes'], manifest['worker_sha256']):
                raise ValueError('rebuilt worker failed its pinned size/SHA-256 verification')
        for name in (patch_name, dependency_patch_name, 'worker-manifest.json', 'LICENSE', 'NOTICE'):
            shutil.copyfile(resources / name, staging / name)
        shutil.copyfile(Path(__file__).resolve(), staging / 'build_torrent_worker.py')
        for name in names:
            os.chmod(staging / name, 0o755 if name == 'TorrServer' else 0o644)
        # Verify all inputs before replacing any previous deliverable.
        for name in names:
            os.replace(staging / name, output / name)
    print('Prepared pinned TorrServer ' + version + ': ' + str(output))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit('error: ' + str(error))
