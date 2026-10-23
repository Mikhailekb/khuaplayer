#!/usr/bin/env python3
"""Package a Git snapshot and verified dependency sources for a release."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
STAMP_PREFIXES = ("dav1d-min", "speex-min", "ffmpeg-min", "subtitles-min", "sparkle-min")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run(*args: str, cwd: Path | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        # The data filter rejects traversal, escaping links and special files.
        source.extractall(destination, filter="data")


def verified_archive(entry: dict, destination: Path, caches: list[Path]) -> None:
    name = entry["archive"]
    if Path(name).name != name or not entry["url"].startswith("https://"):
        raise ValueError("invalid dependency archive record")
    destination.parent.mkdir(parents=True, exist_ok=True)
    for cache in caches:
        candidate = cache / name
        if candidate.is_file() and not candidate.is_symlink() and digest(candidate) == entry["sha256"]:
            shutil.copyfile(candidate, destination)
            break
    else:
        subprocess.run([
            "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
            "--connect-timeout", "20", "--proto", "=https", "--proto-redir", "=https",
            "--output", str(destination), entry["url"],
        ], check=True)
    if digest(destination) != entry["sha256"]:
        raise ValueError("dependency archive SHA-256 mismatch: " + name)


def portable(value: object, repo: Path) -> object:
    """Retain build configuration while removing machine-specific roots."""
    if isinstance(value, dict):
        return {str(portable(key, repo)): portable(item, repo) for key, item in value.items()}
    if isinstance(value, list):
        return [portable(item, repo) for item in value]
    if isinstance(value, str):
        value = value.replace(str(repo), "${APP_SOURCE}")
        value = re.sub(r"/(?:Users|home)/[^/\s\"']+", "${BUILD_HOME}", value)
    return value


def native_sources(app: Path, bundle: Path, repo: Path, require_metadata: bool) -> dict:
    lock_path = app / "ThirdParty/deps.lock.json"
    lock = json.loads(lock_path.read_text())
    records = {}
    for name, entry in sorted(lock["dependencies"].items()):
        target = bundle / "native/archives" / entry["archive"]
        verified_archive(entry, target, [repo / "ThirdParty/downloads"])
        for patch in entry.get("patches", []):
            if digest(app / patch["path"]) != patch["sha256"]:
                raise ValueError("locked source patch mismatch: " + patch["path"])
        records[name] = {
            "version": entry["version"], "sha256": digest(target),
            "archive": target.relative_to(bundle).as_posix(), "bytes": target.stat().st_size,
        }
    licenses = sorted(path for path in (app / "ThirdParty/Licenses").rglob("*") if path.is_file())
    if len(licenses) != 21 or any(path.stat().st_size == 0 for path in licenses):
        raise ValueError("the application source must contain all 21 native third-party notice files")

    metadata = bundle / "native/build-metadata"
    stamps = []
    for prefix in STAMP_PREFIXES:
        path = repo / "ThirdParty" / prefix / ".build-stamp.json"
        if not path.is_file():
            if require_metadata:
                raise ValueError("missing release dependency build stamp: " + prefix)
            continue
        value = json.loads(path.read_text())
        if value.get("dependency_lock_sha256") != digest(lock_path):
            raise ValueError("dependency build stamp uses a different source lock: " + prefix)
        write_json(metadata / (prefix + ".json"), {
            "original_sha256": digest(path),
            "path_substitutions": {"APP_SOURCE": "app/", "BUILD_HOME": "original build home"},
            "build_stamp": portable(value, repo),
        })
        stamps.append(prefix)
    capabilities = repo / "ThirdParty/ffmpeg-min/share/ffmpeg-capabilities.json"
    if capabilities.is_file():
        write_json(metadata / "ffmpeg-capabilities.json", portable(json.loads(capabilities.read_text()), repo))
    build_manifest = repo / ".build/Build/Products/Release/Kinolet.app/Contents/Resources/BuildManifest.json"
    if build_manifest.is_file():
        application_record = json.loads(build_manifest.read_text())
        if application_record.get("dependency_lock_sha256") != digest(lock_path):
            raise ValueError("canonical Release uses a different dependency source lock")
        write_json(metadata / "application-build-manifest.json", portable(application_record, repo))
    elif require_metadata:
        raise ValueError("the canonical Release BuildManifest.json is missing")
    rebuild = bundle / "rebuild-native.sh"
    rebuild.write_text("""#!/bin/bash
set -euo pipefail
SOURCE_BUNDLE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SOURCE_BUNDLE/app/ThirdParty/downloads"
cp "$SOURCE_BUNDLE/native/archives/"* "$SOURCE_BUNDLE/app/ThirdParty/downloads/"
cd "$SOURCE_BUNDLE/app"
./Scripts/build_ffmpeg_min.sh
./Scripts/build_subtitle_libs.sh
./Scripts/build_sparkle.sh
printf '%s\\n' 'Native libraries rebuilt; regenerate/build the app to link modified libraries.'
""", encoding="utf-8")
    rebuild.chmod(0o755)
    return {"dependencies": records, "notice_file_count": len(licenses), "build_stamps": stamps}


def inventory(root: Path) -> dict:
    result = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if relative == "SOURCE_MANIFEST.json":
            continue
        if path.is_symlink():
            result[relative] = {"type": "symlink", "target": os.readlink(path)}
        elif path.is_dir():
            continue
        elif path.is_file():
            result[relative] = {"type": "file", "bytes": path.stat().st_size, "sha256": digest(path)}
        else:
            raise ValueError("unsupported source asset: " + relative)
    return result


def verify(archive: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="kinolet-source-verify.") as temporary:
        destination = Path(temporary)
        extract(archive, destination)
        children = list(destination.iterdir())
        if len(children) != 1 or not children[0].is_dir():
            raise ValueError("source archive must contain one root directory")
        bundle = children[0]
        value = json.loads((bundle / "SOURCE_MANIFEST.json").read_text())
        if value["files"] != inventory(bundle):
            raise ValueError("source archive file inventory/SHA-256 mismatch")
        lock = json.loads((bundle / "app/ThirdParty/deps.lock.json").read_text())
        for name, entry in lock["dependencies"].items():
            record = value["native"]["dependencies"][name]
            if record["sha256"] != entry["sha256"] or digest(bundle / record["archive"]) != entry["sha256"]:
                raise ValueError("source archive native lock mismatch: " + name)
        worker_manifest = json.loads((bundle / "app/Apps/Mac/Resources/Torrent/worker-manifest.json").read_text())
        for key in ("source", "patch", "dependency_source", "dependency_patch"):
            original = bundle / "worker/inputs" / worker_manifest[key + "_name"]
            if original.stat().st_size != worker_manifest[key + "_bytes"] or digest(original) != worker_manifest[key + "_sha256"]:
                raise ValueError("source archive worker input mismatch: " + key)
        if value["worker"].get("build_verified") is not True or value["worker"].get("worker_sha256") != worker_manifest["worker_sha256"]:
            raise ValueError("source archive lacks canonical offline worker rebuild proof")
        modules = json.loads((bundle / "worker/go-modules.json").read_text())
        if modules["module_count"] != len(modules["modules"]) or modules["module_count"] != value["worker"]["module_count"]:
            raise ValueError("source archive Go module inventory mismatch")
        for record in modules["proxy_files"]:
            path = bundle / "worker" / record["path"]
            if path.stat().st_size != record["bytes"] or digest(path) != record["sha256"]:
                raise ValueError("source archive offline Go proxy checksum mismatch")
        return value


def archive_tree(root: Path, destination: Path, epoch: int) -> None:
    with destination.open("wb") as handle:
        with gzip.GzipFile(fileobj=handle, mode="wb", filename="", mtime=0, compresslevel=6) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for path in [root, *sorted(root.rglob("*"))]:
                    record = archive.gettarinfo(str(path), arcname=(Path(root.name) / path.relative_to(root)).as_posix())
                    record.uid = record.gid = 0
                    record.uname = record.gname = ""
                    record.mtime = epoch
                    record.pax_headers = {}
                    if record.isfile():
                        record.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                        with path.open("rb") as source:
                            archive.addfile(record, source)
                    else:
                        record.mode = 0o755 if record.isdir() else 0o777
                        archive.addfile(record)


def package(args: argparse.Namespace) -> None:
    output = args.output.resolve()
    if not output.name.endswith("-source.tar.gz"):
        raise ValueError("output must end with -source.tar.gz")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError("refusing to replace an existing release source archive")
    commit = run("git", "rev-parse", "HEAD", cwd=ROOT)
    epoch = int(run("git", "show", "-s", "--format=%ct", "HEAD", cwd=ROOT))
    if os.environ.get("GITHUB_SHA") and os.environ["GITHUB_SHA"] != commit:
        raise ValueError("source commit differs from the CI build commit")
    with tempfile.TemporaryDirectory(prefix="kinolet-release-sources.") as temporary:
        scratch = Path(temporary)
        bundle = scratch / output.name.removesuffix(".tar.gz")
        app = bundle / "app"
        snapshot = scratch / "application.tar"
        subprocess.run(["git", "archive", "--format=tar", "--output", str(snapshot), commit], cwd=ROOT, check=True)
        extract(snapshot, app)
        project = (app / "Apps/Mac/project.yml").read_text()
        version_match = re.search(r'^\s+MARKETING_VERSION:\s*"?([0-9.]+)"?\s*$', project, re.MULTILINE)
        if not version_match or output.name != f"Kinolet-{version_match.group(1)}-source.tar.gz":
            raise ValueError("source archive filename must match the archived application version")
        native = native_sources(app, bundle, ROOT, args.require_build_metadata)
        spec = importlib.util.spec_from_file_location("release_worker_sources", ROOT / "Scripts/lib/release_worker_sources.py")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        worker_manifest = json.loads((app / "Apps/Mac/Resources/Torrent/worker-manifest.json").read_text())
        caches = [*args.worker_cache,
                  ROOT / ".build/torrent-worker" / worker_manifest["worker_version"] / "Resources/Torrent",
                  ROOT / ".build/Build/Products/Release/Kinolet.app/Contents/Resources/Torrent"]
        worker = helper.prepare_worker_sources(app, bundle / "worker", caches, verify_rebuild=True)
        (bundle / "README.md").write_text("""# Kinolet release source and rebuild materials

`app/` is the complete Git archive of the commit recorded in SOURCE_MANIFEST.json.
It includes the application, shaders, native build/link recipes, patches and
all 21 native third-party notice files. `native/archives/` contains every locked
native source archive, verified against app/ThirdParty/deps.lock.json. Native
build reports use portable placeholders in place of machine-specific roots.

On macOS, install Xcode with the macOS SDK and the build tools described in
app/ThirdParty/README.md. Run `./rebuild-native.sh` to restore verified offline
source archives to the recipe cache and rebuild the native libraries. To link
modified libraries into an application, run app/Apps/Mac/Scripts/build.sh Debug
from app/ after regenerating the project. Release uses the same link recipes
and additionally performs local installation/registration. These are local
ad-hoc builds; distribution certificates are not required. The SDK and compiler
toolchains themselves are prerequisites, not included in this source archive.

`worker/` contains the patched TorrServer source, its local torrent dependency,
project-scoped Go dependency sources and licenses, original pinned source inputs
and an offline worker rebuild recipe. Follow worker/README.md. No global Go
cache is included. Application source and native dependencies can be modified
and relinked using the included project and source build recipes; this archive
does not promise byte-identical native libraries across different Xcode paths.

Verify the extracted file inventory with the packaging script's --verify mode.
SOURCE_MANIFEST.json records every included file's SHA-256 and the exact source
commit. The adjacent release manifest records the compressed archive SHA-256.
""", encoding="utf-8")
        write_json(bundle / "SOURCE_MANIFEST.json", {
            "schema": 1, "source_commit": commit, "source_date_epoch": epoch,
            "native": native, "worker": worker, "files": inventory(bundle),
        })
        candidate = scratch / output.name
        archive_tree(bundle, candidate, epoch)
        checked = verify(candidate)
        staged_output = output.with_name("." + output.name + ".tmp")
        shutil.copyfile(candidate, staged_output)
        os.replace(staged_output, output)
        sidecar = output.with_name(output.name.removesuffix(".tar.gz") + ".manifest.json")
        write_json(sidecar, {
            "schema": 1, "archive": output.name, "sha256": digest(output),
            "bytes": output.stat().st_size, "source_commit": commit,
            "file_count": len(checked["files"]), "native": native, "worker": worker,
        })
    print("Packaged and verified release sources:", output)
    print("Source archive SHA-256:", digest(output))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--output", type=Path)
    action.add_argument("--verify", type=Path)
    parser.add_argument("--worker-cache", type=Path, action="append", default=[])
    parser.add_argument("--require-build-metadata", action="store_true")
    args = parser.parse_args()
    if args.verify:
        value = verify(args.verify.resolve())
        print("Verified source archive:", value["source_commit"], len(value["files"]), "files")
    else:
        package(args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, tarfile.TarError, subprocess.CalledProcessError) as error:
        raise SystemExit("error: " + str(error))
