<img src="Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png" width="96" height="96" alt="Кинолёт app icon">

# Кинолёт · Kinolet

A native, open-source video player for Apple silicon Macs. Watch local files,
keep a series together in a folder playlist, or start a video from a torrent
before the entire file has downloaded.

[Releases](https://github.com/Mikhailekb/kinolet/releases) ·
[Issues](https://github.com/Mikhailekb/kinolet/issues) ·
[Build from source](#build-from-source) · [Privacy](PRIVACY.md)

Кинолёт is an independent fork of [Khua Player](https://github.com/nake13/khuaplayer).
It adds its own interface, playback controls, folder playlists, and torrent
streaming while retaining Khua's media engine and supported Mac features.

## Playback

- **Local video and audio.** MKV, MP4, MOV, WebM, AVI, MPEG-TS, FLV, WMV, and
  other formats supported by the bundled media stack. Hardware decoding is
  used where supported, with software fallbacks for other codecs.
- **HDR and Dolby Vision.** Metal rendering, Dolby Vision Profile 5 color
  conversion, and tone mapping for SDR displays. Picture adjustments include
  brightness, contrast, saturation, gamma, and hue. HDR viewing preferences
  and SDR brightness enhancement are available on compatible displays.
- **Motion+.** Optional frame interpolation on supported Macs running macOS
  26 or later; hold **C** to compare the original and enhanced motion.
- **Subtitles.** Embedded and external subtitle tracks, automatic matching of
  nearby subtitle files, and on-device generation and translation on supported
  macOS versions. Generated subtitles can be saved as SRT.
- **Mac controls.** Trackpad seeking and volume, pinch to resize or toggle
  full screen, configurable gesture sensitivity, playback speed, and a
  hold-Space Turbo action. Layout, video, audio, and subtitle controls are
  available in the playback settings panel.
- **Everyday details.** Resume playback, select audio tracks, step through
  frames, take screenshots, open multiple windows, and preview supported
  formats through the Finder Quick Look extension.

## Folders and series

Open a folder to browse its videos as a tree, including nested episode folders.
The playlist updates when files are added, removed, renamed, or grow while
being downloaded. It keeps the current playback session in place during those
updates.

A folder playlist remembers its picture settings, Motion+ choice, and selected
audio voice when a matching track is available in another episode. Resume
positions and recent items are stored locally. Recovery of damaged or unfinished
files is best-effort and does not alter the original media.

## Torrent playback

Open a `.torrent` file or a magnet link, choose a video, and start watching as
pieces arrive. Files from a multi-file torrent appear in the playlist, so a
series can be played episode by episode.

Streaming uses a bundled [TorrServer](https://github.com/YouROK/TorrServer)
worker and a configurable memory cache. It does not save a complete movie to
a permanent media folder unless you choose **Save**. Configuration, resume
metadata, and saved files are separate from the in-memory streaming cache;
see [Privacy](PRIVACY.md) for details. **Save** downloads the selected file to
the location you choose.

Playback depends on the available peers, network speed, and file structure.
Кинолёт does not provide a media catalogue or torrent search service. BitTorrent
connections expose your IP address and torrent identifier to the peers and
trackers involved in the transfer.

## Requirements

| Feature | Requirements |
|---|---|
| Playback, playlists, torrent streaming, and Quick Look | Apple silicon Mac with macOS 14 or later |
| Motion+ frame interpolation | macOS 26 or later and supported system frame-rate conversion |
| Subtitle generation and translation | macOS 26 or later; available languages depend on Apple's on-device services |
| HDR output and SDR brightness enhancement | A compatible display with available extended brightness headroom |

Intel Macs are not supported. This repository builds the Mac application.

## Build from source

The full source build requires an Apple silicon Mac, Xcode with the macOS 26.4
SDK or later, and these build tools:

```bash
brew install xcodegen meson ninja cmake pkg-config go
```

From the repository root:

```bash
./Apps/Mac/Scripts/build.sh Debug
# or
./Apps/Mac/Scripts/build.sh Release
```

`Scripts/build.sh` forwards to the same entry point. The project definition is
[`Apps/Mac/project.yml`](Apps/Mac/project.yml); the generated Xcode project is
not a source file and should not be edited by hand.

The build downloads and verifies pinned dependency sources, builds the media
and subtitle libraries, prepares the torrent worker, and packages the app.
The torrent build uses the Go toolchain and source hashes recorded in
[`worker-manifest.json`](Apps/Mac/Resources/Torrent/worker-manifest.json).
Cached dependencies are reused after their build stamps have been checked.

The app is built at `.build/Build/Products/<configuration>/Kinolet.app`.
Release builds also publish `Kinolet.app` at the repository root. Its visible
name is **Кинолёт**; its executable is `Kinolet` and its bundle identifier is
`app.kinolet.player`. Local builds use ad-hoc signing; that is separate from
Apple Developer ID signing and notarization.
Release artifacts and their signing status belong in the corresponding
[GitHub release](https://github.com/Mikhailekb/kinolet/releases).

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks,
[REPOSITORY_LAYOUT.md](REPOSITORY_LAYOUT.md) for source ownership, and
[RELEASING.md](RELEASING.md) for packaging notes.

## Origin and licenses

Кинолёт is based on [Khua Player](https://github.com/nake13/khuaplayer), by
Khua contributors. The original copyright and [MIT license](LICENSE) are
preserved. Changes in this fork are provided under the same MIT license unless
an individual component states otherwise.

Third-party components keep their own licenses. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
[`ThirdParty/Licenses`](ThirdParty/Licenses), and the torrent worker's
[NOTICE](Apps/Mac/Resources/Torrent/NOTICE) and
[GPL-3.0 license](Apps/Mac/Resources/Torrent/LICENSE). The worker's pinned
sources, downstream patches, and rebuild instructions accompany its packaging
recipe. Distributors must satisfy the licenses of every component they ship.
