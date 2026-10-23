#!/usr/bin/env python3
"""Verify the packaged app's Mach-O closure and reproducibility metadata."""

from __future__ import annotations

import argparse
import base64
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from typing import Iterable
from urllib.parse import urlsplit

import build_manifest


class BundleError(RuntimeError):
    pass


def run(command: list[str]) -> str:
    result = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if result.returncode != 0:
        raise BundleError(f"command failed ({result.returncode}): {' '.join(command)}\n{result.stdout}")
    return result.stdout


def is_macho(path: Path) -> bool:
    result = subprocess.run(
        ["/usr/bin/file", "-b", str(path)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.returncode == 0 and "Mach-O" in result.stdout


def find_machos(app: Path) -> list[Path]:
    contents = app / "Contents"
    result = [path for path in contents.rglob("*") if path.is_file() and is_macho(path)]
    return sorted(result, key=lambda path: path.as_posix())


def parse_dependencies(path: Path) -> list[str]:
    lines = run(["otool", "-L", str(path)]).splitlines()[1:]
    dependencies: list[str] = []
    for line in lines:
        match = re.match(r"\s*(.+?)\s+\(compatibility version", line)
        if match:
            dependencies.append(match.group(1))
    try:
        image_id = run(["otool", "-D", str(path)]).splitlines()[1]
    except (BundleError, IndexError):
        image_id = ""
    return [dependency for dependency in dependencies if dependency != image_id]


def parse_rpaths(path: Path) -> list[str]:
    lines = run(["otool", "-l", str(path)]).splitlines()
    rpaths: list[str] = []
    in_rpath = False
    for line in lines:
        stripped = line.strip()
        if stripped == "cmd LC_RPATH":
            in_rpath = True
        elif in_rpath and stripped.startswith("path "):
            rpaths.append(stripped[5:].split(" (offset", 1)[0])
            in_rpath = False
        elif stripped.startswith("cmd "):
            in_rpath = False
    return rpaths


def expand_token(path: str, loader: Path, executable_dir: Path) -> Path | None:
    if path == "@loader_path":
        return loader.parent
    if path.startswith("@loader_path/"):
        return loader.parent / path[len("@loader_path/") :]
    if path == "@executable_path":
        return executable_dir
    if path.startswith("@executable_path/"):
        return executable_dir / path[len("@executable_path/") :]
    if path.startswith("/"):
        return Path(path)
    return None


def ensure_inside_app(candidate: Path, app: Path, dependency: str) -> Path:
    resolved = candidate.resolve()
    try:
        resolved.relative_to(app.resolve())
    except ValueError as exc:
        raise BundleError(f"dependency escapes app bundle: {dependency} -> {resolved}") from exc
    if not resolved.is_file():
        raise BundleError(f"bundle dependency is missing: {dependency} -> {resolved}")
    return resolved


def resolve_dependency(
    dependency: str,
    image: Path,
    app: Path,
    executable_dir: Path,
    image_rpaths: Iterable[str],
    executable_rpaths: Iterable[str],
) -> Path | None:
    if dependency.startswith("/usr/lib/") or dependency.startswith("/System/Library/"):
        return None
    if dependency.startswith("/"):
        raise BundleError(f"non-system absolute dependency: {image}: {dependency}")
    if dependency.startswith("@loader_path") or dependency.startswith("@executable_path"):
        candidate = expand_token(dependency, image, executable_dir)
        if candidate is None:
            raise BundleError(f"cannot expand dependency: {dependency}")
        return ensure_inside_app(candidate, app, dependency)
    if dependency.startswith("@rpath/"):
        suffix = dependency[len("@rpath/") :]
        for rpath in list(image_rpaths) + list(executable_rpaths):
            root = expand_token(rpath, image, executable_dir)
            if root is None:
                continue
            candidate = root / suffix
            if candidate.is_file():
                return ensure_inside_app(candidate, app, dependency)
        raise BundleError(f"unresolved @rpath dependency: {image}: {dependency}")
    raise BundleError(f"unsupported relative dependency: {image}: {dependency}")


def executable_dir_for(image: Path, app: Path, default_dir: Path) -> Path:
    """Nested bundle executables (.appex) resolve @executable_path against
    their own Contents/MacOS, not the host app's."""
    for parent in image.parents:
        if parent.name == "MacOS" and parent.parent.name == "Contents":
            return parent
        if parent == app:
            break
    return default_dir


def version_tuple(version: str) -> tuple[int, ...]:
    try:
        return tuple(int(component) for component in version.split("."))
    except ValueError as exc:
        raise BundleError(f"invalid version: {version}") from exc


def verify_metallib(path: Path) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise BundleError(f"missing or empty metallib: {path}")
    description = run(["/usr/bin/file", "-b", str(path)])
    if "MetalLib executable (MacOS)" not in description:
        raise BundleError(f"invalid macOS metallib: {path}: {description.strip()}")


def verify_captions_framework(app: Path, main_bundle_id: str) -> Path:
    """The on-demand download UI must be present even without a build manifest.

    It is loaded with Bundle.load, so the normal linked-dependency closure
    cannot detect a missing embedded framework in an App Store archive.
    """
    framework = app / "Contents/Frameworks/KhuaPlayerCaptionsUI.framework"
    info_path = framework / "Resources/Info.plist"
    if not main_bundle_id:
        raise BundleError("main app has no bundle identifier")
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise BundleError(f"caption UI framework Info.plist is missing or invalid: {info_path}") from exc
    if not isinstance(info, dict):
        raise BundleError(f"caption UI framework Info.plist is not a dictionary: {info_path}")
    expected_id = f"{main_bundle_id}.CaptionsUI"
    if info.get("CFBundleIdentifier") != expected_id:
        raise BundleError(f"caption UI framework bundle identifier must be {expected_id}")
    if info.get("CFBundleExecutable") != "KhuaPlayerCaptionsUI":
        raise BundleError("caption UI framework executable must be KhuaPlayerCaptionsUI")
    binary = framework / "KhuaPlayerCaptionsUI"
    if not binary.is_file():
        raise BundleError(f"caption UI framework executable is missing: {binary}")
    return ensure_inside_app(binary, app, "KhuaPlayerCaptionsUI.framework")


def verify_update_usage_privacy(app: Path, info: dict) -> None:
    privacy_path = app / "Contents/Resources/PrivacyInfo.xcprivacy"
    try:
        with privacy_path.open("rb") as handle:
            privacy = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise BundleError("main app privacy manifest is missing or invalid") from exc
    if privacy.get("NSPrivacyTracking") is not False:
        raise BundleError("privacy manifest must not declare advertising tracking")
    if privacy.get("NSPrivacyCollectedDataTypes") != []:
        raise BundleError("Kinolet requires the neutral privacy manifest without update analytics")
    if info.get("SPUpdateUsageEnabled") is True:
        raise BundleError("Kinolet does not enable upstream update usage statistics")
    update_keys = ("SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks",
                   "SUEnableSystemProfiling", "SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed")
    if info.get("SPEnableDistributionUpdates") is not True:
        if any(name in info for name in update_keys):
            raise BundleError("disabled distribution updates must not contain Sparkle configuration")
        return
    feed, key = info.get("SUFeedURL"), info.get("SUPublicEDKey")
    if not isinstance(feed, str) or not isinstance(key, str):
        raise BundleError("distribution updates require an own feed and public key")
    try:
        url = urlsplit(feed)
        host = (url.hostname or "").lower().rstrip(".")
        url.port
    except ValueError as exc:
        raise BundleError("invalid distribution update feed URL") from exc
    if url.scheme != "https" or not host or url.username or url.password or url.fragment:
        raise BundleError("the update feed must be HTTPS without credentials or a fragment")
    if host == "khua.app" or host.endswith(".khua.app"):
        raise BundleError("the upstream Khua update feed cannot be used by Kinolet")
    if key == "d8nyI3ZvaY4fTRHzcLYyygiRagGoGRdObweyoAARQ+0=":
        raise BundleError("the upstream Khua update key cannot be used by Kinolet")
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid_key = False
    if not valid_key:
        raise BundleError("the update public key must encode a 32-byte Ed25519 key")
    if (info.get("SUEnableAutomaticChecks") is not True
            or info.get("SUEnableSystemProfiling") is not False
            or info.get("SUVerifyUpdateBeforeExtraction") is not True
            or info.get("SURequireSignedFeed") is not True):
        raise BundleError("distribution updates require signed feeds, verified extraction and profiling off")


def verify_bundle(
    app: Path,
    lock_path: Path,
    stamps: dict[str, Path],
    verify_codesign: bool = True,
    verify_embedded_manifest: bool = True,
    licenses_dir: Path | None = None,
) -> None:
    if not app.is_dir():
        raise BundleError(f"app does not exist: {app}")
    lock = build_manifest.read_json(lock_path)
    target = lock.get("target", {})
    expected_arch = str(target.get("arch", ""))
    maximum_minos = str(target.get("macos_min", ""))
    if not expected_arch or not maximum_minos:
        raise BundleError("dependency lock has no target arch/minos")

    info_path = app / "Contents/Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise BundleError(f"invalid Info.plist: {exc}") from exc
    if str(info.get("CFBundleName", "")) != "Кинолёт":
        raise BundleError("Info.plist CFBundleName must be Кинолёт")
    if str(info.get("CFBundleDisplayName", "")) != "Кинолёт":
        raise BundleError("Info.plist CFBundleDisplayName must be Кинолёт")
    if info.get("SPProductName") != "Кинолёт":
        raise BundleError("Info.plist SPProductName must be Кинолёт for About")
    executable_name = str(info.get("CFBundleExecutable", ""))
    if executable_name != "Kinolet":
        raise BundleError("Info.plist CFBundleExecutable must be Kinolet")
    main = app / "Contents/MacOS" / executable_name
    if not main.is_file():
        raise BundleError(f"main executable missing: {main}")
    if str(info.get("LSMinimumSystemVersion", "")) != maximum_minos:
        raise BundleError("Info.plist minimum system version does not match dependency lock")
    verify_update_usage_privacy(app, info)

    main_bundle_id = str(info.get("CFBundleIdentifier", ""))
    if main_bundle_id == "app.khuaplayer.KhuaPlayer" or main_bundle_id.startswith("app.khuaplayer.KhuaPlayer."):
        raise BundleError("Kinolet must not use the upstream app bundle identifier")
    captions_binary = verify_captions_framework(app, main_bundle_id)

    for relative in build_manifest.REQUIRED_METALLIBS:
        verify_metallib(app / relative)

    machos = find_machos(app)
    if main not in machos:
        raise BundleError("main executable is not Mach-O")
    macho_set = {path.resolve() for path in machos}
    if captions_binary not in macho_set:
        raise BundleError(f"caption UI framework executable is not Mach-O: {captions_binary}")
    required_libass = app / "Contents/Frameworks/libass.9.dylib"
    if required_libass.resolve() not in macho_set:
        raise BundleError(f"required libass is not Mach-O: {required_libass}")
    executable_rpaths = parse_rpaths(main)
    max_tuple = version_tuple(maximum_minos)
    for image in machos:
        archs = run(["lipo", "-archs", str(image)]).strip().split()
        if archs != [expected_arch]:
            raise BundleError(f"wrong architecture for {image}: {' '.join(archs)}")
        build_info = run(["vtool", "-show-build", str(image)])
        minos_values = re.findall(r"^\s*minos\s+([0-9.]+)\s*$", build_info, re.MULTILINE)
        if not minos_values:
            raise BundleError(f"no LC_BUILD_VERSION minos in {image}")
        for minos in minos_values:
            if version_tuple(minos) > max_tuple:
                raise BundleError(f"minos {minos} exceeds {maximum_minos}: {image}")
        image_rpaths = parse_rpaths(image)
        image_exec_dir = executable_dir_for(image, app, main.parent)
        for dependency in parse_dependencies(image):
            resolved = resolve_dependency(
                dependency,
                image,
                app,
                image_exec_dir,
                image_rpaths,
                # Host-executable rpaths only apply to images the host loads,
                # not to nested bundles with their own executable.
                executable_rpaths if image_exec_dir == main.parent else [],
            )
            if resolved is not None and resolved.resolve() not in macho_set:
                raise BundleError(f"resolved dependency is not packaged Mach-O: {resolved}")
        if verify_codesign:
            run(["codesign", "--verify", "--strict", str(image)])

    # This also applies to Store archives, which intentionally have no manifest.
    build_manifest.verify_third_party_notices(
        app, licenses_dir if licenses_dir is not None else lock_path.parent / "Licenses"
    )
    if verify_embedded_manifest:
        build_manifest.verify_manifest(app, lock_path, stamps)
    if verify_codesign:
        run(["codesign", "--verify", "--strict", "--deep", str(app)])


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--stamp", action="append", default=[])
    parser.add_argument("--licenses", help="source notice directory (default: <lock directory>/Licenses)")
    parser.add_argument("--skip-codesign", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--skip-manifest", action="store_true", help=argparse.SUPPRESS)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = create_parser().parse_args(argv)
    try:
        verify_bundle(
            Path(args.app),
            Path(args.lock),
            build_manifest.parse_stamp_specs(args.stamp),
            not args.skip_codesign,
            not args.skip_manifest,
            Path(args.licenses) if args.licenses else None,
        )
    except (BundleError, build_manifest.ManifestError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
