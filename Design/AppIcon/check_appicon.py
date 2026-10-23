#!/usr/bin/env python3
"""Validate the selected Kinolet raster, RGBA exports and retained legacy art."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parent
MASTER = ROOT / "Kinolet-Prism-Master.png"
SIZES = (16, 32, 64, 128, 256, 512, 1024)
EXPECTED_LAYERS = {
    "01-Background.png",
    "03-RearRibbons.png",
    "04-PlayTriangle.png",
}
EXPECTED_SLOTS = {
    ("AppIcon-16.png", "mac", "1x", "16x16"),
    ("AppIcon-32.png", "mac", "2x", "16x16"),
    ("AppIcon-32.png", "mac", "1x", "32x32"),
    ("AppIcon-64.png", "mac", "2x", "32x32"),
    ("AppIcon-128.png", "mac", "1x", "128x128"),
    ("AppIcon-256.png", "mac", "2x", "128x128"),
    ("AppIcon-256.png", "mac", "1x", "256x256"),
    ("AppIcon-512.png", "mac", "2x", "256x256"),
    ("AppIcon-512.png", "mac", "1x", "512x512"),
    ("AppIcon-1024.png", "mac", "2x", "512x512"),
}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
ICNS_ENTRIES = {
    b"icp4": 16, b"icp5": 32,
    b"ic07": 128, b"ic08": 256, b"ic09": 512, b"ic10": 1024,
    b"ic11": 32, b"ic12": 64, b"ic13": 256, b"ic14": 512,
}


def fail(message: str) -> None:
    raise SystemExit(f"AppIcon validation failed: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def png_properties(path: Path) -> tuple[int, int, int, int, bool]:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        fail(f"not a PNG: {path}")

    position = len(PNG_SIGNATURE)
    width = height = bit_depth = color_type = -1
    has_srgb = False
    saw_iend = False
    while position < len(data):
        if position + 12 > len(data):
            fail(f"truncated PNG chunk: {path}")
        length = struct.unpack(">I", data[position : position + 4])[0]
        chunk_type = data[position + 4 : position + 8]
        chunk_start = position + 8
        chunk_end = chunk_start + length
        crc_end = chunk_end + 4
        if crc_end > len(data):
            fail(f"truncated PNG payload: {path}")
        payload = data[chunk_start:chunk_end]
        expected_crc = struct.unpack(">I", data[chunk_end:crc_end])[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(payload, actual_crc) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            fail(f"invalid PNG CRC: {path}")

        if chunk_type == b"IHDR":
            if length != 13:
                fail(f"invalid IHDR length: {path}")
            width, height, bit_depth, color_type = struct.unpack(">IIBB", payload[:10])
        elif chunk_type == b"sRGB":
            has_srgb = True
        elif chunk_type == b"IEND":
            saw_iend = True
            position = crc_end
            break
        position = crc_end

    if not saw_iend or position != len(data):
        fail(f"invalid PNG ending: {path}")
    return width, height, bit_depth, color_type, has_srgb


def validate_alpha_corners(path: Path, width: int, height: int) -> None:
    """Check the real alpha samples without requiring Pillow in CI."""
    data = path.read_bytes()
    compressed = bytearray()
    position = len(PNG_SIGNATURE)
    while position < len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        if kind == b"IHDR" and payload[12] != 0:
            fail(f"interlaced RGBA PNG is unsupported: {path}")
        if kind == b"IDAT":
            compressed.extend(payload)
        position += length + 12
    raw = zlib.decompress(compressed)
    stride = width * 4
    if len(raw) != height * (stride + 1):
        fail(f"unexpected decoded RGBA size: {path}")
    previous = bytearray(stride)
    corners = []
    has_opaque = False
    for row in range(height):
        offset = row * (stride + 1)
        method = raw[offset]
        samples = bytearray(raw[offset + 1:offset + 1 + stride])
        if method not in range(5):
            fail(f"invalid PNG row filter: {path}")
        for index in range(stride):
            left = samples[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if method == 1:
                predictor = left
            elif method == 2:
                predictor = above
            elif method == 3:
                predictor = (left + above) // 2
            elif method == 4:
                estimate = left + above - upper_left
                distances = (abs(estimate - left), abs(estimate - above),
                             abs(estimate - upper_left))
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            else:
                predictor = 0
            samples[index] = (samples[index] + predictor) & 255
        if row in (0, height - 1):
            corners.extend((samples[3], samples[-1]))
        has_opaque = has_opaque or 255 in samples[3::4]
        previous = samples
    if any(corners) or not has_opaque:
        fail(f"PNG must retain transparent corners and opaque artwork: {path}")


def validate_png(path: Path, size: int, require_srgb: bool = True) -> None:
    if not path.is_file():
        fail(f"missing PNG: {path}")
    width, height, bit_depth, color_type, has_srgb = png_properties(path)
    if (width, height) != (size, size):
        fail(f"wrong dimensions for {path}: {width}x{height}")
    if bit_depth != 8 or color_type != 6:
        fail(f"{path} must be 8-bit RGBA; PNG color type is {color_type}")
    if require_srgb and not has_srgb:
        fail(f"missing sRGB declaration: {path}")
    validate_alpha_corners(path, width, height)


def validate_icon_composer_source() -> None:
    document_path = ROOT / "KhuaPlayer.icon" / "icon.json"
    document = json.loads(document_path.read_text(encoding="utf-8"))
    groups = document.get("groups")
    if not isinstance(groups, list) or len(groups) != 1:
        fail("KhuaPlayer.icon must contain exactly one layer group")
    group = groups[0]
    layers = group.get("layers")
    if not isinstance(layers, list):
        fail("KhuaPlayer.icon layers are missing")
    referenced = {layer.get("image-name") for layer in layers}
    if referenced != EXPECTED_LAYERS:
        fail(f"unexpected Icon Composer layer set: {sorted(referenced)}")

    assets_dir = ROOT / "KhuaPlayer.icon" / "Assets"
    available = {path.name for path in assets_dir.glob("*.png")}
    if available != EXPECTED_LAYERS:
        fail(f"unexpected Icon Composer assets: {sorted(available)}")
    if group.get("specular") is not False:
        fail("Icon Composer group specular must remain disabled")
    translucency = group.get("translucency", {})
    if translucency.get("enabled") is not False:
        fail("Icon Composer group translucency must remain disabled")
    if group.get("shadow", {}).get("kind") != "none":
        fail("Icon Composer group shadow must remain disabled")


def validate_manifest() -> None:
    manifest = json.loads((ROOT / "export-manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 2:
        fail("unsupported export-manifest.json schema")
    master = MASTER
    source = manifest.get("source", {})
    source_width = source.get("width")
    if not isinstance(source_width, int) or source_width < 1024:
        fail("selected master must be at least 1024 px")
    validate_png(master, source_width, require_srgb=False)
    if source.get("file") != master.name or source.get("sha256") != sha256(master):
        fail("static master does not match export-manifest.json")
    if (
        source.get("height") != source_width
        or source.get("mode") != "RGBA"
        or source.get("colorSpace") != "untagged; interpreted as sRGB"
    ):
        fail("static master metadata is invalid in export-manifest.json")
    export = manifest.get("export", {})
    if export.get("alpha") is not True or export.get("colorSpace") != "sRGB IEC61966-2.1":
        fail("production export must remain RGBA sRGB")

    records = manifest.get("files")
    if not isinstance(records, list):
        fail("export-manifest.json files are missing")
    by_name = {record.get("file"): record for record in records}
    expected_names = {f"AppIcon-{size}.png" for size in SIZES}
    if set(by_name) != expected_names:
        fail("export-manifest.json has an unexpected file set")

    appiconset = ROOT / "AppIcon.appiconset"
    contents = json.loads((appiconset / "Contents.json").read_text(encoding="utf-8"))
    images = contents.get("images")
    if not isinstance(images, list):
        fail("AppIcon Contents.json images are missing")
    slots = {
        (image.get("filename"), image.get("idiom"), image.get("scale"), image.get("size"))
        for image in images
    }
    if len(images) != len(EXPECTED_SLOTS) or slots != EXPECTED_SLOTS:
        fail("AppIcon Contents.json does not contain the required macOS slots")
    for size in SIZES:
        filename = f"AppIcon-{size}.png"
        path = appiconset / filename
        validate_png(path, size)
        record = by_name[filename]
        if record.get("sha256") != sha256(path):
            fail(f"hash mismatch in export-manifest.json: {filename}")
        if record.get("width") != size or record.get("height") != size:
            fail(f"dimension mismatch in export-manifest.json: {filename}")
        if record.get("mode") != "RGBA":
            fail(f"mode mismatch in export-manifest.json: {filename}")

    icns_record = manifest.get("icns", {})
    icns_path = ROOT / "AppIcon.icns"
    if icns_record.get("file") != icns_path.name or icns_record.get("sha256") != sha256(icns_path):
        fail("AppIcon.icns does not match export-manifest.json")
    data = icns_path.read_bytes()
    if data[:4] != b"icns" or len(data) < 8 or struct.unpack(">I", data[4:8])[0] != len(data):
        fail("invalid AppIcon.icns header")
    seen = set()
    position = 8
    while position < len(data):
        if position + 8 > len(data):
            fail("truncated AppIcon.icns entry")
        kind = data[position:position + 4]
        length = struct.unpack(">I", data[position + 4:position + 8])[0]
        if kind not in ICNS_ENTRIES or kind in seen or length < 8 or position + length > len(data):
            fail("unexpected AppIcon.icns entry")
        expected_png = (appiconset / f"AppIcon-{ICNS_ENTRIES[kind]}.png").read_bytes()
        if data[position + 8:position + length] != expected_png:
            fail("AppIcon.icns entry does not preserve the canonical RGBA PNG")
        seen.add(kind)
        position += length
    if seen != set(ICNS_ENTRIES) or icns_record.get("entries") != [kind.decode("ascii") for kind in ICNS_ENTRIES]:
        fail("AppIcon.icns is missing required standard or Retina representations")


def validate_asset_manifest() -> None:
    manifest_path = ROOT / "asset-manifest.txt"
    listed = {
        line.strip()
        for line in manifest_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    actual: set[str] = set()
    for path in ROOT.rglob("*"):
        if path.is_symlink():
            fail(f"source tree must not contain symlinks: {path}")
        if path.is_file() and "__pycache__" not in path.parts:
            actual.add(path.relative_to(ROOT).as_posix())
    if listed != actual:
        missing = sorted(listed - actual)
        unexpected = sorted(actual - listed)
        fail(f"asset-manifest mismatch; missing={missing}, unexpected={unexpected}")


def validate_shipping_copy(shipping: Path) -> None:
    canonical = ROOT / "AppIcon.appiconset"
    for filename in ["Contents.json", *(f"AppIcon-{size}.png" for size in SIZES)]:
        source = canonical / filename
        destination = shipping / filename
        if not destination.is_file():
            fail(f"shipping AppIcon is missing: {destination}")
        if source.read_bytes() != destination.read_bytes():
            fail(f"shipping AppIcon is out of date: {destination}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--shipping",
        type=Path,
        help="optional Xcode AppIcon.appiconset that must match the canonical export",
    )
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    validate_icon_composer_source()
    validate_manifest()
    validate_asset_manifest()
    if arguments.shipping is not None:
        validate_shipping_copy(arguments.shipping.resolve())
    print(f"AppIcon source and export validation passed: {ROOT}")


if __name__ == "__main__":
    main()
