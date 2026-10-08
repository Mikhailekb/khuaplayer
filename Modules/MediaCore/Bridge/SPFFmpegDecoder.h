// Software video decoding with frame/slice threading and IOSurface-backed
// pixel buffers. Pending output preserves one-frame-at-a-time delivery without
// dropping additional frames decoded from a packet.
#import <Foundation/Foundation.h>
#import "SPVideoDecoding.h"

@interface SPFFmpegDecoder : NSObject <SPVideoDecoding>
// Opt-in direct dav1d output for AV1 I420 8/10-bit playback. A custom allocator
// supplies IOSurface-backed three-plane storage, avoiding a full-frame copy.
// P10 previews use picture metadata from direct dav1d and scale to bi-planar
// buffers; other thumbnail formats retain avcodec/swscale. Set before setup;
// disabled by default for consumers requiring bi-planar output.
@property (nonatomic) BOOL planarOutputEnabled;
// Whether setup selected direct dav1d output for the current session.
@property (nonatomic, readonly) BOOL planarOutputActive;
// True after direct AV1 decoding is confirmed, including scaled P10 previews.
// Consumers can then skip duplicate packet parsing and use picture attachments.
@property (nonatomic, readonly) BOOL doviPictureMetadataActive;
// Single-frame race mode uses slice-only decoding with four threads, avoiding
// frame-pipeline allocation intended for continuous decoding.
@property (nonatomic) BOOL singleFrameMode;
// Opt-in FEL output: retain progressive decoded chroma siting for EL sampling.
// Default NO. Scaled previews keep their existing approximate sampling policy.
@property (nonatomic) BOOL preserveChromaLocation;
// Quick Look uses one low-delay AV1 frame context and no process-memory claim.
// Set before setup to preserve extension memory headroom.
@property (nonatomic) BOOL previewMode;
// Optional output dimensions. When both exceed one, swscale writes directly
// to that size and the pool follows it. The caller incorporates sample aspect
// ratio; the output is treated as square pixels. Set before setup; rebuilds retain it.
@property (nonatomic) int outputWidthHint;
@property (nonatomic) int outputHeightHint;
// YCbCr matrix for RGB-to-NV12/P010 conversion, expressed as AVColorSpace.
// Defaults to BT.709 and must match the stream matrix sent to the renderer.
// YUV sources bypass this matrix. Set before setup.
@property (nonatomic) int rgbSourceMatrix;
// Pixel buffer, PTS and AVFrame scan sidecar are returned atomically and remain
// paired while frames wait in the decoder's pending queue.
- (SPDecodedVideoOutput)decodePacketOutput:(const struct AVPacket *)pkt;
@end
