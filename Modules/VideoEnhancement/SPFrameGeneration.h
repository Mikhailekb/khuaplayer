// Shared core/generator contract. The core owns mode transactions, queues,
// and presentation; callbacks return frames and status. Submission, reset,
// and teardown run on the decode thread. Counters are atomic.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "SPPlayerCore.h"

#ifdef __cplusplus
#include "BoundedQueue.hpp"
#include <atomic>

namespace sp {

// Atomic generation and presentation counters.
struct SPFrameGeneratorCounters {
    std::atomic<uint64_t> generated{0};
    std::atomic<uint64_t> presented{0};
    std::atomic<uint64_t> dropped{0};
    std::atomic<uint64_t> bypassed{0};
    void reset() { generated = 0; presented = 0; dropped = 0; bypassed = 0; }
};

// Core atomic references support live seek/mode checks during bounded waits.
// Pointers are populated at construction and remain valid until shutdown.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
struct SPFrameGeneratorLiveState {
    const std::atomic<int64_t> *generation = nullptr;
    const std::atomic<bool> *seekPending = nullptr;
    const std::atomic<int> *requestedMode = nullptr;
    const std::atomic<uint64_t> *policyEpoch = nullptr;
    const std::atomic<bool> *firstFramePending = nullptr;
    const std::atomic<bool> *running = nullptr;
    const std::atomic<bool> *paused = nullptr;
    const std::atomic<double> *displayMaximumFPS = nullptr;
    const std::atomic<double> *playbackRate = nullptr;
    std::atomic<bool> *activeValue = nullptr;             // Core activity flag, cleared when the engine is destroyed.
    const std::atomic<uint64_t> *lateDrops = nullptr;     // Late presentation drops used as session-pressure feedback.
};

// Media facts set during preparation and stable for the session.
struct SPFrameGeneratorMediaInfo {
    double videoFps = 0.0;
    int64_t frameIntervalUs = 0;
    int videoWidth = 0;
    int videoHeight = 0;
    bool dynamicHDRUnsafe = false;
    bool dynamicHDRRequiresMetadata = false;
    bool interlaced = false;
};

// Transient context for one decode-thread submission.
struct SPFrameGeneratorSubmitContext {
    int64_t ptsUs = 0;
    int64_t generation = 0;
    bool interlaced = false;
    bool scanUnknown = false;
    bool catchUpActive = false;
    uint64_t interruptGeneration = 0;
};

} // namespace sp

typedef sp::PushResult (^SPFrameGeneratorEnqueue)(CVPixelBufferRef buffer, int64_t ptsUs,
                                              int64_t generation, BOOL synthetic,
                                              uint64_t interpolationEpoch,
                                              uint64_t interruptGeneration);
#pragma clang diagnostic pop
#endif

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPFrameGeneratorStatus)(NSString *_Nullable status, BOOL active, int code);
/// Queue depth used to calculate bounded emission waits.
typedef size_t (^SPFrameGeneratorQueueDepth)(void);

// Localized routing descriptions shared by core tooltips and generator status.
// Unmapped codes fall back to the policy's UTF-8 descriptions.
FOUNDATION_EXPORT NSString *_Nullable SPFrameGeneratorLocalizedPolicyStatus(int policyCode);

NS_ASSUME_NONNULL_END
