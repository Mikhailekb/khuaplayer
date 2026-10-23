# Releasing Кинолёт

Кинолёт is distributed from
[GitHub Releases](https://github.com/Mikhailekb/kinolet/releases) for this fork.
Khua's website, signed update feed, signing identity, and notarization history
do not apply to these packages.

## Version and source identity

Choose a version for the actual change and assign a higher build number to
each replacement package handed out for testing or release. Keep the main app
and Quick Look extension aligned. Configure the intended values in
`Apps/Mac/project.yml` and verify them in the packaged `Info.plist`.

A release record should identify:

- Source commit and tag.
- Application version and build number.
- Apple silicon architecture and minimum macOS version.
- Checks performed and any build or playback limitations.
- SHA-256 checksums of the published artifacts.
- Actual signing and notarization status.

Do not replace a published file with different bytes under the same version
and build identity. Publish a new build instead.

## Full source build

Use an Apple silicon Mac with Xcode and the macOS 26.4 SDK or later. Install
the dependency tools listed in [README.md](README.md), then run from the
repository root:

```bash
python3 Scripts/l10n.py check --full
./Scripts/check_public_repo.sh
./Apps/Mac/Scripts/build.sh Release
```

The build generates the Xcode project, verifies or builds the pinned media and
subtitle dependencies, prepares the torrent worker, and packages the app.
Run `Scripts/verify_app_bundle.sh` against the resulting application path
printed by the build. Check the app's version, bundled executable, framework
load paths, resources, and architecture before packaging.

The canonical full-build output is
`.build/Build/Products/Release/Kinolet.app`; the Release script also publishes
`Kinolet.app` at the repository root. The executable remains ASCII `Kinolet`,
while the displayed product name is Кинолёт.

A local ad-hoc signature provides integrity checking; it is not an Apple
Developer ID identity or notarization. Do not label a release as notarized
unless that exact artifact has passed Apple's notarization workflow and its
stapled ticket has been verified.

## Playback and feature verification

Run the focused `Scripts/test_*.sh` checks appropriate to the changed features.
For a public build, also exercise local-file playback, a folder playlist,
settings persistence, audio/subtitle selection, opening and closing a torrent,
resuming a torrent from history, and an explicit Save. Use controlled fixtures
and identify the hardware and media profiles tested.

Verify that the package contains the selected Кинолёт icon and product name,
and that it does not contact Khua's update service. The inherited internal
module names do not need to be changed to validate the public branding.

Model and component checks do not replace playback inspection. If packaging
uses a prebuilt media framework, identify its origin and version rather than
claiming a fresh full source build.

## Torrent worker source and notices

The bundled TorrServer worker has a separate GPL-3.0 license. Preserve its
`LICENSE`, `NOTICE`, `worker-manifest.json`, source archives, downstream patches,
and rebuild script when preparing a distribution. The pinned build is prepared
through:

```bash
./Scripts/prepare_torrent_worker.sh
```

`Scripts/build_torrent_worker.py` validates the size and SHA-256 of the pinned
inputs and resulting unsigned worker. Signing changes executable signature
bytes; preserve the distinction between the reproducible unsigned worker and
the signed app payload.

The worker notice identifies its exact upstream source and patched dependency.
Include the required Corresponding Source and notices for the components
being distributed. Preserve Khua's MIT copyright and license, as well as the
media stack's third-party notices. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
[Apps/Mac/Resources/Torrent/NOTICE](Apps/Mac/Resources/Torrent/NOTICE).

## Package and publish

Package the verified app as an archive or disk image that preserves the bundle
structure and executable permissions. Do not commit app bundles, archives,
DMGs, dependency caches, or signing secrets into the source repository.
Publish the app and its source information together in the matching GitHub
release, with checksums and the signing status stated plainly.

The repository retains archive and notarization scripts inherited from Khua.
They require a distributor's own identifiers, certificates, credentials, and
validated configuration. Their presence does not establish that this fork has
an App Store release, Developer ID certificate, signed update feed, or a
notarized download. Do not reuse upstream feed settings or signing keys.

Automatic updates are disabled by default. Enabling a distributor's own
channel requires `KINOLET_ENABLE_AUTOMATIC_UPDATES=true` together with both
`KINOLET_SPARKLE_FEED_URL` and `KINOLET_SPARKLE_PUBLIC_ED_KEY`. The default
`Distribution/sparkle.json` contains no feed or key. Supplying a channel is a
separate distribution decision; it must not reactivate Khua's feed or its
installation-identifier statistics.
