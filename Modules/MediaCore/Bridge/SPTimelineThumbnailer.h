// Independent, on-demand hover previews using a private demuxer, decoder and
// low-priority worker. Background scans require playback admission. Interaction
// interrupts in-flight thumbnail work, and per-thread disk I/O priority protects
// foreground reads. Hover requests use a separate admission gate for responsiveness.
// Shutdown never joins a worker that may be blocked on remote storage; the
// worker retains and releases its own state after observing cancellation.
#import <Foundation/Foundation.h>
#import "SPDustSnapshot.h"

NS_ASSUME_NONNULL_BEGIN

// Worker-thread background admission probe: atomic reads only, no blocking or locks.
struct AVCodecParameters;
typedef BOOL (^SPThumbIdleProbe)(void);

// Worker-thread hover gate. True means foreground opening, seeking or catch-up
// still requires protection. Keep this distinct from stronger scan-idle checks.
typedef BOOL (^SPThumbSeekBusyProbe)(void);

@interface SPTimelineThumbnailer : NSObject

// Owning playback instance for log attribution; zero means unassigned.
@property (nonatomic) unsigned spLogId;

// Stream color metadata from playback preparation. The independent context
// skips stream analysis, so fill only undeclared fields and preserve explicit metadata.
- (instancetype)initWithPath:(NSString *)path
                  durationUs:(int64_t)durationUs
            timelineOriginUs:(int64_t)originUs
                remoteVolume:(BOOL)remoteVolume
              colorPrimaries:(int)colorPrimaries
                    colorTrc:(int)colorTrc
                  colorSpace:(int)colorSpace
                  colorRange:(int)colorRange
                 videoParams:(nullable const struct AVCodecParameters *)videoParams // Prepared codec parameters used when the independent context lacks
                                        // dimensions or codec configuration.
            videoStreamIndex:(int)videoStreamIndex // Selected playback video stream; negative chooses the first video stream.
               videoStreamId:(int)videoStreamId // Selected AVStream.id, or zero if unknown. Validate identity when independent
                                        // stream ordering differs; disable if the chosen stream cannot be found.
                     doviIPT:(BOOL)doviIPT // Dolby Vision without a compatible base (P5 IPTPQc2, P10.0/P20.0): frames
                                        // without an RPU still use the Metal conversion (fixed fallback mapping),
                                        // never a YCbCr interpretation.
                   idleProbe:(SPThumbIdleProbe)idleProbe
               seekBusyProbe:(nullable SPThumbSeekBusyProbe)seekBusyProbe
                    onUpdate:(void (^)(void))onUpdate; // Main-thread notification that another preview is available.

// Start coarse-to-fine scanning across the media using bit-reversed ordering
// so partially completed scans provide coverage throughout the timeline.
- (void)startSweep;

// Main-thread latest-wins request for the preceding keyframe at this position.
- (void)requestPreviewAt:(double)seconds;

// Cancel pending and in-flight hover work, including interrupted retained
// targets, without cancelling an independent scan. Main-thread call.
- (void)cancelPreviewRequest;

// Main-thread lookup of the nearest generated image at or before the target,
// boxed for CALayer/Swift, or nil. outExact means verified keyframe coverage
// proves this is the target's preceding keyframe. False means unverified,
// even if the cached image happens to be correct.
- (nullable id)previewImageAt:(double)seconds isExact:(nullable BOOL *)outExact;

// Foreground interaction interrupts thumbnail work and restarts its quiet interval.
- (void)noteInteraction;

// Main-thread snapshot of keyframes, verified coverage and thumbnail colors.
// Reuse the same object while its generation is unchanged; nil before work starts.
- (nullable SPThumbDustSnapshot *)dustSnapshot;

- (void)shutdown; // Idempotent main-thread shutdown.

@end

NS_ASSUME_NONNULL_END
