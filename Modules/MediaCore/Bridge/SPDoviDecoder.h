// Decoder decorator for supported AVC, HEVC and AV1 Dolby Vision streams.
#pragma once
#import "SPVideoDecoding.h"

@class SPDoviEnhancementPreparation;

// P3 and P20.0 have no compatible base image. Unknown required metadata is
// a capability error, not evidence of damaged video or a reason to retry VT.
static const int kSPDoviMetadataUnsupportedError = -9106;

// OpenIssued only: inspect the selected stream's first AU and prepare EL if it
// contains a valid FEL RPU and an EL random-access picture. May run alongside
// BL setup. The caller must join this work before releasing par/packet, and
// discard the result when its open generation is superseded. No frame decoded.
SPDoviEnhancementPreparation *SPPrepareDoviEnhancement(
    const struct AVCodecParameters *parameters, const struct AVPacket *packet,
    int64_t timeBaseNum, int64_t timeBaseDen, unsigned logId);

// The supplied base decoder is already configured. Non-DV returns it unchanged.
// A preparation is consumed once; otherwise EL is created lazily at a FEL RAP.
// P3 returns nil if wrapping fails; its undecorated BL must never be presented.
id<SPVideoDecoding> SPWrapDoviDecoder(id<SPVideoDecoding> base,
                                    const struct AVCodecParameters *parameters,
                                    int64_t timeBaseNum, int64_t timeBaseDen,
                                    SPDoviEnhancementPreparation *prepared = nil);

// Decode-thread notification: a P10 wrapper changed its backend to obtain
// picture-owned metadata. Consume once to refresh the published decoder name.
bool SPConsumeDoviDecoderChange(id<SPVideoDecoding> decoder);

// On-demand supported HEVC dual-layer preview only. Zero dimensions retain
// native EL resolution before shrinking; positive hints keep the scaled test path.
// BL is configured independently. Software EL uses single-picture scheduling.
// Other inputs return the base unchanged. Metadata/EL remain owned by the output.
id<SPVideoDecoding> SPWrapDoviThumbnailDecoder(id<SPVideoDecoding> base,
    const struct AVCodecParameters *parameters, int64_t timeBaseNum,
    int64_t timeBaseDen, int outputWidth, int outputHeight);

// Speculative first-frame race only. The EL uses the formal path's decoder
// policy (VideoToolbox first) so damaged EL slices are accepted or rejected
// identically; it is decoded after the BL so the VT first-create latch does
// not delay the race. A FEL picture without its EL is dropped instead of shown
// as compatible base (the formal frame would then visibly change look).
// Non-DV returns the base unchanged.
id<SPVideoDecoding> SPWrapDoviSpeculativeDecoder(id<SPVideoDecoding> base,
                                               const struct AVCodecParameters *parameters,
                                               int64_t timeBaseNum, int64_t timeBaseDen);
