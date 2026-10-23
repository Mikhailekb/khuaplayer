// Objective-C interface exposed to Swift.
// Keep C++ types out of this header because Swift cannot bridge them.
#import <Cocoa/Cocoa.h>
#import "SPDustSnapshot.h"
#import "SPDamageSnapshot.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorUserInfoKey const SPPlayerErrorPhaseKey;      // NSString：open / decode / read / subtitle
FOUNDATION_EXPORT NSErrorUserInfoKey const SPPlayerErrorDiagnosisKey;  // NSString: zeroHead / indexAtTail / missingMetadata / noPlayableTrack /
                                                                        //   decoderCreate / openFailed / decodeFailed / readWarning / url /
                                                                        //   subtitleLoad (external subtitles rejected; always terminal = NO)
FOUNDATION_EXPORT NSErrorUserInfoKey const SPPlayerErrorTerminalKey;

typedef NS_ENUM(NSInteger, SPPlayerState) {
    SPPlayerStateIdle = 0,
    SPPlayerStateOpening,
    // Reserved for an opened session that has not started playback. Preserve this
    // value so later enum cases keep their stable numeric identities.
    SPPlayerStateReady,
    SPPlayerStatePlaying,
    SPPlayerStatePaused,
    SPPlayerStateEnded,
    SPPlayerStateFailed,
};

// Coherent, selected-file-relative HTTP cache hints. All fields are -1 when
// unavailable. Offsets come from real packet positions, never bitrate estimates.
// The history boundary is the first known packet at/after playbackTime - 20s;
// it deliberately does not keep an older GOP just to avoid a future re-download.
// A known sub-packet audio lead can precede video in the file; its effective
// historyStartTime is then capped at playbackTime, meaning no watched history.
typedef struct SPSourcePlaybackWindow {
    int64_t openGeneration;
    int64_t seekGeneration;
    int64_t playbackOffset;
    int64_t historyStartOffset;
    double playbackTime;
    double historyStartTime;
} SPSourcePlaybackWindow;

// Budget-based Apple frame interpolation, exposed on the macOS 26+ feature tier.
// The requested mode doubles source cadence when resources permit; uncovered
// frame pairs retain the original source cadence.
typedef NS_ENUM(NSInteger, SPFrameInterpolationMode) {
    SPFrameInterpolationModeOff = 0,
    SPFrameInterpolationModeDoubleRate = 1,
};

typedef struct SPVideoInfo {
    int width;
    int height;
    double fps;
    double duration;      // Seconds.
    int hasAudio;
} SPVideoInfo;

@class SPPlayerCore;

/// Cooperative cancellation for short-lived, independent container probes.
/// Thread-safe: the UI may cancel while FFmpeg polls it from a worker thread.
NS_SWIFT_SENDABLE @interface SPProbeCancellationToken : NSObject
@property (atomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

// Delegate callbacks run on the main thread and are exposed to Swift as MainActor.
NS_SWIFT_UI_ACTOR
@protocol SPPlayerCoreDelegate <NSObject>
@optional
- (void)playerCore:(SPPlayerCore *)core didChangeState:(SPPlayerState)state;
- (void)playerCore:(SPPlayerCore *)core didUpdatePosition:(double)position duration:(double)duration;
- (void)playerCore:(SPPlayerCore *)core didFailWithError:(NSError *)error;

- (void)playerCoreDidChangeFrameInterpolation:(SPPlayerCore *)core;
// A new timeline preview is available. Requery the current hover position on the main thread.
- (void)playerCoreDidUpdateTimelinePreview:(SPPlayerCore *)core;
// Decoder reconstruction updated mediaInfo; refresh the decoder detail on the main thread.
- (void)playerCoreDidChangeDecoder:(SPPlayerCore *)core;
// Display capabilities may have changed. Requery xdrAvailable on the main thread.
- (void)playerCoreDidChangeXDRAvailability:(SPPlayerCore *)core;

- (void)playerCoreDidChangeSourceGrowth:(SPPlayerCore *)core;

- (void)playerCore:(SPPlayerCore *)core didSkipMissingContentFrom:(double)fromSec to:(double)toSec afterSeek:(BOOL)afterSeek;

- (void)playerCoreWaitedSourceBecameReady:(SPPlayerCore *)core;
@end

@interface SPPlayerCore : NSObject
- (instancetype)initWithView:(NSView *)view;
// Quick Look skips playback prewarming, subtitle selection and timeline
// thumbnails. The shared media framework contains subtitle support, but
// preview sessions do not initialize subtitle rendering.
- (instancetype)initWithView:(NSView *)view previewMode:(BOOL)previewMode;

// Probe display dimensions in pixels, including sample aspect ratio, from
// container headers without creating a decoder. Failure or audio-only media
// returns CGSizeZero.
+ (CGSize)probeDisplaySizeForURL:(NSURL *)url;
// Cancellable variant used by Quick Look. Cancellation is wired into FFmpeg's
// interrupt callback, so a superseded/expired probe stops doing remote I/O
// instead of merely discarding its eventual result.
+ (CGSize)probeDisplaySizeForURL:(NSURL *)url
              cancellationToken:(nullable SPProbeCancellationToken *)token;
@property (nonatomic, weak) id<SPPlayerCoreDelegate> delegate;
@property (nonatomic, readonly) SPPlayerState state;
@property (nonatomic, readonly) SPVideoInfo videoInfo;
@property (nonatomic, readonly) double position;   // Seconds.
@property (nonatomic, readonly) double duration;

@property (nonatomic, readonly) BOOL sourceGrowing;
@property (nonatomic, readonly) BOOL sourceWaiting;
// Main-thread viewer impact: sustained rebuffer hold/source-blocked seek,
// excluding buffered prefetch and ordinary pause. Raw sourceWaiting is unchanged.
@property (nonatomic, readonly) BOOL sourcePlaybackWaiting;
@property (nonatomic, readonly) BOOL sourceStalled;

@property (nonatomic, readonly) BOOL sourceWaitingForIndex;

@property (nonatomic, readonly) BOOL contentSearching;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) double playbackRate;

@property (nonatomic) SPFrameInterpolationMode frameInterpolationMode;
@property (nonatomic, readonly) BOOL frameInterpolationAvailable;

+ (BOOL)fullFeatureTier;
// Audio-only sessions disable video-specific controls.
@property (nonatomic, readonly) BOOL audioOnlySession;
@property (nonatomic, readonly) BOOL frameInterpolationActive;
@property (nonatomic, readonly, copy) NSString *frameInterpolationStatus;
// A single user-facing sentence for the current unavailability reason.
// Diagnostic details remain in frameInterpolationStatus; no known reason = "".
@property (nonatomic, readonly, copy) NSString *frameInterpolationUnavailableDescription;

@property (nonatomic, readonly) BOOL frameInterpolationContentBypassed;

@property (nonatomic, readonly) double presentedFrameRate;

@property (nonatomic, readonly) double frameInterpolationCoverage;

- (void)setMotionCompareEnabled:(BOOL)enabled;

@property (nonatomic, readonly, copy, nullable) NSString *currentFilePath;

- (BOOL)openFileAtPath:(NSString *)path error:(NSError **)error;
- (BOOL)openMediaAtURL:(NSURL *)url error:(NSError **)error;
// Open at the resume position by seeking before the first decode, avoiding
// presentation of the beginning followed by a second seek.
- (BOOL)openMediaAtURL:(NSURL *)url startAt:(double)seconds error:(NSError **)error;
- (void)play;
- (void)pause;
- (void)togglePlayPause;
- (void)seekTo:(double)seconds;
// precise=NO performs a coarse seek that completes when the selected keyframe is
// displayed (~20 ms, independent of GOP duration) instead of decoding forward
// to the exact target. Timeline clicks and drags intentionally stop at that
// keyframe. Repeated arrow-key seeks show intermediate keyframes; the UI issues
// one precise seek when the key is released.
- (void)seekTo:(double)seconds precise:(BOOL)precise;
// forward=YES applies only to coarse seeks and selects the first keyframe after
// the target. Relative forward steps use it so a GOP longer than the step does
// not repeatedly resolve to the current keyframe.
- (void)seekTo:(double)seconds precise:(BOOL)precise forward:(BOOL)forward;
// Latest-wins advisory prefetch for the hovered keyframe region. It may warm
// file pages without changing playback position or seek semantics.
- (void)prefetchScrubHintAt:(double)seconds;
// Whether the latest seek target was accepted for presentation, allowing the
// next repeated step without invalidating every intermediate target.
@property (nonatomic, readonly) BOOL seekSettled;
// Main-thread snapshot of the current HTTP(S) source's exact AVIO logical
// next-byte cursor. It can precede the end of an already downloaded AVIO buffer.
// Returns -1 while opening, seeking, stopped, or on a non-HTTP source. A settled
// paused session retains its cursor; reading this property never performs I/O.
@property (nonatomic, readonly) int64_t sourceReadOffset;
// Main-thread, no-I/O snapshot anchored to an accepted video frame or the played
// audio clock. Seeking invalidates it until the new generation is settled.
// Unknown history after a seek is omitted rather than guessed; packet/container
// and downstream torrent-piece granularity determine the final cache boundary.
@property (nonatomic, readonly) SPSourcePlaybackWindow sourcePlaybackWindow;
@property (nonatomic, readonly) int64_t sourcePlaybackByteOffset;
@property (nonatomic, readonly) int64_t sourceHistoryStartOffset;
// Verified coarse-seek landing for the current generation, in zero-based
// seconds; -1 means unavailable or unverified. Never reuse a previous generation.
@property (nonatomic, readonly) double lastSettledCoarseSeekLandingSeconds;
// Main-thread hover preview lookup. Return the nearest generated image at or
// before the requested position, boxed as id for CALayer/Swift, or nil. outExact
// indicates verified keyframe coverage, not merely a nearby cached image.
- (nullable id)timelinePreviewImageAt:(double)seconds
                              isExact:(nullable BOOL *)outExact;
// Request the exact preview asynchronously; only the latest request matters.
// Completion notifies the delegate on the main thread.
- (void)requestTimelinePreviewAt:(double)seconds;
// Cancel pending or in-flight hover work without affecting background scanning.
- (void)cancelTimelinePreview;
// Suspend background thumbnail scanning while another window is key. This
// prevents concurrent scanners from competing for storage and CPU while keeping
// on-demand hover previews responsive. The UI drives this from window key state;
// scanning is active by default.
- (void)setTimelinePreviewSuspended:(BOOL)suspended;
// Main-thread particle snapshot with keyframes, coverage and thumbnail colors.
// Nil before the worker starts or when disabled; preview updates announce changes.
- (nullable SPThumbDustSnapshot *)timelineDustSnapshot;
// -- Resilient playback (damaged or incomplete files) --
// Damage snapshot (main thread): tri-state spans merged for the selected tracks plus the actual usable
// end of this open. nil when there is no evidence (always nil for healthy files, so the UI pays nothing).
// Changes arrive through playerCoreDidUpdateTimelinePreview.
- (nullable SPDamageSnapshot *)damageSnapshot;
// PartialEnded: the actual usable end (seconds) recorded when content ran out before the declared
// duration; -1 = never happened. The declared duration is kept; in the Ended state position stops here.
@property (nonatomic, readonly) double availableEndSeconds;
- (void)stepFrame:(NSInteger)delta; // Pause and step by frames; forward pops a frame, other directions use precise seeking.
- (void)setPlaybackRate:(double)rate; // 0.25x ~ 5x
- (void)setVolume:(float)volume;     // 0~5 software gain (100%=1, 500%=5)
@property (nonatomic, readonly) float volume; // Current volume for UI readback.
- (void)setMuted:(BOOL)muted;
// YES means accepted for background reading and validation. Keep current
// subtitles until a validated replacement is ready. Errors preserve the old
// track and notify the delegate. NO means no subtitle renderer is available.
- (BOOL)loadSubtitleFile:(NSString *)path;
// Silent failure skips delegate error presentation. Completion runs on the
// main thread; rejected or obsolete generations report failure.
- (BOOL)loadSubtitleFile:(NSString *)path
                  silent:(BOOL)silent
              completion:(void (^_Nullable)(BOOL ok))completion;
// Explicitly choosing the current/generated subtitle still supersedes a
// pending external load. Invalidate it without clearing the displayed track.
- (void)cancelPendingSubtitleLoad;

// Immutable track snapshots prepared off the main thread. Main-thread reads
// never touch the demuxer. Entries contain container stream index and display title.
@property (nonatomic, readonly) NSArray<NSDictionary *> *audioTrackList;
@property (nonatomic, readonly) NSArray<NSDictionary *> *subtitleTrackList;
@property (nonatomic, readonly) NSInteger currentAudioTrackIndex;    // -1 means none.
@property (nonatomic, readonly) NSInteger currentSubtitleTrackIndex; // -1 means none or disabled.
// Switch audio asynchronously through the demux/audio seek transaction; ignore invalid indices.
- (void)selectAudioTrackAtIndex:(NSInteger)streamIndex;
// Select an embedded subtitle track, replacing external subtitles; -1 disables subtitles.
- (void)selectSubtitleTrackAtIndex:(NSInteger)streamIndex;
// Subtitle scale persists across media; 1.0 is the authored size, clamped to 0.25...3.0.
- (void)setSubtitleScale:(double)scale;
@property (nonatomic, readonly) double subtitleScale;

// Begin a generated virtual track by stopping embedded packets, clearing the
// renderer and loading the supplied ASS header. The container track index is -1;
// the UI tracks the generated selection independently.
- (void)beginGeneratedSubtitleTrackWithHeader:(NSString *)assHeader;
// Append a Matroska ASS event body without a Dialogue prefix, from any thread.
// Ignore events if the generated track has not started or was superseded.
- (void)appendGeneratedSubtitleEvent:(NSString *)assEvent
                             startUs:(int64_t)startUs
                          durationUs:(int64_t)durationUs;
// Idempotently end and clear the generated subtitle track.
- (void)endGeneratedSubtitleTrack;
@property (nonatomic, readonly) BOOL generatedSubtitleActive;
// Signed timeline origin in microseconds, valid after opening and zero while
// closed. Caption readers use this same origin to align with playback timestamps.
@property (nonatomic, readonly) int64_t timelineOriginUs;
// Thread-safe read-only admission for background caption I/O. Protect opening,
// seeking, catch-up, scrubbing and recent presentation starvation; audio-only
// sessions use audio readiness. Non-key windows still contribute playback demand.
- (BOOL)backgroundWorkIdle;
// Content format description after opening, or nil without media.
@property (nonatomic, readonly, copy, nullable) NSString *hdrDescription;
// Multi-line format, color, luminance and current output-path details.
// Requery when display headroom or output configuration changes.
@property (nonatomic, readonly, copy, nullable) NSString *hdrDetailDescription;
// Enable SDR inverse tone mapping into available EDR headroom, capped at 6x.
// Reset on new media. Only SDR video on an EDR-capable display is eligible;
// HDR and non-EDR displays are unchanged. Main-thread access.
@property (nonatomic) BOOL xdrEnabled;
// Whether SDR boost is currently available; valid after opening.
@property (nonatomic, readonly) BOOL xdrAvailable;
// Current display headroom (at least one) and potential EDR capability.
@property (nonatomic, readonly) double displayEDRHeadroom;
@property (nonatomic, readonly) BOOL displayEDRCapable;
// Lift HDR shadows for a brighter viewing environment. Main-thread access.
// Defaults to NO and persists across media opens within this core instance.
// SDR video, encoded black, highlights and subtitle colors are unchanged.
@property (nonatomic) BOOL hdrShadowLiftEnabled;
// Picture controls.
- (void)setAspectMode:(NSInteger)mode;  // 0: original, 1: 16:9, 2: 4:3, 3: stretch, 4: crop.
- (void)setForcedAspect:(double)ratio;  // Positive values force a display aspect ratio; zero restores the default.
- (void)setCropAspect:(double)ratio;    // Positive values crop to the requested ratio; zero disables cropping.
- (void)setRotation:(NSInteger)deg;     // 0/90/180/270
- (void)setMirror:(NSInteger)m;         // 0: none, 1: horizontal, 2: vertical.
- (void)setBrightness:(float)v;         // -0.5~0.5
- (void)setContrast:(float)v;           // 0.5~2
- (void)setSaturation:(float)v;         // 0~2
- (void)setGamma:(float)v;              // Range: 0.5...2.
- (void)setHue:(float)v;                // Range: -180...180 degrees.
// Encode and write the current frame as PNG off the main thread; completion returns to main.
- (void)captureScreenshotToPath:(NSString *)path completion:(void (^_Nullable)(BOOL ok))completion;
// When uniquify is enabled, reserve an unused numbered path with exclusive
// creation. Existence checks and writes stay off the main thread, including on
// slow or remote media volumes. Completion returns the actual destination.
- (void)captureScreenshotToPath:(NSString *)path
                       uniquify:(BOOL)uniquify
                     completion:(void (^_Nullable)(BOOL ok, NSString *finalPath))completion;

- (void)captureScreenshotPNGWithCompletion:(void (^_Nullable)(NSData *_Nullable png))completion;

// On display changes, reselect the output mode and redraw using the new EDR capability.
- (void)displayScreenChanged;
// Resynchronize viewport and redraw paused content after layout; no-op during playback.
- (void)notePausedLayoutChange;
// Main-thread depth-effect parameters. Blur and color strengths of zero use
// the ordinary single pass. Anchor is in drawable pixels from the top left.
// Paused content redraws immediately; playback applies changes to the next frame.
- (void)setWindowDragEffectStrength:(float)strength colorStrength:(float)colorStrength anchorPx:(CGPoint)anchor;
// Prewarm depth-effect pipelines in the background when video interaction begins.
- (void)prewarmWindowDragEffect;
// Media information.
- (NSDictionary *)mediaInfo;
@property (nonatomic, readonly) BOOL isMuted;
// A/B loop positions in seconds; -1 means unset.
- (void)setLoopPointA:(double)sec;
- (void)setLoopPointB:(double)sec;
- (void)clearLoop;
- (void)stop;
// Explicit media-session close (window closes/returns to welcome). Unlike stop
// during a file switch, also releases inactive audio scratch, retaining its unit.
- (void)closeMediaSession;

- (void)cancelIndexWait;
// Present black after closing; stopping alone preserves the layer's last frame.
- (void)clearVideoSurface;
// Main-thread visibility input. Hidden windows retain only the latest intent
// without requesting drawables or encoding; becoming visible resumes its delivery.
- (void)setWindowVisibleForRendering:(BOOL)visible;
// Whether this session has accepted video for presentation. Playing state
// alone does not prove that the first frame is ready.
@property (nonatomic, readonly) BOOL hasEverPresentedThisSession;
// Low-frequency main-thread admission for optional storage work. Protect
// current-generation video readiness, seeking and supply health; paused and
// audio-only sessions use separate rules that can converge without video delivery.
@property (nonatomic, readonly) BOOL backgroundDirectoryScanReady;
@end

// Welcome-page storage warming (implemented in Demuxer.cpp).
#ifdef __cplusplus
extern "C" {
#endif
/// One welcome-page heartbeat for a remote volume (same 2.5 s cadence and
/// per-device single lane as the playback-session heartbeat): open, read 4 KB
/// at a random offset, close. Returns 1 = reached the disk, 0 = another lane
/// beat this device within the period, -1 = local volume (not applicable),
/// -2 = currently unreachable. `devOut` receives the device number.
int SPVolumeHeartbeatBeat(const char *path, int intervalMs, int64_t *_Nullable devOut);
/// Speculative open for a recent MKV/MP4 entry: read the header, seek to the
/// resume point (index), then read packets until `aheadSec` past it without
/// decoding, leaving the bytes in the page cache for the real open. Returns the
/// bytes read, -1 if the file cannot be opened, -3 for other containers.
/// Aborts as soon as `shouldYield(ctx)` returns nonzero.
int64_t SPSpeculativeOpenWarm(const char *path, double resumeSec, double aheadSec,
                              int (*_Nullable shouldYield)(void *_Nullable),
                              void *_Nullable ctx);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
