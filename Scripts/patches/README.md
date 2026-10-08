# Downstream dependency patches

## FFmpeg MOV multi-stsd seek

[`ffmpeg-mov-multistsd-seek.patch`](ffmpeg-mov-multistsd-seek.patch) targets
the exact FFmpeg `n8.1.2` source archive locked by
[`ThirdParty/deps.lock.json`](../../ThirdParty/deps.lock.json) (archive SHA-256
`9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7`).
The patch itself is also checksum-pinned by that lock. The build applies it with
zero fuzz, so an incompatible source update fails instead of silently moving the
hunk.

MOV demuxer read-ahead can advance `MOVStreamContext::last_stsd_index` for
packets that the player later discards. After a seek and decoder flush, seeking
back to the same sample description can then suppress the first packet's
`AV_PKT_DATA_NEW_EXTRADATA`, leaving the rebuilt decoder with stale codec
configuration. The patch invalidates that cache after a successful seek, but
only for tracks with more than one sample description; single-stsd files must
not gain redundant extradata side data.

When updating FFmpeg, revalidate two behavioral invariants with suitable MOV
fixtures: current extradata must be re-emitted after read-ahead and seek for a
multi-stsd track, while an ordinary single-stsd track must not gain redundant
extradata side data. Those fixture tests are intentionally outside this
shipping-source repository.

The repository records no upstream issue, review, or merge commit for this
downstream patch, so its upstream status is unknown. Remove it only when a newly
locked FFmpeg release has equivalent behavior and both invariants pass with the
patch omitted; then remove the patch entry and checksum from
`deps.lock.json` in the same change.

## FFmpeg libspeex decoder state after flush

[`ffmpeg-libspeex-flush-state.patch`](ffmpeg-libspeex-flush-state.patch) targets
the same locked FFmpeg n8.1.2 archive. Upstream flush clears the bit reader but
retains decoder and stereo history, so seeking back and replaying the same
packets can produce different PCM. The patch recreates the decoder and rebinds
the stereo callback. Failed allocation reports `ENOMEM` on subsequent decode;
old state remains only for safe cleanup until a successful flush replaces it.

Validate full integer PCM against independent Xiph packet references for mono
and stereo at 8/16/32 kHz, with one and three frames per packet, including
repeated flush/replays and misleading suffixes. Ogg granule trimming and speaker
presentation remain separate integration checks. These fixtures are maintained
outside this shipping-source repository.

No upstream submission or merge is recorded. Remove this patch only when a
new locked wrapper passes the independent PCM and flush/replay invariants
without it; remove its lock entry and checksum in the same change.

## FFmpeg raw AV1 Annex-B tail drain and seek state

`ffmpeg-annexb-tail-eof.patch` records a read-only reason only when an OBU
payload short read reaches clean physical EOF after earlier bitstream-filter
output. Outer length boundaries have been checked; this does not certify the
partial OBU header, frame, or temporal unit. Default behavior is unchanged. A
single acknowledgement at that position discards the partial packet and uses
the existing filter drain; filter errors remain errors. The player permits
this only after a fault-time same-file-descriptor identity check for an
unchanged local static view. A failed identity check poisons the context until
reopen, including after seek; cancellation remains distinct.

`ffmpeg-annexb-seek-flush.patch` mirrors the existing OBU demuxer: only a
successful I/O reposition flushes the filter and resets Annex-B unit counters.
Clearing tail permission alone never flushes pending packets. This adds no
raw-file index or new seek fallback.

Both patches are checksum-pinned against FFmpeg n8.1.2 and applied with zero
fuzz, in tail-drain then seek-reset order. Validation must cover bounded
EOF/error behavior, packet/PTS prefix identity, seek/replay, source changes
during acknowledgement, and cancellation. Complete decoded-pixel prefix and
player-ended checks are separate; packet equality is not presentation evidence.
Preserve the raw/container timing metadata and complete packet checks as well.

No upstream submission or merge is recorded. Remove either patch only when a
new locked upstream version passes its default-off, fault, seek, and unchanged-
input invariants without it, removing its lock entry in the same change.

## FFmpeg Dolby Vision transport and metadata parsing

`ffmpeg-dovi-transport.patch` targets the same locked FFmpeg n8.1.2 archive.
It preserves enhancement-layer configuration from hvcE records in public
dictionary side data and exposes MP4 vdep and MPEG-TS dependency associations.
It also initializes omitted optional CM4 controls to neutral values and rejects
missing mapping or static metadata references for strict parser consumers.
No FFmpeg structure ABI is extended.

The small `Scripts/lib/sp_dovi_rpu.{c,h}` adapter is compiled against that exact
patched source and archived into `libavcodec.a`. Only its opaque parser handle
and public metadata types cross the application boundary. The patch, adapter,
and header are recipe inputs; the installed header is a required build output.

Validate container association, per-frame metadata, malformed input, and parser
flush/replay against the public-built archives. Validate the actual decoder,
rendering, thumbnails, and Motion+ independently; parser tests alone do not
establish visual correctness. Keep media fixtures outside this repository.

No upstream submission or merge is recorded. Remove this patch only after a
newly locked version supplies equivalent behavior and passes those checks
without it. Update the adapter, lock, and recipe together when changing FFmpeg.
