# Kinolet App Icon

`Kinolet-Prism-Master.png` is the selected prism icon, concept **05**, generated
with OpenAI ImageGen for Kinolet on 2026-10-23. It is the transparent version of
the selected concept, copied byte for byte from the generated PNG. Its original
1254 x 1254 RGBA pixels and alpha channel are retained. The file has no embedded
color profile; exports interpret its RGB channels as sRGB.

The production exporter only resizes and packages this raster. It does not
redraw the prism, change its colors, remove a background, crop it, or recreate
its transparency. The selected source SHA-256 is recorded in
`export-manifest.json`.

## Production files

- `Kinolet-Prism-Master.png`: unchanged selected source.
- `AppIcon.appiconset`: canonical macOS PNGs at 16, 32, 64, 128, 256, 512 and
  1024 pixels, with all standard and Retina asset catalog slots.
- `AppIcon.icns`: deterministic ICNS container for Finder, Dock and builds that
  do not recompile the asset catalog. Its entries contain the exact canonical
  PNG bytes, including alpha.
- `export-manifest.json`: source, export and ICNS hashes, dimensions, alpha
  policy and pinned Pillow version.

Every PNG is resized directly from the source using Pillow Lanczos, retains
RGBA transparency and receives a fixed sRGB declaration. No intermediate size
is used as another size's source.

## Export and verify

The exporter uses Python 3 and the Pillow version pinned in `requirements.txt`.
From the repository root:

```sh
python3 -m pip install -r Design/AppIcon/requirements.txt
python3 Design/AppIcon/export_static_appicon.py
python3 Design/AppIcon/export_static_appicon.py \
  --output Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset
python3 Design/AppIcon/export_static_appicon.py --check
python3 Design/AppIcon/check_appicon.py \
  --shipping Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset
```

`--check` regenerates PNGs, ICNS and the manifest in a temporary directory and
compares their bytes. `check_appicon.py` uses only the Python standard library;
it validates PNG checksums, real alpha samples and transparent corners, source
and export hashes, ICNS entries and the shipping copy.

For a manual app bundle, copy `AppIcon.icns` into `Contents/Resources` and set
`CFBundleIconFile` to `AppIcon.icns`. When an old `Assets.car` remains in a manual
build, load this ICNS explicitly with `NSImage(contentsOf:)` for in-app artwork
and `NSApplication.applicationIconImage`; an asset-catalog lookup can otherwise
still return the previous icon. A normal Xcode build consumes the updated
asset catalog under `Apps/Mac/Resources`.

## Legacy Khua artwork

`KhuaPlayer.icon`, `KhuaPlayer-StaticMaster-1024.png` and
`prepare_icon_composer_layers.py` are retained unchanged from the upstream
[Khua repository](https://github.com/nake13/khuaplayer). Their attribution remains
with Khua contributors under the repository's MIT license. The Icon Composer
document contains the previous Khua artwork; it is not an editable source for
the Kinolet prism and is not used by the production export.

The legacy layer reconstruction tool requires the pinned NumPy version. Run it
only to reconstruct the retained legacy artwork. Production checks retain its
source-integrity checks alongside validation of the new selected raster.
