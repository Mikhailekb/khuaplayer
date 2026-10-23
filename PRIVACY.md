# Privacy policy for Кинолёт

Effective date: October 23, 2026

Кинолёт is an independent fork of Khua Player. This policy describes this
fork, including its local playlists and torrent playback. It does not describe
Khua's separate website, update service, or official releases.

The application has no account system, advertising SDK, or playback analytics
service. It does not upload your local videos, playback history, picture
settings, or subtitle text to a Kinolet server. Torrent playback makes network
connections as described below.

## Local files and preferences

Files are opened after a user action, such as choosing a file or folder,
dropping it into the app, or opening it from Finder. A selected folder may be
scanned and monitored to update its playlist and find nearby subtitles.
Folder scanning reads names and file metadata; it does not upload the folder
contents. Access to a mounted network folder uses that filesystem's normal
network connection.

The application stores recent items, playback positions, selected folders,
file-access bookmarks, language preferences, and playback settings locally.
A folder playlist can retain its picture settings, Motion+ preference, and
preferred audio voice for other episodes. These records may contain local
paths and media titles.

On the first launch of this renamed fork, missing preferences and torrent
resume metadata are copied from its earlier SidebarDev development build.
Existing Kinolet values and the development build's originals are preserved.
The original Khua application's preference domain is not used as a source.

The history-clearing command removes the playback positions and recent-item
history managed by the app. It does not delete media, saved screenshots,
subtitle exports, or files saved from torrents, and should not be treated as
a reset of every preference.

Screenshots, generated subtitles, and explicit file saves write to local
storage. Their destination follows the app's save action and the access granted
by macOS. macOS may retain recent-document information, permission records,
backups, and crash diagnostics under the user's system settings.

## Torrents and magnet links

Opening a torrent or magnet link starts a bundled TorrServer worker when
needed. The player communicates with its authenticated control and streaming
endpoint on `127.0.0.1`, using temporary per-worker credentials. That local
endpoint is separate from the worker's BitTorrent peer connections.

BitTorrent is a peer-to-peer protocol. The worker contacts trackers and may use
DHT and peer exchange to discover peers. Those parties can observe the public
IP address used for the connection and the torrent's identifier. Peers exchange
requested pieces according to the protocol, which can include uploading
available pieces. A torrent's own metadata or magnet link can supply tracker
addresses and other source information. These connections are not anonymous,
and they are not playback analytics sent to the application developer.

Streaming media pieces use the configured memory cache rather than a permanent
movie download folder. This does not mean that the application writes nothing
to disk: temporary worker configuration and authentication files, torrent
metadata, and playback history have different lifetimes from the piece cache.
The operating system may also page memory to disk.

To reopen a torrent from history, the application stores its identity, media
filename, selected file, and resume position locally. It can retain the magnet
link or a copy of the original `.torrent` metadata in Application Support.
These records can reveal which torrent was opened. Closing playback releases
its active torrent session; metadata retained for history is separate from
that session's temporary streaming cache.

Choosing **Save** starts a download of the selected file to the destination
you choose. The download can use temporary disk storage before the completed
file is moved into place. Saved files remain until you delete them.

## On-device subtitles

On supported macOS versions, subtitle generation and translation use Apple's
on-device speech and translation services. Кинолёт does not send the selected
video or subtitle text to a developer-operated transcription service. macOS
may download the language models required by those services, following Apple's
prompts and system settings. This feature reads the selected media's audio;
it does not record your microphone.

Generated or translated subtitle files and intermediate task data remain
local. Clearing playback history does not remove subtitle exports you saved.

## Updates and development downloads

Fork releases are published at
[github.com/Mikhailekb/kinolet/releases](https://github.com/Mikhailekb/kinolet/releases).
The Кинолёт distribution does not use Khua's automatic update feed or its
installation-identifier statistics. Visiting GitHub or downloading a release
uses GitHub's normal service and request processing.

When a developer builds the application, the build scripts download pinned
open-source dependency archives and the required build toolchain. This
build-time network activity is separate from opening or watching a video.

## Changes to this policy

Changes to accounts, telemetry, update services, or other network features
must be reflected in this policy before distribution. Privacy questions and
reports can be raised through this fork's
[issue tracker](https://github.com/Mikhailekb/kinolet/issues); avoid including
private media, credentials, magnet links, or file paths in a public report.
