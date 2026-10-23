# Contributing to Кинолёт

Keep changes focused on the Mac player and its public build pipeline. This
repository is an independent fork of
[Khua Player](https://github.com/nake13/khuaplayer); report issues with this
fork through [Kinolet's issue tracker](https://github.com/Mikhailekb/kinolet/issues).

## Source changes

- Preserve the original copyright, MIT license, and third-party notices.
- Keep public documentation, diagnostics, and new source comments in English.
  The product's display name is **Кинолёт**, with **Kinolet** as its Latin spelling.
- Add user-facing strings to `Apps/Mac/Resources/Localizable.xcstrings`.
  English is the source language; preserve placeholders and keep every
  supported translation complete.
- Retain existing `SP` symbols and internal framework/module names unless a
  technical change requires renaming them. They are not the product branding.
- Edit `Apps/Mac/project.yml` instead of generated Xcode projects.
- Do not commit downloaded media, build products, dependency caches, generated
  projects, private logs, or signing credentials.

See [REPOSITORY_LAYOUT.md](REPOSITORY_LAYOUT.md) for source ownership.

## Checks

Run checks that exercise the changed behavior. The focused runners in
`Scripts/test_*.sh` compile their fixtures independently where possible, so
many model and policy checks work with Command Line Tools without building
the complete application. Do not treat those checks as proof that the full
app packages or runs correctly.

Localization and source checks:

```bash
python3 Scripts/l10n.py status
python3 Scripts/l10n.py check --full
python3 Scripts/verify_public_surface.py
./Scripts/check_public_repo.sh
```

Examples of feature checks:

```bash
./Scripts/test_playback_gestures.sh
./Scripts/test_playlist_filesystem.sh
./Scripts/test_playlist_keyboard.sh
./Scripts/test_torrent_models.sh
./Scripts/test_torrent_server.sh
./Scripts/test_torrent_resume_store.sh
```

Some integration runners need additional tools or fixtures; read their headers
before running them. Keep temporary fixtures outside tracked source and do
not use someone else's application preferences for tests.

For a complete source build, use an Apple silicon Mac with Xcode and the
macOS 26.4 SDK or later, install the tools listed in [README.md](README.md),
then run:

```bash
./Apps/Mac/Scripts/build.sh Debug
# For an optimized local package:
./Apps/Mac/Scripts/build.sh Release
```

Validate the resulting bundle with `Scripts/verify_app_bundle.sh` and the path
printed by the build. Release packaging and any signing limitations belong
in [RELEASING.md](RELEASING.md).

## Pull requests

Describe the user-visible behavior, the checks run, and any remaining limits.
For playback changes, include the media format, relevant HDR/Dolby Vision
profile, macOS version, and hardware exercised. Model checks, hidden component
checks, visual playback checks, and a full source build establish different
things; identify which evidence is available.

Torrent worker changes must preserve its pinned source manifests, downstream
patches, license, notices, and rebuild recipe. Do not replace a worker binary
without updating and verifying the corresponding source information.
