# Third-party notices

Khua builds the following libraries from the versions and source hashes
recorded in [`ThirdParty/deps.lock.json`](ThirdParty/deps.lock.json).

| Component | Version | Selected license |
|---|---:|---|
| FFmpeg | 8.1.2 | LGPL-2.1-or-later |
| dav1d | 1.5.1 | BSD-2-Clause |
| Speex | 1.2.1 | BSD-3-Clause |
| libass | 0.17.5 | ISC |
| libpng | 1.6.58 | PNG Reference Library License 2.0 |
| FreeType | 2.14.3 | FreeType Project License |
| FriBidi | 1.0.16 | LGPL-2.1-or-later |
| libunibreak | 7.0 | zlib-style license |
| Graphite2 | 1.3.15 | MIT option |
| HarfBuzz | 14.3.0 | Old MIT license |
| Sparkle | 2.9.6 | MIT and bundled third-party notices |

The complete notices and license texts shipped with these upstream releases are
in [`ThirdParty/Licenses`](ThirdParty/Licenses) and are copied into the app
bundle. The locked source URLs, checksums, build options, and downstream FFmpeg
patches are part of this repository. The notice set includes dav1d's patent
license, the FreeType BDF/PCF driver notices, and the HarfBuzz Microsoft
Universal Shaping Engine data notice.

This software is based in part on the work of the Independent JPEG Group.
This software is based in part on the work of the FreeType Team
(https://freetype.org).

Sparkle is built only for the optional direct-distribution update lane. The
Mac App Store configuration excludes the framework and all updater settings.

FFmpeg, dav1d, and Speex are currently linked statically into the media framework.
Anyone distributing binaries must independently satisfy the LGPL requirements,
including corresponding-source and relinking obligations where applicable.
The repository's reproducible recipes help with compliance but are not a
substitute for legal review, especially for Mac App Store distribution.

## Torrent playback helper

Torrent playback uses a separate patched TorrServer executable with these
pinned upstream components:

| Component | Version | Upstream license |
|---|---|---|
| [TorrServer](https://github.com/YouROK/TorrServer) | MatriX.147, source commit `a86d8fa7fd4e07605f240fe69bf299392f7cb023` | [GPL-3.0](https://github.com/YouROK/TorrServer/blob/a86d8fa7fd4e07605f240fe69bf299392f7cb023/LICENSE) |
| [tsynik/torrent](https://github.com/tsynik/torrent) | v1.2.32, with a local patch | [MPL-2.0](https://github.com/tsynik/torrent/blob/v1.2.32/LICENSE) |

The helper's exact build version, source archive hashes and downstream patches
are recorded in
[`worker-manifest.json`](Apps/Mac/Resources/Torrent/worker-manifest.json).
[`NOTICE`](Apps/Mac/Resources/Torrent/NOTICE) documents the changes and pinned
build recipe; the accompanying [`LICENSE`](Apps/Mac/Resources/Torrent/LICENSE)
contains TorrServer's GPL text. The packaged helper includes its upstream source
archive, the pinned torrent dependency source ZIP with its MPL license, both
patches and the build script. Other Go dependency versions and checksums remain
recorded in the upstream source archive's `server/go.mod` and `server/go.sum`.
