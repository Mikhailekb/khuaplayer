#!/usr/bin/env python3
"""Prepare complete, offline-rebuildable source for the pinned torrent worker."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import zipfile


class WorkerSourceError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _verified(path: Path, size: int, digest: str) -> bool:
    return (path.is_file() and not path.is_symlink()
            and path.stat().st_size == size and _sha256(path) == digest)


def _objects(data: str) -> list[dict]:
    decoder = json.JSONDecoder()
    values = []
    while data.strip():
        data = data.lstrip()
        value, end = decoder.raw_decode(data)
        if not isinstance(value, dict):
            raise WorkerSourceError("unexpected Go module resolution output")
        if value.get("Error"):
            raise WorkerSourceError("Go module resolution failed: " + str(value["Error"]))
        values.append(value)
        data = data[end:]
    return values


def _run(arguments: list[str], **options) -> str:
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, **options)
    if result.returncode:
        raise WorkerSourceError(result.stderr.strip() or result.stdout.strip()
                                or "command failed: " + arguments[0])
    return result.stdout


def _escaped(value: str) -> str:
    # Go module proxy paths encode each ASCII uppercase letter as !lowercase.
    return "".join("!" + character.lower() if "A" <= character <= "Z" else character
                   for character in value)


def _safe_relative(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value:
        raise WorkerSourceError("unsafe source archive path")
    return path


def _copy_pinned(name: str, key: str, manifest: dict, resources: Path,
                 caches: list[Path], output: Path) -> None:
    if Path(name).name != name or name in ("", ".", ".."):
        raise WorkerSourceError("manifest source filenames must be simple basenames")
    size, digest = manifest[key + "_bytes"], manifest[key + "_sha256"]
    for cache in [resources, *caches]:
        candidates = [cache] if cache.is_file() else [
            cache / name, cache / "Resources/Torrent" / name,
            cache / "Contents/Resources/Torrent" / name,
            cache / manifest["worker_version"] / "Resources/Torrent" / name,
            cache / "MatriX.147/Resources/Torrent" / name,
            cache / ".build/torrent-worker" / manifest["worker_version"] / "Resources/Torrent" / name,
            cache / ".build/torrent-worker/MatriX.147/Resources/Torrent" / name,
        ]
        if cache.is_dir():
            candidates.extend(sorted(cache.glob("*/Resources/Torrent/" + name)))
        for candidate in candidates:
            if _verified(candidate, size, digest):
                shutil.copyfile(candidate, output)
                return
    url = manifest[key + "_url"]
    if not url.startswith("https://"):
        raise WorkerSourceError("pinned source URL must use HTTPS")
    _run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
          "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
          "--output", str(output), url])
    if not _verified(output, size, digest):
        raise WorkerSourceError("download failed pinned size/SHA-256 verification: " + name)


def _environment(temporary: Path, manifest: dict, proxies: list[Path]) -> dict[str, str]:
    environment = dict(os.environ)
    environment.update({
        "GOENV": "off", "GOTOOLCHAIN": "local", "GOWORK": "off", "GOFLAGS": "",
        "GOCACHEPROG": "", "GO111MODULE": "on", "GOFIPS140": "off",
        "GOEXPERIMENT": "", "CGO_ENABLED": "0", "GOOS": manifest["goos"],
        "GOARCH": manifest["goarch"], "GOARM64": "v8.0",
        "GOPATH": str(temporary / "gopath"), "GOMODCACHE": str(temporary / "modules"),
        "GOCACHE": str(temporary / "build-cache"), "GOPRIVATE": "", "GONOPROXY": "",
        "GONOSUMDB": "", "GOSUMDB": "sum.golang.org",
        "GOPROXY": ",".join([path.resolve().as_uri() for path in proxies]
                            + ["https://proxy.golang.org"]),
    })
    return environment


def _offline_script(manifest: dict) -> str:
    # Python supplies portable file-URI escaping and SHA-256 without relying on
    # a particular platform's shasum utility. The Go build itself has no network
    # fallback, no inherited module/build cache, and no toolchain auto-download.
    configuration = json.dumps({key: manifest[key] for key in
                                ("go_toolchain", "goos", "goarch", "worker_version",
                                 "worker_bytes", "worker_sha256")}, sort_keys=True)
    return '''#!/bin/sh
set -eu
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 - "$script_directory" "${1:-}" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1]).resolve()
configuration = CONFIGURATION
output = pathlib.Path(sys.argv[2]).resolve() if sys.argv[2] else root / "rebuilt/TorrServer"
inventory = json.loads((root / "go-modules.json").read_text())
for item in inventory["proxy_files"]:
    relative = pathlib.PurePosixPath(item["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit("invalid offline module proxy path")
    path = root / relative
    if not path.is_file() or path.is_symlink() or path.stat().st_size != item["bytes"]:
        raise SystemExit("offline module proxy file missing or changed: " + item["path"])
    if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
        raise SystemExit("offline module proxy checksum mismatch: " + item["path"])
with tempfile.TemporaryDirectory(prefix="kinolet-worker-rebuild-") as temporary_name:
    temporary = pathlib.Path(temporary_name)
    environment = dict(os.environ, GOENV="off", GOTOOLCHAIN="local", GOWORK="off",
        GOFLAGS="", GOEXPERIMENT="", GOCACHEPROG="", GO111MODULE="on", GOFIPS140="off",
        CGO_ENABLED="0", GOOS=configuration["goos"],
        GOARCH=configuration["goarch"], GOARM64="v8.0", GOPRIVATE="", GONOPROXY="",
        GONOSUMDB="", GOSUMDB="off", GOVCS="*:off", GOPATH=str(temporary / "gopath"),
        GOMODCACHE=str(temporary / "modules"), GOCACHE=str(temporary / "build-cache"),
        GOPROXY=(root / "go-proxy").as_uri())
    version = subprocess.check_output(["go", "env", "GOVERSION"], env=environment, text=True).strip()
    if version != configuration["go_toolchain"]:
        raise SystemExit("install " + configuration["go_toolchain"] + "; found " + version)
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false",
        "-tags=nosqlite", "-ldflags=-s -w -checklinkname=0 -buildid= -X server/version.Version="
        + configuration["worker_version"], "-o", str(output), "./cmd"],
        cwd=root / "source/server", env=environment, check=True)
digest = hashlib.sha256(output.read_bytes()).hexdigest()
if output.stat().st_size != configuration["worker_bytes"] or digest != configuration["worker_sha256"]:
    raise SystemExit("rebuilt worker does not match pinned unsigned worker: " + digest)
print("Rebuilt pinned unsigned worker SHA-256 " + digest)
PY
'''.replace("CONFIGURATION", configuration)


def _readme(manifest: dict, module_count: int) -> str:
    return f'''# Pinned TorrServer worker source

This folder contains the source inputs for {manifest["worker_version"]}, its
patched source tree, and a project-scoped offline Go module proxy.

Install {manifest["go_toolchain"]} and Python 3 before disconnecting from the
network. From this folder run:

```sh
./offline-rebuild.sh /path/to/output/TorrServer
```

Without an output argument, the executable is written to `rebuilt/TorrServer`.
The recipe creates empty temporary Go module/build caches, disables toolchain
downloads and network module fallbacks, and builds `source/server` using
`-mod=readonly`, `-trimpath`, `-buildvcs=false`, `-tags=nosqlite`, CGO disabled,
GOOS={manifest["goos"]}, GOARCH={manifest["goarch"]}, and GOARM64=v8.0. It verifies
the unsigned executable against {manifest["worker_bytes"]} bytes and SHA-256
`{manifest["worker_sha256"]}`. Signing an executable changes its bytes.

`inputs/worker-manifest.json` identifies the exact upstream commit, archive
digests, two downstream patches, compiler, and unsigned binary digest. Original
archives, patches, LICENSE, NOTICE, and the original online preparation recipe
are retained in `inputs/`. The only Go manifest change in the patched source is
the existing torrent replacement pointing to the adjacent `khua-torrent` source;
the upstream `go.sum` is unchanged.

`go-proxy/` contains complete ZIP, .mod, and .info files for the {module_count}
remote versions in this project's selected module graph. Complete source ZIPs
retain upstream license/notice files, including files outside compiled packages.
`go-modules.json` lists module versions, Go checksums, and SHA-256 for proxy
files. No unrelated global Go cache or private path is needed for the rebuild.

`source/server/vendor/` is included for inspection and source navigation.
Building with `-mod=vendor` changes embedded Go module-checksum metadata and
does not produce the pinned executable; the canonical recipe uses the offline
file proxy and `-mod=readonly`.

For modified source, use the compiler environment and command shown in
`offline-rebuild.sh`, adapting the final expected-digest check for your modified
output. That check intentionally certifies only the original pinned build.
The source retains its component licenses and notices; consult those files for
their terms.
'''


def prepare_worker_sources(app_source: Path, destination: Path,
                           input_caches: list[Path], verify_rebuild: bool = True) -> dict:
    """Build a source bundle from an archived app checkout, never its worktree.

    The offline proxy includes only versions in this project's selected module
    graph. Full module ZIPs preserve every upstream file and license; vendor is
    included for inspection, while the canonical recipe uses -mod=readonly so
    Go retains the exact module-checksum BuildInfo of the pinned worker.
    """
    app_source, destination = Path(app_source).resolve(), Path(destination).resolve()
    resources = app_source / "Apps/Mac/Resources/Torrent"
    manifest = json.loads((resources / "worker-manifest.json").read_text())
    if destination.exists() and any(destination.iterdir()):
        raise WorkerSourceError("worker source destination must be empty")
    destination.mkdir(parents=True, exist_ok=True)
    inputs = destination / "inputs"
    inputs.mkdir()
    for key in ("patch", "dependency_patch"):
        name = manifest[key + "_name"]
        if Path(name).name != name or not _verified(resources / name,
                manifest[key + "_bytes"], manifest[key + "_sha256"]):
            raise WorkerSourceError("source patch failed pinned verification: " + name)
        shutil.copyfile(resources / name, inputs / name)
    for key in ("source", "dependency_source"):
        _copy_pinned(manifest[key + "_name"], key, manifest, resources,
                     [Path(path) for path in input_caches], inputs / manifest[key + "_name"])
    for name in ("worker-manifest.json", "LICENSE", "NOTICE"):
        if not (resources / name).is_file() or (resources / name).is_symlink():
            raise WorkerSourceError("missing source resource: " + name)
        shutil.copyfile(resources / name, inputs / name)
    shutil.copyfile(app_source / "Scripts/build_torrent_worker.py", inputs / "build_torrent_worker.py")

    with tempfile.TemporaryDirectory(prefix=".worker-source-build-", dir=destination.parent) as name:
        temporary = Path(name)
        with tarfile.open(inputs / manifest["source_name"], "r:gz") as archive:
            prefix = "TorrServer-" + manifest["source_commit"]
            for entry in archive.getmembers():
                relative = _safe_relative(entry.name)
                if not relative.parts or relative.parts[0] != prefix or not (entry.isfile() or entry.isdir()):
                    raise WorkerSourceError("unexpected TorrServer archive layout")
            archive.extractall(temporary, filter="data")
        source = destination / "source"
        shutil.move(str(temporary / prefix), source)
        server = source / "server"
        original = {name: (server / name).read_bytes() for name in ("go.mod", "go.sum")}
        _run(["patch", "--batch", "--forward", "-p1", "-d", str(source),
              "-i", str(inputs / manifest["patch_name"])])
        if any((server / name).read_bytes() != content for name, content in original.items()):
            raise WorkerSourceError("worker patch changed pinned Go manifests")
        dependency = source / "khua-torrent"
        prefix = manifest["dependency_module"] + "@" + manifest["dependency_version"] + "/"
        with zipfile.ZipFile(inputs / manifest["dependency_source_name"]) as archive:
            for entry in archive.infolist():
                if not entry.filename.startswith(prefix):
                    raise WorkerSourceError("unexpected torrent dependency archive layout")
                relative = _safe_relative(entry.filename[len(prefix):])
                target = dependency.joinpath(*relative.parts)
                if entry.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(archive.read(entry))
        _run(["patch", "--batch", "--forward", "-p1", "-d", str(dependency),
              "-i", str(inputs / manifest["dependency_patch_name"])])
        old = ("github.com/anacrolix/torrent v1.59.1 => " + manifest["dependency_module"]
               + " " + manifest["dependency_version"]).encode()
        if original["go.mod"].count(old) != 1:
            raise WorkerSourceError("expected pinned torrent replacement is missing")
        expected_mod = original["go.mod"].replace(old,
            b"github.com/anacrolix/torrent v1.59.1 => ../khua-torrent")
        (server / "go.mod").write_bytes(expected_mod)
        proxies = []
        # A cache is read as a proxy and only selected module versions are copied.
        # It is never included wholesale in the release source distribution.
        go_cache = _run(["go", "env", "GOMODCACHE"], env=dict(os.environ, GOENV="off",
                       GOTOOLCHAIN="local", GOWORK="off")).strip()
        for cache in [*input_caches, Path(go_cache)]:
            cache = Path(cache)
            for candidate in (cache / "go-proxy", cache / "cache/download", cache):
                if candidate.is_dir() and (candidate / "github.com").is_dir():
                    proxies.append(candidate)
                    break
        environment = _environment(temporary, manifest, list(dict.fromkeys(proxies)))
        if _run(["go", "env", "GOVERSION"], cwd=server, env=environment).strip() != manifest["go_toolchain"]:
            raise WorkerSourceError("install the pinned Go toolchain: " + manifest["go_toolchain"])
        graph = _objects(_run(["go", "list", "-mod=readonly", "-m", "-json", "all"],
                              cwd=server, env=environment))
        versions = sorted({effective["Path"] + "@" + effective["Version"]
                           for module in graph
                           for effective in [module.get("Replace", module)]
                           if effective.get("Version")})
        # Explicit versions from outside the module leave source go.sum untouched.
        downloaded = _objects(_run(["go", "mod", "download", "-json", *versions],
                                   cwd=temporary, env=environment))
        proxy_files, modules = [], []
        proxy = destination / "go-proxy"
        for module in sorted(downloaded, key=lambda value: (value["Path"], value["Version"])):
            module_path = _escaped(module["Path"]) + "/@v/" + _escaped(module["Version"])
            _safe_relative(module_path)
            record = {key.lower(): module[key] for key in ("Path", "Version", "Sum", "GoModSum")}
            for extension, key in (("zip", "Zip"), ("mod", "GoMod"), ("info", "Info")):
                original_file = Path(module[key])
                output = proxy / (module_path + "." + extension)
                output.parent.mkdir(parents=True, exist_ok=True)
                if extension == "info":
                    # Cache acquisition metadata (Origin/URL) can contain local
                    # checkout paths and differs between proxy/VCS fetches. Go
                    # needs only these public version fields from a file proxy.
                    info = json.loads(original_file.read_text())
                    if info.get("Version") != module["Version"] or not isinstance(info.get("Time"), str):
                        raise WorkerSourceError("unexpected Go module version metadata")
                    output.write_text(json.dumps({key: info[key] for key in ("Version", "Time")},
                                                 sort_keys=True, separators=(",", ":")) + "\n")
                else:
                    shutil.copyfile(original_file, output)
                proxy_files.append({"path": output.relative_to(destination).as_posix(),
                                    "bytes": output.stat().st_size, "sha256": _sha256(output)})
            modules.append(record)
        _run(["go", "mod", "vendor"], cwd=server, env=environment)
        if (server / "go.mod").read_bytes() != expected_mod or (server / "go.sum").read_bytes() != original["go.sum"]:
            raise WorkerSourceError("source preparation changed pinned Go manifests")
        inventory = {"schema": 1, "module_count": len(modules), "modules": modules,
                     "proxy_files": sorted(proxy_files, key=lambda value: value["path"])}
        (destination / "go-modules.json").write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n")
        script = destination / "offline-rebuild.sh"
        script.write_text(_offline_script(manifest))
        script.chmod(0o755)
        (destination / "README.md").write_text(_readme(manifest, len(modules)))
        if verify_rebuild:
            _run([str(script), str(temporary / "verify/TorrServer")], cwd=temporary)
            if not _verified(temporary / "verify/TorrServer", manifest["worker_bytes"], manifest["worker_sha256"]):
                raise WorkerSourceError("offline rebuild failed pinned unsigned worker verification")
        if (server / "go.mod").read_bytes() != expected_mod or (server / "go.sum").read_bytes() != original["go.sum"]:
            raise WorkerSourceError("offline rebuild changed pinned Go manifests")
    return {"schema": 1, "worker_version": manifest["worker_version"],
            "worker_bytes": manifest["worker_bytes"], "worker_sha256": manifest["worker_sha256"],
            "go_toolchain": manifest["go_toolchain"], "source_commit": manifest["source_commit"],
            "source_path": "source", "inputs_path": "inputs", "offline_proxy_path": "go-proxy",
            "module_inventory": "go-modules.json", "module_count": len(modules),
            "proxy_file_count": len(proxy_files), "vendor_file_count": sum(
                path.is_file() for path in (server / "vendor").rglob("*")),
            "offline_rebuild_script": "offline-rebuild.sh", "build_verified": verify_rebuild,
            "readme": "README.md",
            "license_preservation": "complete pinned source archives and complete selected Go module ZIPs"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--input-cache", type=Path, action="append", default=[])
    parser.add_argument("--skip-verify-rebuild", action="store_true")
    args = parser.parse_args()
    result = prepare_worker_sources(args.app_source, args.destination, args.input_cache,
                                    not args.skip_verify_rebuild)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
