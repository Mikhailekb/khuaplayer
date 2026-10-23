# Repository layout

Кинолёт keeps product UI, media processing, and macOS implementations in
separate directories. Existing `KhuaPlayer` module names and `SP` symbols are
retained technical identifiers inherited from Khua; the Mac product is Кинолёт.

```text
Apps/Mac/
  project.yml             XcodeGen project definition
  UI/                     AppKit windows, playback controls, and settings
                          Folder playlists and torrent playback coordination
  Resources/              Localizations, icons, privacy manifest
    Torrent/              Pinned worker manifest, licenses, and source patches
  Support/                Objective-C bridging header
  QuickLook/              Finder preview extension
  CaptionsHost/           Subtitle task coordination and UI adapters
  CaptionsUI/             Lazily loaded system translation interface
Modules/
  MediaCore/Core/         Demuxing, queues, HTTP range I/O, playback policies
  MediaCore/Bridge/       Objective-C interfaces and media implementation
  MediaCore/Shaders/      Metal playback shaders
  Captions/               Subtitle formats, scheduling, transcription
  VideoEnhancement/       Motion+ planning and frame generation
Platform/macOS/
  Audio/                  Mac audio output
  Rendering/              Metal rendering and display handling
Scripts/
  tests/                  Focused policy and integration fixtures
                          Dependency recipes, checks, build and release tools
ThirdParty/               Dependency locks, licenses, ignored build artifacts
Design/AppIcon/           Icon source and exports
Distribution/            Distribution metadata and retained release tooling
```

`Apps/Mobile` is inherited planning material. It does not provide a buildable
mobile product or promise a mobile release.

## Build boundaries

`Apps/Mac/Scripts/build.sh` is the full Mac source-build entry point;
`Scripts/build.sh` forwards its arguments and exit status. The Xcode project is
generated from `Apps/Mac/project.yml` and is intentionally ignored by Git.

The app compiles `Apps/Mac/UI`, `Apps/Mac/CaptionsHost`, and `Modules/Captions`.
`KhuaPlayerMediaCore` combines the media core, video enhancement code, and
macOS platform implementations. Quick Look uses the same media framework.
`KhuaPlayerCaptionsUI` remains a separate framework that is loaded when the
system translation interface is needed.

Motion+ has its own `FrameBudget.metallib`, loaded on demand. Ordinary playback
uses the main renderer without starting interpolation.

The torrent feature runs a separate TorrServer process. Its binary, pinned
source inputs, licenses, and notices are prepared by
`Scripts/prepare_torrent_worker.sh` and embedded by
`Scripts/embed_torrent_worker.sh`. The player reads its selected stream through
HTTP range I/O on an authenticated loopback endpoint. Peer connections belong
to the worker.

Full-build outputs and dependency caches are kept under `.build`. The build
prints its resulting application path; see [RELEASING.md](RELEASING.md) before
publishing a local package. `Scripts/test_*.sh` provides smaller verification
entry points for individual features.
