#!/usr/bin/env python3
"""Export the Kinolet prism AppIcon without altering its source artwork."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import tempfile
from pathlib import Path

try:
    import PIL
    from PIL import Image, PngImagePlugin
except ModuleNotFoundError as error:
    raise SystemExit(
        "Pillow is required. Install it with: python3 -m pip install Pillow"
    ) from error


ROOT = Path(__file__).resolve().parent
DEFAULT_MASTER = ROOT / "Kinolet-Prism-Master.png"
DEFAULT_OUTPUT = ROOT / "AppIcon.appiconset"
DEFAULT_MANIFEST = ROOT / "export-manifest.json"
DEFAULT_ICNS = ROOT / "AppIcon.icns"
SIZES = (16, 32, 64, 128, 256, 512, 1024)
ICNS_ENTRIES = (
    (b"icp4", 16), (b"icp5", 32),
    (b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
    (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
)

CONTENTS = {
    "images": [
        {"filename": "AppIcon-16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
        {"filename": "AppIcon-32.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
        {"filename": "AppIcon-32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
        {"filename": "AppIcon-64.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
        {"filename": "AppIcon-128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
        {"filename": "AppIcon-256.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
        {"filename": "AppIcon-256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
        {"filename": "AppIcon-512.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
        {"filename": "AppIcon-512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
        {"filename": "AppIcon-1024.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
    ],
    "info": {"author": "xcode", "version": 1},
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_json(value: object) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=True) + "\n").encode("utf-8")


def atomic_write(path: Path, contents: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_bytes(contents)
    os.replace(temporary, path)


def save_png(image: Image.Image, path: Path) -> None:
    # A standard sRGB chunk has fixed bytes, unlike a newly created ICC profile
    # whose creation timestamp would make otherwise identical exports differ.
    metadata = PngImagePlugin.PngInfo()
    metadata.add(b"sRGB", b"\x00")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    image.save(
        temporary,
        format="PNG",
        optimize=True,
        compress_level=9,
        pnginfo=metadata,
    )
    os.replace(temporary, path)


def validate_master(master_path: Path) -> Image.Image:
    source = Image.open(master_path)
    source.load()
    if source.width != source.height or source.width < 1024:
        raise SystemExit(f"Master must be square and at least 1024 px; found {source.size}")
    if source.mode != "RGBA":
        raise SystemExit(f"Master must be an RGBA PNG; found {source.mode}")
    alpha = source.getchannel("A")
    corners = ((0, 0), (source.width - 1, 0),
               (0, source.height - 1), (source.width - 1, source.height - 1))
    if alpha.getextrema() != (0, 255) or any(alpha.getpixel(point) for point in corners):
        raise SystemExit("Master must preserve transparent corners and visible opaque artwork")
    return source


def write_icns(output: Path, icns_path: Path) -> dict[str, object]:
    # ICNS accepts PNG-backed entries. Wrapping the canonical PNG bytes directly
    # avoids platform-dependent re-encoding and retains alpha at every size.
    chunks = []
    for kind, size in ICNS_ENTRIES:
        png = (output / f"AppIcon-{size}.png").read_bytes()
        chunks.append(kind + struct.pack(">I", len(png) + 8) + png)
    payload = b"".join(chunks)
    atomic_write(icns_path, b"icns" + struct.pack(">I", len(payload) + 8) + payload)
    return {
        "file": icns_path.name,
        "sha256": sha256(icns_path),
        "format": "ICNS with unchanged canonical PNG entries",
        "entries": [kind.decode("ascii") for kind, _ in ICNS_ENTRIES],
    }


def render(master_path: Path, output: Path, icns_path: Path) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    master = validate_master(master_path)

    files: list[dict[str, object]] = []
    for size in SIZES:
        image = (
            master.copy()
            if master.size == (size, size)
            else master.resize((size, size), Image.Resampling.LANCZOS)
        )
        destination = output / f"AppIcon-{size}.png"
        save_png(image, destination)
        files.append(
            {
                "file": destination.name,
                "sha256": sha256(destination),
                "width": size,
                "height": size,
                "mode": "RGBA",
            }
        )

    atomic_write(output / "Contents.json", stable_json(CONTENTS))
    return {
        "schemaVersion": 2,
        "source": {
            "file": master_path.name,
            "sha256": sha256(master_path),
            "width": master.width,
            "height": master.height,
            "mode": "RGBA",
            "colorSpace": "untagged; interpreted as sRGB",
        },
        "export": {
            "alpha": True,
            "colorSpace": "sRGB IEC61966-2.1",
            "resampling": "Pillow LANCZOS; every size is rendered directly from the unchanged RGBA master",
            "pillowVersion": PIL.__version__,
        },
        "files": files,
        "icns": write_icns(output, icns_path),
    }


def compare_file(expected: Path, actual: Path) -> list[str]:
    if not actual.is_file():
        return [f"missing: {actual}"]
    if expected.read_bytes() != actual.read_bytes():
        return [f"out of date: {actual}"]
    return []


def check(master: Path, output: Path, manifest: Path, icns_path: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="kinolet-appicon-check.") as temporary:
        expected_output = Path(temporary) / "AppIcon.appiconset"
        expected_manifest = Path(temporary) / "export-manifest.json"
        expected_icns = Path(temporary) / icns_path.name
        manifest_value = render(master, expected_output, expected_icns)
        atomic_write(expected_manifest, stable_json(manifest_value))

        errors: list[str] = []
        for size in SIZES:
            filename = f"AppIcon-{size}.png"
            errors.extend(compare_file(expected_output / filename, output / filename))
        errors.extend(compare_file(expected_output / "Contents.json", output / "Contents.json"))
        errors.extend(compare_file(expected_manifest, manifest))
        errors.extend(compare_file(expected_icns, icns_path))

        expected_pngs = {f"AppIcon-{size}.png" for size in SIZES}
        actual_pngs = {path.name for path in output.glob("*.png")}
        for filename in sorted(actual_pngs - expected_pngs):
            errors.append(f"unexpected PNG: {output / filename}")

        if errors:
            raise SystemExit("AppIcon verification failed:\n" + "\n".join(errors))

    print(f"AppIcon is reproducible and up to date: {output}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--master", type=Path, default=DEFAULT_MASTER)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--icns", type=Path, default=DEFAULT_ICNS)
    parser.add_argument(
        "--check",
        action="store_true",
        help="regenerate in a temporary directory and compare without modifying files",
    )
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    master = arguments.master.resolve()
    output = arguments.output.resolve()
    manifest = arguments.manifest.resolve()
    icns_path = arguments.icns.resolve()
    if arguments.check:
        check(master, output, manifest, icns_path)
        return

    manifest_value = render(master, output, icns_path)
    atomic_write(manifest, stable_json(manifest_value))
    print(f"Exported AppIcon: {output}")
    print(f"Wrote deterministic manifest: {manifest}")


if __name__ == "__main__":
    main()
