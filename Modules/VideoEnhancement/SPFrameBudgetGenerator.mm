#import "SPFrameBudgetGenerator.h"
#import "SPFRCEngine.h"
#import "SPFrameBudgetMetal.h"
#import "SPFrameBudgetPlanner.hpp"
#import "SPInterpolationRoutingPolicy.hpp"
#import "SPMotionFrameCompatibility.hpp"
#import "SPRuntimeGates.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <pthread.h>
#include <thread>
#include <vector>

#include <mach/mach.h>
#include <sys/sysctl.h>

extern "C" {
#include <libavutil/avutil.h>
}

#define SPLOG(fmt, ...) NSLog(@"[c%u]" fmt, self->_logId, ##__VA_ARGS__)

using namespace sp;

struct SPBudgetEntry {
    CVPixelBufferRef buffer = nullptr;
    int64_t ptsUs = 0;
    int64_t generation = 0;
    uint64_t epoch = 0;
    uint64_t interruptGeneration = 0;
    uint64_t seq = 0;
    bool eligible = true;
    bool chainEnd = false;
    id<MTLTexture> probeTex = nil;
    bool probeCommitted = false;
    id<MTLBuffer> blockResults = nil;

    SPBudgetPair pair;
    int64_t deltaUs = 0;
    CVPixelBufferRef synth = nullptr;
    int64_t submitUs = 0;
};

struct SPBudgetReturned {
    CVPixelBufferRef buffer = nullptr;
    int64_t ptsUs = 0;
    int64_t generation = 0;
};

static double spBudgetBufferSecondsRequested(bool *forced) {
    double seconds = 5.0;
    *forced = false;
#if !SP_APP_STORE

#endif
    return seconds;
}

static uint64_t spBudgetPhysicalMemory(void) {
#if !SP_APP_STORE

#endif
    return NSProcessInfo.processInfo.physicalMemory;
}

static uint64_t spBudgetBytesPerFrame(uint32_t width, uint32_t height, OSType format) {

    const bool eightBit = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                          format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                          format == kCVPixelFormatType_420YpCbCr8Planar ||
                          format == kCVPixelFormatType_420YpCbCr8PlanarFullRange;
    const uint64_t px = (uint64_t)width * height;
    return eightBit ? px * 3 / 2 : px * 3;
}

static inline int64_t spBudgetRunwayUs(size_t depth, int64_t intervalUs) {
    return depth > 1 ? (int64_t)(depth - 1) * intervalUs / 2 : 0;
}

static double spPhysFootprintGB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0.0;
    return (double)info.phys_footprint / 1073741824.0;
}

static unsigned spBudgetFixedSessions(void) {
#if !SP_APP_STORE

#endif
    return 0;
}

static NSString *spBudgetCalibDefaultsKey(uint32_t width, uint32_t height) {
    const uint64_t px = (uint64_t)width * height;
    const char *bucket = px >= 6000000ULL ? "4k" : (px >= 1800000ULL ? "1080" : "sd");
    char model[64] = "unknown";
    size_t len = sizeof(model) - 1;
    if (sysctlbyname("hw.model", model, &len, nullptr, 0) != 0) strlcpy(model, "unknown", sizeof(model));
    const NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    return [NSString stringWithFormat:@"dev.khuaplayer.frc.calib.%s.%s.%ld.%ld", bucket, model,
            (long)os.majorVersion, (long)os.minorVersion];
}

enum SPBudgetCalibMode { SPBudgetCalibNone = 0, SPBudgetCalibFull = 1, SPBudgetCalibVerify = 2, SPBudgetCalibHill = 3 };

struct SPBudgetEmitStat { uint8_t covered = 0; uint8_t toggled = 0; float benefit = 0.0f; };

@implementation SPFrameBudgetGenerator {
    id<MTLDevice> _device;
    unsigned _logId;
    SPFrameGeneratorLiveState _live;
    SPFrameGeneratorMediaInfo _media;
    SPFrameGeneratorEnqueue _enqueue;
    SPFrameGeneratorStatus _status;
    SPFrameGeneratorQueueDepth _queueDepth;
    SPFrameGeneratorCounters _counters;
    double _bufferSeconds;
    double _bufferSecondsRequested;
    bool _bufferForced;
    uint64_t _bytesPerFrame;
    uint64_t _doviEnhancementBytes; // retained FEL surface; monotonic within a media session
    size_t _ringCapacityBase;
    SPBudgetMemoryPressure _memoryPressure;
    dispatch_source_t _memorySource;
    unsigned _memoryCap;
    unsigned _memoryDesiredSessions;
    bool _memoryFits;
    double _memoryRequiredGB;

    std::mutex _mtx;
    std::condition_variable _cv;
    std::deque<SPBudgetEntry> _ring;
    size_t _ringCapacity;
    uint64_t _seq;
    std::deque<SPBudgetReturned> _returned;
    std::atomic<bool> _returnedNonEmpty;
    std::vector<id<MTLTexture>> _probePool;
    std::vector<id<MTLBuffer>> _blockPool;
    bool _chainEnded;
    bool _filledOnce;

    std::thread _emitter;
    bool _emitterStarted;
    bool _emitterQuit;
    bool _emitterPaused;
    bool _emitterBusy;
    bool _shutdownDone;
    bool _observersStarted;

    dispatch_queue_t _work;
    SPFrameBudgetMetal *_metal;
    SPFRCEngine *_engine;
    int _engineState;
    uint64_t _engineEpoch;
    uint64_t _engineBuildSeq;
    uint32_t _engineWidth, _engineHeight;
    OSType _engineFormat;

    uint64_t _pairsMissed;
    std::deque<uint8_t> _coverageWindow;
    uint32_t _coverageWindowCovered;
    std::deque<SPBudgetEmitStat> _emitWindow;
    double _emitBenefitSum, _emitBenefitCoveredSum;
    uint32_t _emitToggles;
    int _emitLastCovered;
    float _emitLastBenefit;
    double _tickUsEwma, _tickUsMax;
    double _probeGpuUsEwma;
    uint64_t _kpiLateSeen, _kpiMissedSeen;
    size_t _lastSelectedSegments, _lastRejectedSegments, _lastPlanned;
    int64_t _lastStatusUs, _lastLogUs;
    int _publishedCode; BOOL _publishedActive;
    NSString *_lastStatusText;
    bool _lastSubmitPolicyActive;

    unsigned _fixedSessions;
    bool _calibrating;
    unsigned _calibTrial;
    uint64_t _calibSaturated;
    int64_t _calibStartUs;
    bool _calibWindowOpen;
    int64_t _calibGen;
    NSString *_calibKey;
    unsigned _calibratedSessions;
    int _calibMode;                 // SPBudgetCalibMode
    std::vector<unsigned> _calibQueue;
    std::vector<SPBudgetCalibSample> _calibSamples;
    double _calibPersistedTp;
    double _calibLatencySec;
    int64_t _calibWarmUntilUs;
    int64_t _driftSinceUs;
    int64_t _hillLastUs;
    bool _recalibRequested;

    id _thermalObserver;
    unsigned _thermalCap;
    unsigned _pressureCap;
    int64_t _pressureHoldUntilUs;
    int64_t _pressureQuietSinceUs;
    uint64_t _lateDropsSeen;
    unsigned _pressureBurstStreak;
    bool _calibDisturbed;
    int64_t _governorLastUs;
}

+ (BOOL)isAvailable { return SPFRCEngine.isAvailable; }
+ (int)availabilityIfResolved { return [SPFRCEngine availabilityIfResolved]; }
+ (void)resolveAvailabilityAsync { [SPFRCEngine resolveAvailabilityAsync]; }

- (instancetype)initWithDevice:(id<MTLDevice>)device
                          logId:(unsigned)logId
                      liveState:(const SPFrameGeneratorLiveState &)liveState
                        enqueue:(SPFrameGeneratorEnqueue)enqueue
                         status:(SPFrameGeneratorStatus)status
                     queueDepth:(SPFrameGeneratorQueueDepth)queueDepth {
    if (!(self = [super init])) return nil;
    _device = device;
    _logId = logId;
    _live = liveState;
    _enqueue = [enqueue copy];
    _status = [status copy];
    _queueDepth = [queueDepth copy];
    _bufferSecondsRequested = spBudgetBufferSecondsRequested(&_bufferForced);
    _bufferSeconds = _bufferSecondsRequested;
    _ringCapacity = _ringCapacityBase = 120;
    _memoryDesiredSessions = 3;
    _memoryFits = true;
    _emitLastCovered = -1;
    _work = dispatch_queue_create("dev.khuaplayer.frame-budget",
                                  dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    _fixedSessions = spBudgetFixedSessions();
    _publishedCode = -1;
    return self;
}

- (void)startObserversIfNeeded {
    if (_observersStarted) return;
    _observersStarted = true;

    __weak SPFrameBudgetGenerator *weakSelf = self;
    auto applyThermal = ^(NSProcessInfoThermalState state) {
        SPFrameBudgetGenerator *s = weakSelf;
        if (!s) return;
        unsigned cap = 0;
        if (state == NSProcessInfoThermalStateSerious) cap = 2;
        else if (state == NSProcessInfoThermalStateCritical) cap = 1;
        dispatch_async(s->_work, ^{
            {
                std::lock_guard<std::mutex> lock(s->_mtx);
                if (s->_thermalCap == cap) return;
                if (s->_thermalCap > 0 && cap == 0) s->_recalibRequested = true;
                s->_thermalCap = cap;
            }
            if (spDebug()) NSLog(@"[c%u][Budget] 热状态 %ld → 路数封顶 %u", s->_logId, (long)state, cap);
            [s tick];
        });
    };
    applyThermal(NSProcessInfo.processInfo.thermalState);
    _thermalObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil
                usingBlock:^(NSNotification *note) { (void)note; applyThermal(NSProcessInfo.processInfo.thermalState); }];

    _memorySource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                           DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
                                           _work);
    if (_memorySource) {
        dispatch_source_t src = _memorySource;
        dispatch_source_set_event_handler(_memorySource, ^{
            SPFrameBudgetGenerator *s = weakSelf;
            if (!s) return;
            const unsigned long flags = dispatch_source_get_data(src);
            SPBudgetMemoryPressure level = SPBudgetMemoryPressure::Normal;
            if (flags & DISPATCH_MEMORYPRESSURE_CRITICAL) level = SPBudgetMemoryPressure::Critical;
            else if (flags & DISPATCH_MEMORYPRESSURE_WARN) level = SPBudgetMemoryPressure::Warn;
            [s applyMemoryPressure:level];
        });
        dispatch_resume(_memorySource);
    }
}

- (void)applyMemoryPressure:(SPBudgetMemoryPressure)level {
    size_t before, after;
    SPFRCEngine *engine = nil;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        if (_memoryPressure == level) return;
        const unsigned wasCap = _memoryCap;
        _memoryPressure = level;
        before = _ringCapacity;
        [self applyRingCapacityLocked];
        after = _ringCapacity;
        if (wasCap > 0 && _memoryCap == 0) _recalibRequested = true;
        if (level != SPBudgetMemoryPressure::Normal) engine = _engine;
    }
    _cv.notify_all();

    [engine flushIdleOutputBuffers];
    if (spDebug()) SPLOG(@"[Budget] 内存压力 %d → 环容量 %zu→%zu（%.1fs）路数封顶 %u 足迹 %.2fGB",
                         (int)level, before, after, _bufferSeconds, _memoryCap, spPhysFootprintGB());
    [self tick];
}

- (void)applyRingCapacityLocked {
    const double fps = _media.videoFps > 1.0 ? _media.videoFps : 24.0;
    SPBudgetMemoryPolicy policy;
    policy.requestedSeconds = _bufferSecondsRequested;
    double base = _bufferSecondsRequested, now = _bufferSecondsRequested;
    unsigned cap = 0;
    _memoryFits = true;
    if (_bufferForced) {
        if (_memoryPressure == SPBudgetMemoryPressure::Warn) now *= policy.warnFactor;
        else if (_memoryPressure == SPBudgetMemoryPressure::Critical) { now = std::min(now, policy.minSeconds); cap = 1; }
    } else {
        const uint64_t phys = spBudgetPhysicalMemory();
        const uint64_t px = (uint64_t)std::max(_media.videoWidth, 1) * (uint64_t)std::max(_media.videoHeight, 1);
        const SPBudgetMemoryPlan normal = spBudgetAllocate(phys, _bytesPerFrame, px, fps, _memoryDesiredSessions,
                                                           SPBudgetMemoryPressure::Normal, policy);
        const SPBudgetMemoryPlan plan = _memoryPressure == SPBudgetMemoryPressure::Normal ? normal
            : spBudgetAllocate(phys, _bytesPerFrame, px, fps, _memoryDesiredSessions, _memoryPressure, policy);
        base = normal.seconds;
        now = plan.seconds;
        _memoryFits = normal.fits;
        _memoryRequiredGB = normal.requiredGB;
        if (plan.sessions < _memoryDesiredSessions || _memoryPressure == SPBudgetMemoryPressure::Critical) cap = plan.sessions;
    }
    _memoryCap = cap;
    _bufferSeconds = now;
    _ringCapacityBase = std::max<size_t>(8, (size_t)std::ceil(base * fps));
    _ringCapacity = std::max<size_t>(8, (size_t)std::ceil(now * fps));
}

- (unsigned)hardSessionCapLocked {
    unsigned cap = _thermalCap;
    if (_memoryCap > 0) cap = cap > 0 ? std::min(cap, _memoryCap) : _memoryCap;
    return cap;
}

- (BOOL)memoryAllowsSessionsLocked:(unsigned)n {
    if (_bufferForced || n == 0) return YES;
    const double fps = _media.videoFps > 1.0 ? _media.videoFps : 24.0;
    const uint64_t px = (uint64_t)std::max(_media.videoWidth, 1) * (uint64_t)std::max(_media.videoHeight, 1);
    SPBudgetMemoryPolicy policy;
    policy.requestedSeconds = _bufferSecondsRequested;
    const SPBudgetMemoryPlan plan = spBudgetAllocate(spBudgetPhysicalMemory(), _bytesPerFrame, px, fps, n,
                                                     _memoryPressure, policy);
    return plan.fits && plan.sessions >= n && plan.seconds + 1e-6 >= _bufferSeconds;
}

- (BOOL)sessionsAdmissibleLocked:(unsigned)n {
    const unsigned hard = [self hardSessionCapLocked];
    if (hard > 0 && n > hard) return NO;
    return [self memoryAllowsSessionsLocked:n];
}

- (void)shutdown {
    {
        std::lock_guard<std::mutex> lock(_mtx);
        if (_shutdownDone) return;
        _shutdownDone = true;
    }
    if (_thermalObserver) { [[NSNotificationCenter defaultCenter] removeObserver:_thermalObserver]; _thermalObserver = nil; }
    if (_memorySource) { dispatch_source_cancel(_memorySource); _memorySource = nil; }
    [self destroyEngine];
    [self discardReturnedFrames];
    {
        std::lock_guard<std::mutex> lock(_mtx);
        _emitterQuit = true;
    }
    _cv.notify_all();
    if (_emitterStarted && _emitter.joinable()) _emitter.join();
    dispatch_sync(_work, ^{});
}

- (void)dealloc {
    [self shutdown];
}

- (SPFrameGeneratorCounters *)counters { return &_counters; }
- (size_t)pendingSourceFrameCount {
    std::lock_guard<std::mutex> lock(_mtx);

    return _ring.size() + _returned.size() + (_emitterBusy ? 1 : 0);
}
- (double)coverageRatio {
    std::lock_guard<std::mutex> lock(_mtx);
    if (_coverageWindow.empty()) return 0.0;
    return (double)_coverageWindowCovered / (double)_coverageWindow.size();
}

- (void)resetForNewMediaWithInfo:(const SPFrameGeneratorMediaInfo &)info {
    [self quiesceEmitterFlushingRingReturning:NO];
    [self discardReturnedFrames];
    _media = info;
    _counters.reset();
    {
        std::lock_guard<std::mutex> lock(_mtx);
        _engineEpoch++;
        _bytesPerFrame = spBudgetBytesPerFrame((uint32_t)std::max(info.videoWidth, 1), (uint32_t)std::max(info.videoHeight, 1), 0);
        _doviEnhancementBytes = 0;
        [self applyRingCapacityLocked];
        _chainEnded = false;
        _filledOnce = false;
        _pairsMissed = 0;
        _coverageWindow.clear();
        _coverageWindowCovered = 0;
        _emitWindow.clear();
        _emitBenefitSum = _emitBenefitCoveredSum = 0.0;
        _emitToggles = 0;
        _emitLastCovered = -1;
        _emitLastBenefit = 0.0f;
        _kpiMissedSeen = 0;
        _publishedCode = -1;
        _publishedActive = NO;
        _lastSubmitPolicyActive = false;
        _emitterPaused = false;
    }
    _cv.notify_all();
    if (spDebug()) SPLOG(@"[Budget] 新媒体 %dx%d %.3ffps 前瞻 %.1fs（上限 %.1fs，物理内存 %.0fGB，每帧 %.1fMB）→ 环容量 %zu 路数上限 %u 装得下=%d（最低需 %.1fGB）",
                         info.videoWidth, info.videoHeight, info.videoFps, _bufferSeconds, _bufferSecondsRequested,
                         spBudgetPhysicalMemory() / 1073741824.0, _bytesPerFrame / 1048576.0, _ringCapacity, _memoryCap,
                         (int)_memoryFits, _memoryRequiredGB);
}

#pragma mark - Status

- (void)publishStatus:(NSString *)status active:(BOOL)active code:(int)code {
    if (_status) _status(status, active, code);
}

#pragma mark - Ring resources

- (BOOL)ringNearlyFullLocked {
    return _ring.size() >= (size_t)std::ceil(0.9 * (double)_ringCapacity);
}

static inline bool spBudgetEntryMatches(const SPBudgetEntry &e, uint32_t width, uint32_t height, OSType format) {
    return e.buffer && CVPixelBufferGetWidth(e.buffer) == width && CVPixelBufferGetHeight(e.buffer) == height &&
           CVPixelBufferGetPixelFormatType(e.buffer) == format;
}

- (bool)entryMatchesEngineLocked:(const SPBudgetEntry &)e {
    return spBudgetEntryMatches(e, _engineWidth, _engineHeight, _engineFormat);
}

- (void)recycleEntryResourcesLocked:(SPBudgetEntry &)e {
    if (e.probeTex) { if (_probePool.size() < _ringCapacity + 4) _probePool.push_back(e.probeTex); e.probeTex = nil; }
    if (e.blockResults) { if (_blockPool.size() < _ringCapacity + 4) _blockPool.push_back(e.blockResults); e.blockResults = nil; }
}

- (void)releaseEntryLocked:(SPBudgetEntry &)e returning:(BOOL)returning {
    if (e.synth) {
        _counters.dropped.fetch_add(1);
        CVPixelBufferRelease(e.synth);
        e.synth = nullptr;
    }
    if (e.buffer) {
        if (returning) { _returned.push_back({e.buffer, e.ptsUs, e.generation}); _returnedNonEmpty.store(true, std::memory_order_release); }
        else CVPixelBufferRelease(e.buffer);
        e.buffer = nullptr;
    }
    [self recycleEntryResourcesLocked:e];
}

#pragma mark - Returned-frame mailbox

- (BOOL)hasReturnedFrames {

    return _returnedNonEmpty.load(std::memory_order_acquire);
}

- (void)drainReturnedFramesWithHandler:(void (^)(CVPixelBufferRef, int64_t, int64_t))handler {
    while (true) {
        SPBudgetReturned f;
        {
            std::lock_guard<std::mutex> lock(_mtx);
            if (_returned.empty()) { _returnedNonEmpty.store(false, std::memory_order_release); return; }
            f = _returned.front();
            _returned.pop_front();
            if (_returned.empty()) _returnedNonEmpty.store(false, std::memory_order_release);
        }
        handler(f.buffer, f.ptsUs, f.generation);
    }
}

- (void)discardReturnedFrames {
    std::lock_guard<std::mutex> lock(_mtx);
    for (auto &f : _returned) if (f.buffer) CVPixelBufferRelease(f.buffer);
    _returned.clear();
    _returnedNonEmpty.store(false, std::memory_order_release);
}

#pragma mark - Emission worker

- (void)ensureEmitterStarted {
    if (_emitterStarted) return;
    _emitterStarted = true;

    _emitter = std::thread([self] {
        pthread_setname_np("dev.khuaplayer.frame-budget-emit");
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
        [self emitterLoop];
    });
}

- (int64_t)boundedWaitUsForEntry:(const SPBudgetEntry &)e {
    const size_t depth = _queueDepth ? _queueDepth() : 0;
    if (depth < 2) return 0;
    const double rate = std::max(_live.playbackRate->load(), 0.01);
    const int64_t T = (int64_t)((_media.frameIntervalUs > 0 ? _media.frameIntervalUs : 41667) / rate);
    const int64_t runway = spBudgetRunwayUs(depth, T) - 10000;
    const double latency = _engine ? _engine.latencyEstimateSec : 0.15;
    const int64_t remaining = e.submitUs + (int64_t)(latency * 1e6) - spNowUs() + 15000;
    return std::max<int64_t>(0, std::min<int64_t>({runway, remaining, 150000}));
}

- (void)emitterLoop {
    std::unique_lock<std::mutex> lk(_mtx);
    while (true) {
        _cv.wait(lk, [&] { return _emitterQuit || (!_emitterPaused && !_ring.empty()); });
        if (_emitterQuit) break;
        _emitterBusy = true;
        const int64_t liveGen = _live.generation->load();
        if (_ring.front().generation != liveGen) {

            SPBudgetEntry e = std::move(_ring.front());
            _ring.pop_front();
            [self releaseEntryLocked:e returning:NO];
            _emitterBusy = false;
            _cv.notify_all();
            continue;
        }
        CVPixelBufferRef synth = nullptr;
        {
            SPBudgetEntry &head = _ring.front();
            const bool hasPair = _ring.size() >= 2 && head.pair.eligible && !head.chainEnd;
            if (hasPair) {
                if (head.pair.state == SPBudgetPairState::InFlight) {
                    const int64_t waitUs = [self boundedWaitUsForEntry:head];
                    if (waitUs > 0) {
                        const uint64_t seq = head.seq;
                        _cv.wait_for(lk, std::chrono::microseconds(waitUs), [&] {
                            return _emitterQuit || _emitterPaused || _ring.empty() || _ring.front().seq != seq ||
                                   _ring.front().pair.state != SPBudgetPairState::InFlight;
                        });
                        if (_emitterQuit) break;
                        if (_emitterPaused || _ring.empty() || _ring.front().seq != seq) {
                            _emitterBusy = false;
                            _cv.notify_all();
                            continue;
                        }
                    }
                }
                SPBudgetEntry &h = _ring.front();
                if (h.pair.state == SPBudgetPairState::Ready && h.synth) {
                    synth = h.synth;
                    h.synth = nullptr;
                } else {
                    if (h.pair.state == SPBudgetPairState::Planned || h.pair.state == SPBudgetPairState::InFlight) _pairsMissed++;
                    h.pair.state = SPBudgetPairState::Skipped;
                }
                _coverageWindow.push_back(synth ? 1 : 0);
                if (synth) _coverageWindowCovered++;
                SPBudgetEmitStat st;
                st.covered = synth ? 1 : 0;
                st.benefit = h.pair.probed && !h.pair.cut ? h.pair.benefit : 0.0f;

                st.toggled = _emitLastCovered >= 0 && (_emitLastCovered != (int)st.covered) &&
                             st.benefit > 0.0f && _emitLastBenefit > 0.0f ? 1 : 0;
                _emitLastCovered = (int)st.covered;
                _emitLastBenefit = st.benefit;
                _emitWindow.push_back(st);
                _emitBenefitSum += st.benefit;
                if (st.covered) _emitBenefitCoveredSum += st.benefit;
                _emitToggles += st.toggled;
                if (_coverageWindow.size() > 240) {
                    if (_coverageWindow.front()) _coverageWindowCovered--;
                    _coverageWindow.pop_front();
                    const SPBudgetEmitStat &old = _emitWindow.front();
                    _emitBenefitSum -= old.benefit;
                    if (old.covered) _emitBenefitCoveredSum -= old.benefit;
                    _emitToggles -= old.toggled;
                    _emitWindow.pop_front();
                }
            }
        }
        SPBudgetEntry e = std::move(_ring.front());
        _ring.pop_front();
        [self recycleEntryResourcesLocked:e];
        if (e.synth) { CVPixelBufferRelease(e.synth); e.synth = nullptr; }
        _cv.notify_all();
        lk.unlock();

        const PushResult r = _enqueue(e.buffer, e.ptsUs, e.generation, NO, e.epoch, e.interruptGeneration);
        if (r == PushResult::Pushed) {
            e.buffer = nullptr;
            if (!e.pair.eligible) _counters.bypassed.fetch_add(1);
            if (synth) {
                const PushResult r2 = _enqueue(synth, e.ptsUs + e.deltaUs / 2, e.generation, YES, e.epoch, e.interruptGeneration);
                if (r2 != PushResult::Pushed) { _counters.dropped.fetch_add(1); CVPixelBufferRelease(synth); }
                synth = nullptr;
            }
        } else if (r == PushResult::Interrupted) {

            lk.lock();
            _returned.push_back({e.buffer, e.ptsUs, e.generation});
            _returnedNonEmpty.store(true, std::memory_order_release);
            e.buffer = nullptr;
            _emitterPaused = true;
            lk.unlock();
            if (synth) { _counters.dropped.fetch_add(1); CVPixelBufferRelease(synth); synth = nullptr; }
        } else {
            if (e.buffer) { CVPixelBufferRelease(e.buffer); e.buffer = nullptr; }
            if (synth) { _counters.dropped.fetch_add(1); CVPixelBufferRelease(synth); synth = nullptr; }
        }
        lk.lock();
        _emitterBusy = false;
        _cv.notify_all();
    }
}

- (void)quiesceEmitterFlushingRingReturning:(BOOL)returning {
    std::unique_lock<std::mutex> lk(_mtx);
    _emitterPaused = true;
    _cv.notify_all();
    _cv.wait(lk, [&] { return !_emitterBusy; });
    const int64_t liveGen = _live.generation->load();
    while (!_ring.empty()) {
        SPBudgetEntry e = std::move(_ring.front());
        _ring.pop_front();
        [self releaseEntryLocked:e returning:(returning && e.generation == liveGen)];
    }
    _cv.notify_all();
}

- (void)breakPairChain {
    std::lock_guard<std::mutex> lock(_mtx);
    if (!_ring.empty()) _ring.back().chainEnd = true;
    _chainEnded = true;
}

- (void)applyModeReset:(SPFrameInterpolationMode)mode {
    {

        std::lock_guard<std::mutex> lock(_mtx);
        if (!_emitterStarted && _engineState == 0 && _ring.empty() && _returned.empty() && !_emitterBusy) {
            _emitterPaused = false;
            return;
        }
    }
    [self quiesceEmitterFlushingRingReturning:YES];
    if (mode == SPFrameInterpolationModeOff) {
        [self destroyEngine];
    }
    std::lock_guard<std::mutex> lock(_mtx);
    _emitterPaused = false;
    _cv.notify_all();
}

- (void)destroyEngine {
    [self quiesceEmitterFlushingRingReturning:YES];
    SPFRCEngine *engine = nil;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        engine = _engine;
        _engine = nil;
        _metal = nil;
        _engineState = 0;
        _engineEpoch++;
        _probePool.clear();
        _blockPool.clear();
        _calibrating = false;
    }
    if (engine) {
        if (spDebug()) SPLOG(@"[Budget] 引擎销毁：完成 %llu 失败 %llu 延迟 %.0fms 路 %u",
                             (unsigned long long)engine.completedPairs, (unsigned long long)engine.failedPairs,
                             engine.latencyEstimateSec * 1e3, engine.sessionCount);

        [engine invalidate];
    }
    if (_live.activeValue) _live.activeValue->store(false);
    {
        std::lock_guard<std::mutex> lock(_mtx);
        _emitterPaused = false;
        _publishedActive = NO;
    }
    _cv.notify_all();
}

#pragma mark - Engine setup on the work queue

- (void)ensureEngineForWidth:(uint32_t)width height:(uint32_t)height format:(OSType)format {
    uint64_t epoch = 0, buildSeq = 0;
    BOOL reconstructDovi = NO;
    SPFRCEngine *old = nil;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        if (_engineState == 1) return;

        if (_engineState != 0 && _engineWidth == width && _engineHeight == height && _engineFormat == format) return;
        _engineState = 1;
        _engineWidth = width; _engineHeight = height; _engineFormat = format;
        epoch = _engineEpoch;
        reconstructDovi = _media.dynamicHDRRequiresMetadata;
        buildSeq = ++_engineBuildSeq;
        old = _engine; _engine = nil; _metal = nil;
        _probePool.clear(); _blockPool.clear();

        for (auto &e : _ring) {
            if (spBudgetEntryMatches(e, width, height, format)) continue;
            e.eligible = false;
            e.pair.eligible = false;
            e.pair.probed = false;
            e.pair.state = SPBudgetPairState::Skipped;
            e.probeTex = nil;
            e.probeCommitted = false;
            e.blockResults = nil;
        }
    }
    [self publishStatus:NSLocalizedString(@"memc.status.budget.preparing", nil) active:NO
                   code:static_cast<int>(SPInterpolationPolicyCode::Preparing)];
    dispatch_async(_work, ^{
        if (old) [old invalidate];
        const int64_t t0 = spNowUs();
        NSError *error = nil;
        SPFrameBudgetMetal *metal = [[SPFrameBudgetMetal alloc] initWithDevice:self->_device library:nil
                                                                          width:width height:height
                                                                    pixelFormat:format error:&error];
        if (metal && reconstructDovi && ![metal enableDoviReconstructionWithError:&error]) metal = nil;
        SPFRCEngine *engine = nil;
        unsigned sessions = self->_fixedSessions;
        NSString *key = spBudgetCalibDefaultsKey(width, height);
        int calibMode = SPBudgetCalibNone;
        double persistedTp = 0.0;
        if (sessions == 0) {
            NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:key];
            const NSInteger n = [saved[@"sessions"] integerValue];
            if (n >= 1 && n <= 8) {

                sessions = (unsigned)n;
                persistedTp = [saved[@"pairsPerSec"] doubleValue];
                calibMode = SPBudgetCalibVerify;
            } else {
                sessions = 3;
                calibMode = SPBudgetCalibFull;
            }
        }
        size_t outputCapacity = 0;
        BOOL stale = NO;

        auto discardStale = ^{
            std::lock_guard<std::mutex> lock(self->_mtx);
            if (self->_engineState == 1 && self->_engineBuildSeq == buildSeq) self->_engineState = 0;
        };
        {
            std::lock_guard<std::mutex> lock(self->_mtx);
            if (self->_engineEpoch != epoch) {
                stale = YES;
            } else {
                self->_bytesPerFrame = spBudgetBytesPerFrame(width, height,
                    reconstructDovi ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : format) + self->_doviEnhancementBytes;
                self->_memoryDesiredSessions = sessions;
                [self applyRingCapacityLocked];
                if (self->_memoryCap > 0 && sessions > self->_memoryCap) {
                    if (spDebug()) NSLog(@"[c%u][Budget] 内存分配：路数 %u→%u（前瞻 %.1fs）", self->_logId, sessions, self->_memoryCap, self->_bufferSeconds);
                    sessions = self->_memoryCap;
                }
                outputCapacity = self->_ringCapacityBase + 16;
            }
        }
        if (stale) {
            discardStale();
            if (spDebug()) SPLOG(@"[Budget] 引擎建立作废（建立期间换片/销毁）%ux%u", width, height);
            return;
        }
        self->_cv.notify_all();
        if (metal) {

            engine = [[SPFRCEngine alloc] initWithMetal:metal sessions:sessions
                                         outputCapacity:outputCapacity error:&error];
        }
        {
            std::lock_guard<std::mutex> lock(self->_mtx);
            if (self->_engineEpoch != epoch) {

                stale = YES;
            } else if (engine) {
                self->_metal = metal;
                self->_engine = engine;
                self->_engineState = 2;
                self->_calibKey = key;
                self->_pressureCap = 0; self->_pressureHoldUntilUs = 0; self->_pressureQuietSinceUs = spNowUs();
                self->_lateDropsSeen = self->_live.lateDrops ? self->_live.lateDrops->load() : 0;
                self->_driftSinceUs = 0; self->_recalibRequested = false; self->_calibLatencySec = 0.0;
                [self beginCalibrationLocked:calibMode sessions:sessions persistedTp:persistedTp warmSec:8.0];
                [engine resetThroughputWindow];
            } else {
                self->_engineState = 3;
            }
        }
        if (stale) {
            if (engine) [engine invalidate];
            discardStale();
            if (spDebug()) SPLOG(@"[Budget] 引擎建立结果作废（建立期间已销毁）%ux%u", width, height);
            return;
        }
        if (engine) {
            if (spDebug()) SPLOG(@"[Budget] 引擎就绪 %ux%u 路=%u 标定模式=%d 探针 %ux%u/%u 建立 %.0fms",
                                 width, height, sessions, calibMode, metal.probeWidth, metal.probeHeight,
                                 metal.probeFactor, (spNowUs() - t0) / 1e3);
            [self probeRingAfterEngineReady];
            [self tick];
        } else {
            SPLOG(@"[Budget] 引擎建立失败 %ux%u: %@", width, height, error.localizedDescription);
            [self publishStatus:[NSString stringWithFormat:NSLocalizedString(@"memc.status.budget.engineFailedFmt", nil),
                                                           error.localizedDescription ?: @"?"]
                         active:NO code:static_cast<int>(SPInterpolationPolicyCode::EngineFailed)];
        }
    });
}

#pragma mark - Decode-thread submission

- (PushResult)submitSourceBuffer:(CVPixelBufferRef)buffer
                         context:(const SPFrameGeneratorSubmitContext &)ctx {
    if (!buffer) return PushResult::Closed;
    const int64_t ptsUs = ctx.ptsUs;
    const int64_t generation = ctx.generation;
    const SPFrameInterpolationMode mode = (SPFrameInterpolationMode)_live.requestedMode->load();
    const uint64_t policyEpoch = _live.policyEpoch->load();
    const OSType format = CVPixelBufferGetPixelFormatType(buffer);
    const uint32_t width = (uint32_t)CVPixelBufferGetWidth(buffer);
    const uint32_t height = (uint32_t)CVPixelBufferGetHeight(buffer);

    SPInterpolationRoutingContext rc;
    rc.requested = mode != SPFrameInterpolationModeOff;
    rc.apiAvailable = rc.requested && SPFRCEngine.isAvailable;
    rc.dynamicHDRUnsafe = _media.dynamicHDRUnsafe ||
        (_media.dynamicHDRRequiresMetadata && !spMotionDoviFrameEligible(buffer));
    rc.interlaced = _media.interlaced || ctx.interlaced;
    rc.scanUnknown = ctx.scanUnknown;
    rc.playbackRate = _live.playbackRate->load();
    rc.videoFPS = _media.videoFps;
    rc.displayMaximumFPS = _live.displayMaximumFPS->load();
    rc.width = width; rc.height = height;
    rc.supportedPixelFormat = spMotionPixelFormatIsSupported(format) && CVPixelBufferGetPlaneCount(buffer) >= 2;
    rc.supportedChromaSiting = rc.supportedPixelFormat && spMotionFrameHasSupportedChromaSiting(buffer);
    rc.hasIOSurface = rc.supportedChromaSiting && CVPixelBufferGetIOSurface(buffer) != nullptr;
    const SPInterpolationPolicyCode policy = spEvaluateInterpolationRouting(rc);
    bool policyActive = spInterpolationPolicyIsActive(policy);
    bool memoryShort = false;
    if (policyActive) {
        std::lock_guard<std::mutex> lock(_mtx);
        if (_media.dynamicHDRRequiresMetadata) {
            if (auto el = spDoviEnhancementFrame(buffer)) {
                uint64_t bytes=0;
                for (size_t p=0;p<CVPixelBufferGetPlaneCount(el);++p)
                    bytes += CVPixelBufferGetBytesPerRowOfPlane(el,p) * CVPixelBufferGetHeightOfPlane(el,p);
                if (bytes > _doviEnhancementBytes) {
                    _doviEnhancementBytes = bytes;
                    _bytesPerFrame = spBudgetBytesPerFrame(width,height,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) + bytes;
                    [self applyRingCapacityLocked];
                }
            }
        }
        memoryShort = !_memoryFits;
    }
    if (memoryShort) {

        policyActive = false;
        const int code = static_cast<int>(SPInterpolationPolicyCode::MemoryLimit);
        bool publish = false;
        double need = 0.0;
        {
            std::lock_guard<std::mutex> lock(_mtx);
            need = _memoryRequiredGB;
            if (_publishedCode != code || _publishedActive) { _publishedCode = code; _publishedActive = NO; publish = true; }
        }
        if (publish) {
            NSString *text = [NSString stringWithFormat:NSLocalizedString(@"memc.status.budget.memoryFmt", nil), need];
            { std::lock_guard<std::mutex> lock(_mtx); _lastStatusText = text; }
            [self publishStatus:text active:NO code:code];
        }
    } else if (!policyActive) {
        const int code = static_cast<int>(policy);
        bool publish = false;
        {
            std::lock_guard<std::mutex> lock(_mtx);
            if (_publishedCode != code || _publishedActive) {
                _publishedCode = code; _publishedActive = NO;
                publish = true;
            }
        }

        if (publish) {
            NSString *text = nil;
            if (policy == SPInterpolationPolicyCode::DisplayCadence) {
                text = [NSString stringWithFormat:NSLocalizedString(@"memc.status.displayCadenceFmt", nil),
                        rc.displayMaximumFPS, _media.videoFps * 2.0 * rc.playbackRate];
            } else {
                text = SPFrameGeneratorLocalizedPolicyStatus(code);
            }
            { std::lock_guard<std::mutex> lock(_mtx); _lastStatusText = text; }
            if (text) [self publishStatus:text active:NO code:code];
        }
    }
    const bool currentGeneration = generation == _live.generation->load();
    const bool transient = !currentGeneration || _live.seekPending->load() || ctx.catchUpActive;
    const bool eligible = policyActive && !transient;
    { std::lock_guard<std::mutex> lock(_mtx); _lastSubmitPolicyActive = policyActive; }
    if (!policyActive) {

        std::unique_lock<std::mutex> lk(_mtx);
        _cv.wait(lk, [&] {
            return (_ring.empty() && !_emitterBusy) || !_live.running->load() ||
                   _emitterPaused || _live.generation->load() != generation;
        });
        if (!_live.running->load()) return PushResult::Closed;
        if (!_ring.empty() || _emitterBusy) return PushResult::Interrupted;
        lk.unlock();
        const PushResult r = _enqueue(buffer, ptsUs, generation, NO, policyEpoch, ctx.interruptGeneration);
        if (r == PushResult::Pushed) _counters.bypassed.fetch_add(1);
        return r;
    }
    [self startObserversIfNeeded];
    [self ensureEmitterStarted];
    if (eligible) [self ensureEngineForWidth:width height:height format:format];

    SPBudgetEntry entry;
    entry.buffer = buffer;
    entry.ptsUs = ptsUs;
    entry.generation = generation;
    entry.epoch = policyEpoch;
    entry.interruptGeneration = ctx.interruptGeneration;
    entry.eligible = eligible;
    entry.pair.eligible = false;
    entry.pair.state = SPBudgetPairState::Skipped;

    SPFrameBudgetMetal *metal = nil;
    id<MTLTexture> prevProbe = nil;
    bool probePrev = false;
    std::unique_lock<std::mutex> lk(_mtx);
    _cv.wait(lk, [&] {
        return _ring.size() < _ringCapacity || !_live.running->load() || _emitterPaused ||
               _live.generation->load() != generation;
    });
    if (!_live.running->load()) return PushResult::Closed;
    if (_ring.size() >= _ringCapacity) return PushResult::Interrupted;
    entry.seq = ++_seq;
    if (_engineState == 2) metal = _metal;

    if (!_ring.empty()) {
        SPBudgetEntry &prev = _ring.back();
        const bool hasPTS = ptsUs != AV_NOPTS_VALUE && prev.ptsUs != AV_NOPTS_VALUE;
        const int64_t delta = hasPTS ? ptsUs - prev.ptsUs : 0;
        const int64_t maxGap = std::max<int64_t>(100000, _media.frameIntervalUs * 3);
        const bool validTiming = hasPTS && delta > 1 && delta <= maxGap;
        const double panelMax = _live.displayMaximumFPS->load();
        const int64_t minOut = panelMax > 1.0 ? (int64_t)llround(1000000.0 / panelMax) : 16667;
        const double midWall = validTiming ? (double)delta / (2.0 * std::max(rc.playbackRate, 0.01)) : 0.0;
        const bool cadenceOK = validTiming && midWall + 1000.0 >= (double)minOut;
        const bool compatible = prev.eligible && eligible && !prev.chainEnd && prev.generation == generation &&
            CVPixelBufferGetWidth(prev.buffer) == width && CVPixelBufferGetHeight(prev.buffer) == height &&
            CVPixelBufferGetPixelFormatType(prev.buffer) == format &&
            spMotionPairCompatibility(prev.buffer, buffer, _media.dynamicHDRRequiresMetadata) ==
                SPMotionPairCompatibility::Compatible;
        if (compatible && validTiming && cadenceOK) {
            prev.pair = SPBudgetPair{};
            prev.pair.eligible = true;
            prev.deltaUs = delta;
            probePrev = metal != nil && prev.probeTex != nil && prev.probeCommitted;
            prevProbe = prev.probeTex;
        } else {
            prev.pair.eligible = false;
            prev.pair.state = SPBudgetPairState::Skipped;
        }
    }

    const bool probe = eligible && metal && !_live.firstFramePending->load();
    if (probe) {
        if (!_probePool.empty()) { entry.probeTex = _probePool.back(); _probePool.pop_back(); }
        else entry.probeTex = [metal newProbeTexture];
        if (probePrev) {
            if (!_blockPool.empty()) { entry.blockResults = _blockPool.back(); _blockPool.pop_back(); }
            else entry.blockResults = [metal newBlockResultBuffer];
        }
    }
    id<MTLTexture> probeTex = entry.probeTex;
    id<MTLBuffer> blockResults = entry.blockResults;
    const uint64_t seq = entry.seq;

    if (probe && probeTex) CVPixelBufferRetain(buffer);
    _ring.push_back(std::move(entry));
    const bool ringNearlyFull = [self ringNearlyFullLocked];
    _cv.notify_all();
    lk.unlock();

    if (probe && probeTex) {
        NSMutableArray *owners = [NSMutableArray array];
        [owners addObject:CFBridgingRelease(buffer)];
        id<MTLCommandBuffer> cb = [metal.commandQueue commandBuffer];
        BOOL ok = [metal encodeDownsampleOfFrame:buffer into:probeTex commandBuffer:cb owners:owners];
        if (ok && probePrev && blockResults) {
            [metal encodeBlockMatchFrom:prevProbe to:probeTex results:blockResults commandBuffer:cb];
        }
        if (ok) {
            __weak SPFrameBudgetGenerator *weakSelf = self;
            const bool scored = probePrev && blockResults != nil;
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                (void)owners;
                SPFrameBudgetGenerator *s = weakSelf;
                if (!s) return;
                const BOOL good = done.status == MTLCommandBufferStatusCompleted;
                const double gpuUs = good ? (done.GPUEndTime - done.GPUStartTime) * 1e6 : 0.0;
                dispatch_async(s->_work, ^{
                    if (gpuUs > 0.0) {
                        std::lock_guard<std::mutex> lock(s->_mtx);
                        s->_probeGpuUsEwma = s->_probeGpuUsEwma <= 0.0 ? gpuUs : 0.9 * s->_probeGpuUsEwma + 0.1 * gpuUs;
                    }
                    [s probeCompletedForSeq:seq scored:scored good:good];
                });
            }];
            [cb commit];

            std::lock_guard<std::mutex> lock(_mtx);
            for (auto it = _ring.rbegin(); it != _ring.rend(); ++it) if (it->seq == seq) { it->probeCommitted = true; break; }
        }
    }

    if (!_filledOnce && ringNearlyFull) {
        dispatch_async(_work, ^{ [self tick]; });
    }
    return PushResult::Pushed;
}

#pragma mark - Motion analysis, planning, and conversion

- (void)probeRingAfterEngineReady {
    SPFrameBudgetMetal *metal = nil;
    NSMutableArray *owners = [NSMutableArray array];
    std::vector<uint64_t> scoredSeqs;
    std::vector<uint64_t> downsampledSeqs;
    id<MTLCommandBuffer> cb = nil;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        if (_engineState != 2 || !_metal) return;
        metal = _metal;
        cb = [metal.commandQueue commandBuffer];
        SPBudgetEntry *prev = nullptr;
        for (auto &e : _ring) {
            if (!e.eligible || ![self entryMatchesEngineLocked:e]) { prev = nullptr; continue; }
            if (!e.probeTex) {
                e.probeTex = _probePool.empty() ? [metal newProbeTexture] : _probePool.back();
                if (!_probePool.empty()) _probePool.pop_back();
                e.probeCommitted = false;
                CVPixelBufferRetain(e.buffer);
                [owners addObject:CFBridgingRelease(e.buffer)];
                if (![metal encodeDownsampleOfFrame:e.buffer into:e.probeTex commandBuffer:cb owners:owners]) {
                    [self recycleEntryResourcesLocked:e];
                    prev = nullptr;
                    continue;
                }
                downsampledSeqs.push_back(e.seq);
            } else if (!e.probeCommitted) {

                prev = nullptr;
                continue;
            }
            if (prev && prev->pair.eligible && !prev->pair.probed && prev->probeTex && !e.blockResults) {
                e.blockResults = _blockPool.empty() ? [metal newBlockResultBuffer] : _blockPool.back();
                if (!_blockPool.empty()) _blockPool.pop_back();
                [metal encodeBlockMatchFrom:prev->probeTex to:e.probeTex results:e.blockResults commandBuffer:cb];
                scoredSeqs.push_back(e.seq);
            }
            prev = &e;
        }
    }

    if (scoredSeqs.empty() && downsampledSeqs.empty()) return;
    __weak SPFrameBudgetGenerator *weakSelf = self;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)owners;
        SPFrameBudgetGenerator *s = weakSelf;
        if (!s) return;
        const BOOL good = done.status == MTLCommandBufferStatusCompleted;
        dispatch_async(s->_work, ^{
            for (uint64_t seq : scoredSeqs) [s probeCompletedForSeq:seq scored:true good:good];
        });
    }];
    [cb commit];
    {
        std::lock_guard<std::mutex> lock(_mtx);
        for (auto &e : _ring) {
            if (std::find(downsampledSeqs.begin(), downsampledSeqs.end(), e.seq) != downsampledSeqs.end()) e.probeCommitted = true;
        }
    }
    if (spDebug()) SPLOG(@"[Budget] 引擎就绪后补探针 %zu 对（缩放 %zu 帧）", scoredSeqs.size(), downsampledSeqs.size());
}

- (void)probeCompletedForSeq:(uint64_t)seq scored:(bool)scored good:(BOOL)good {
    if (!scored) return;
    SPFrameBudgetMetal *metal = nil;
    id<MTLBuffer> results = nil;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        metal = _metal;
        for (auto &e : _ring) if (e.seq == seq) { results = e.blockResults; break; }
    }
    if (!metal || !results) return;
    SPBudgetProbeSummary s = good ? [metal summarizeBlockResults:results] : SPBudgetProbeSummary{};
    {
        std::lock_guard<std::mutex> lock(_mtx);

        for (auto &e : _ring) if (e.seq == seq && e.blockResults == results) {
            if (_blockPool.size() < _ringCapacity + 4) _blockPool.push_back(e.blockResults);
            e.blockResults = nil;
            break;
        }

        for (size_t i = 1; i < _ring.size(); ++i) {
            if (_ring[i].seq != seq) continue;
            SPBudgetEntry &prev = _ring[i - 1];
            if (!prev.pair.eligible) break;
            if (!s.valid) { prev.pair.eligible = false; prev.pair.state = SPBudgetPairState::Skipped; break; }
            prev.pair.probed = true;
            prev.pair.cut = s.cut;
            prev.pair.benefit = s.cut ? 0.0f : s.benefit;
            if (s.cut && spDebug()) {
                SPLOG(@"[Budget] 剪辑 pts=%.3f→%.3f unm=%.2f diff=%.2f coh=%.2f res=%.2f",
                      prev.ptsUs / 1e6, _ring[i].ptsUs / 1e6, s.unmatchedFraction, s.meanAbsDiff, s.coherence, s.residualRatio);
            }
            break;
        }
    }
    [self tick];
}

- (void)tick {
    std::unique_lock<std::mutex> lk(_mtx);
    SPFRCEngine *engine = _engine;
    if (!engine || _engineState != 2) return;
    const size_t n = _ring.size();
    if (n >= 2) {
        std::vector<SPBudgetPair> pairs(n - 1);
        for (size_t i = 0; i + 1 < n; ++i) {
            pairs[i] = _ring[i].pair;
            if (!_ring[i].eligible || !_ring[i + 1].eligible || _ring[i].chainEnd) pairs[i].eligible = false;
        }
        SPBudgetPlanContext ctx;
        const double rate = std::max(_live.playbackRate->load(), 0.01);
        ctx.pairIntervalSec = ((_media.frameIntervalUs > 0 ? _media.frameIntervalUs : 41667) / 1e6) / rate;
        ctx.paused = _live.paused->load();

        const size_t depth = _queueDepth ? _queueDepth() : 0;
        ctx.headOffsetSec = (double)spBudgetRunwayUs(depth, (int64_t)llround(ctx.pairIntervalSec * 1e6)) / 1e6;
        ctx.headSeq = _ring.front().seq;
        ctx.latencySec = engine.latencyEstimateSec;
        ctx.sessions = std::max(1u, engine.sessionCount);
        [engine copySlotBusyRemaining:ctx.slotBusyUntilSec count:8];
        SPBudgetPlanConfig cfg;
        const double fps = _media.videoFps > 1.0 ? _media.videoFps : 24.0;
        cfg.maxSegmentPairs = std::max<size_t>(8, (size_t)llround(fps * 2.0));
        cfg.minSegmentPairs = std::max<size_t>(3, (size_t)llround(fps / 6.0));
        const int64_t planT0 = spNowUs();
        SPBudgetPlanResult plan = spBudgetPlan(pairs, ctx, cfg);
        const double planUs = (double)(spNowUs() - planT0);
        _tickUsEwma = _tickUsEwma <= 0.0 ? planUs : 0.9 * _tickUsEwma + 0.1 * planUs;
        _tickUsMax = std::max(_tickUsMax, planUs);
        for (size_t i = 0; i + 1 < n; ++i) {
            SPBudgetPairState st = _ring[i].pair.state;
            if (st == SPBudgetPairState::InFlight || st == SPBudgetPairState::Ready) continue;
            _ring[i].pair.state = pairs[i].state;
        }
        _lastSelectedSegments = plan.selectedSegments;
        _lastRejectedSegments = plan.rejectedSegments;
        _lastPlanned = plan.plannedPairs;

        size_t planned = plan.plannedPairs;
        size_t i = plan.hasNext ? plan.nextPair : n;
        while (i + 1 < n && engine.busyCount < engine.sessionCount) {
            if (_ring[i].pair.state != SPBudgetPairState::Planned) { ++i; continue; }
            SPBudgetEntry &a = _ring[i];
            SPBudgetEntry &b = _ring[i + 1];
            if (![self entryMatchesEngineLocked:a] || ![self entryMatchesEngineLocked:b]) {

                a.pair.state = SPBudgetPairState::Skipped;
                ++i;
                continue;
            }
            CVPixelBufferRef fa = CVPixelBufferRetain(a.buffer);
            CVPixelBufferRef fb = CVPixelBufferRetain(b.buffer);
            const uint64_t token = a.seq;
            __weak SPFrameBudgetGenerator *weakSelf = self;
            const BOOL submitted = [engine submitPairWithFrameA:fa frameB:fb token:token
                completion:^(uint64_t t, CVPixelBufferRef midpoint, double latency, NSError *error) {
                    (void)latency;
                    SPFrameBudgetGenerator *s = weakSelf;
                    if (!s) { CVPixelBufferRelease(fa); CVPixelBufferRelease(fb); if (midpoint) CVPixelBufferRelease(midpoint); return; }
                    dispatch_async(s->_work, ^{
                        CVPixelBufferRelease(fa); CVPixelBufferRelease(fb);
                        [s pairCompleted:t midpoint:midpoint error:error];
                    });
                }];
            if (!submitted) { CVPixelBufferRelease(fa); CVPixelBufferRelease(fb); break; }
            a.pair.state = SPBudgetPairState::InFlight;
            a.submitUs = spNowUs();
            if (_calibrating && _calibWindowOpen && planned > ctx.sessions) _calibSaturated++;
            if (planned > 0) planned--;
            ++i;
        }
    }
    [self maybePublishStatusLocked];
    [self maybeLogLocked:engine];
    lk.unlock();
    [self calibrateStep];
    [self governSessions:engine];
}

- (void)governSessions:(SPFRCEngine *)engine {
    const int64_t now = spNowUs();
    unsigned target = 0, current = engine.sessionCount;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        if (_engineState != 2 || now - _governorLastUs < 1000000) return;
        _governorLastUs = now;
        const uint64_t drops = _live.lateDrops ? _live.lateDrops->load() : 0;
        const uint64_t delta = drops >= _lateDropsSeen ? drops - _lateDropsSeen : 0;
        _lateDropsSeen = drops;
        if (_calibrating) {

            if (delta >= 10) _calibDisturbed = true;
            const unsigned hard = [self hardSessionCapLocked];
            if (hard == 0 || current <= hard) return;
            target = hard;
            _calibTrial = hard;
            _calibSaturated = 0;
            _calibWindowOpen = false;
            _calibDisturbed = false;
            _calibWarmUntilUs = now + 1500000;
            _calibQueue.erase(std::remove_if(_calibQueue.begin(), _calibQueue.end(), [&](unsigned t) { return t > hard; }),
                              _calibQueue.end());
            if (_calibQueue.empty() || _calibQueue.front() != hard) _calibQueue.insert(_calibQueue.begin(), hard);
            if (spDebug()) SPLOG(@"[Budget] 标定期间硬上限 %u（热 %u/内存 %u）→ 路数 %u→%u，试验重开",
                                 hard, _thermalCap, _memoryCap, current, hard);
        } else {
        _pressureBurstStreak = delta >= 3 ? _pressureBurstStreak + 1 : 0;
        if (delta > 0) {
            _pressureQuietSinceUs = now;

            if (_pressureBurstStreak >= 2 && engine.busyCount > 0 && now >= _pressureHoldUntilUs && current > 1) {
                _pressureCap = current - 1;
                _pressureHoldUntilUs = now + 60000000;
                _pressureBurstStreak = 0;
                if (spDebug()) SPLOG(@"[Budget] 迟到丢帧持续（%llu/s）→ 路数降至 %u（维持 60s）", (unsigned long long)delta, _pressureCap);
            }
        } else if (_pressureCap > 0 && now - _pressureQuietSinceUs > 120000000 && now >= _pressureHoldUntilUs) {
            _pressureCap++;
            _pressureQuietSinceUs = now;
            if (spDebug()) SPLOG(@"[Budget] 120s 无迟到 → 路数回升至 %u", _pressureCap);
        }
        target = _calibratedSessions > 0 ? _calibratedSessions : current;
        if (_thermalCap > 0) target = std::min(target, _thermalCap);
        if (_memoryCap > 0) target = std::min(target, _memoryCap);
        if (_pressureCap > 0) target = std::min(target, _pressureCap);
        if (_pressureCap >= target && _calibratedSessions > 0 && target >= _calibratedSessions) _pressureCap = 0;
        target = std::max(1u, target);

        const bool uncapped = _thermalCap == 0 && _memoryCap == 0 && _pressureCap == 0;
        bool hill = false;
        if (uncapped && [self ringNearlyFullLocked] && target == current) {
            if (_recalibRequested) hill = true;
            else if (_calibLatencySec > 0.0 && spBudgetLatencyDrifted(engine.latencyEstimateSec, _calibLatencySec)) {
                if (_driftSinceUs == 0) _driftSinceUs = now;
                else if (now - _driftSinceUs >= 30000000 && now - _hillLastUs >= 300000000) hill = true;
            } else {
                _driftSinceUs = 0;
            }
        }
        if (hill) {
            _recalibRequested = false;
            _driftSinceUs = 0;
            _hillLastUs = now;
            [self beginCalibrationLocked:SPBudgetCalibHill sessions:current persistedTp:0.0 warmSec:1.5];
            if (spDebug()) SPLOG(@"[Budget] 复测：爬山 路=%u±1（延迟 %.0fms vs 标定 %.0fms）",
                                 current, engine.latencyEstimateSec * 1e3, _calibLatencySec * 1e3);
            return;
        }
        }
    }
    if (target != current) {
        NSError *e = nil;
        if ([engine setSessionCount:target error:&e] && spDebug()) SPLOG(@"[Budget] 路数 %u→%u（治理）", current, target);
    }
}

- (void)pairCompleted:(uint64_t)token midpoint:(CVPixelBufferRef)midpoint error:(NSError *)error {
    {
        std::lock_guard<std::mutex> lock(_mtx);
        for (auto &e : _ring) {
            if (e.seq != token) continue;
            if (e.pair.state == SPBudgetPairState::InFlight) {
                if (midpoint) {
                    e.synth = midpoint; midpoint = nullptr;
                    e.pair.state = SPBudgetPairState::Ready;
                    _counters.generated.fetch_add(1);
                } else {
                    e.pair.state = SPBudgetPairState::Skipped;
                }
            }
            break;
        }
    }
    if (midpoint) { _counters.dropped.fetch_add(1); CVPixelBufferRelease(midpoint); }
    if (error && spDebug()) SPLOG(@"[Budget] FRC 对失败 token=%llu: %@", (unsigned long long)token, error.localizedDescription);
    _cv.notify_all();
    [self tick];
}

#pragma mark - Status and logging under the mutex

- (void)maybePublishStatusLocked {

    if (!_lastSubmitPolicyActive) return;
    const int64_t now = spNowUs();
    if (now - _lastStatusUs < 1000000) return;
    _lastStatusUs = now;
    const size_t fill = _ring.size();
    const double fillRatio = _ringCapacity ? (double)fill / (double)_ringCapacity : 0.0;
    const bool paused = _live.paused->load();
    if (!_filledOnce && ([self ringNearlyFullLocked] || _chainEnded || (paused && fill > 0))) _filledOnce = true;
    NSString *text;
    BOOL active;
    int code;
    if (!_filledOnce) {
        text = [NSString stringWithFormat:NSLocalizedString(@"memc.status.budget.bufferingFmt", nil),
                (int)llround(fillRatio * 100.0)];
        active = NO;
        code = static_cast<int>(SPInterpolationPolicyCode::Preparing);
    } else {
        const int coverage = _coverageWindow.empty() ? 0
            : (int)llround(100.0 * (double)_coverageWindowCovered / (double)_coverageWindow.size() / 5.0) * 5;
        text = [NSString stringWithFormat:NSLocalizedString(@"memc.status.budget.activeFmt", nil),
                _engineWidth, _engineHeight, coverage, _bufferSeconds, _engine ? _engine.sessionCount : 0u];
        active = YES;
        code = static_cast<int>(SPInterpolationPolicyCode::Active);
    }
    if (_publishedCode == code && _publishedActive == active && _lastStatusText && [_lastStatusText isEqualToString:text]) return;
    _publishedCode = code; _publishedActive = active; _lastStatusText = text;
    [self publishStatus:text active:active code:code];
}

- (NSString *)calibDescriptionLocked {
    if (!_calibrating) return [NSString stringWithFormat:@"done(%u)", _calibratedSessions];
    const char *mode = _calibMode == SPBudgetCalibFull ? "full" : (_calibMode == SPBudgetCalibVerify ? "verify" : "hill");
    return [NSString stringWithFormat:@"%s:%u%s", mode, _calibTrial, _calibWindowOpen ? "" : "(warm)"];
}

- (void)maybeLogLocked:(SPFRCEngine *)engine {
    if (!spDebug()) return;
    const int64_t now = spNowUs();
    if (now - _lastLogUs < 5000000) return;
    _lastLogUs = now;
    const double cov = _coverageWindow.empty() ? 0.0 : (double)_coverageWindowCovered / (double)_coverageWindow.size();
    const double wcov = _emitBenefitSum > 1e-6 ? _emitBenefitCoveredSum / _emitBenefitSum : 0.0;
    const double T = (_media.frameIntervalUs > 0 ? _media.frameIntervalUs : 41667) / 1e6;
    const double windowSec = (double)_emitWindow.size() * T;
    const double togglesPerMin = windowSec > 0.0 ? _emitToggles * 60.0 / windowSec : 0.0;
    const uint64_t late = _live.lateDrops ? _live.lateDrops->load() : 0;
    const uint64_t lateDelta = late >= _kpiLateSeen ? late - _kpiLateSeen : 0;
    _kpiLateSeen = late;
    const uint64_t missedDelta = _pairsMissed >= _kpiMissedSeen ? _pairsMissed - _kpiMissedSeen : 0;
    _kpiMissedSeen = _pairsMissed;
    SPLOG(@"[BudgetKPI] cov=%.2f wcov=%.2f toggles/min=%.1f late=%llu expired=%llu fail=%llu | sess=%u busy=%u lat=%.0fms(frc %.0f conv %.1f) done=%llu | ring=%zu/%zu(%.1fs) fp=%.2fGB thermal=%ld cap(th/pr/mem)=%u/%u/%u calib=%@ | probe=%.2fms tick=%.0fµs(max %.0f) plan=%zu seg=%zu/%zu",
          cov, wcov, togglesPerMin, (unsigned long long)lateDelta, (unsigned long long)missedDelta,
          (unsigned long long)engine.failedPairs, engine.sessionCount, engine.busyCount, engine.latencyEstimateSec * 1e3,
          engine.frcCoreEstimateSec * 1e3, engine.conversionGPUEstimateSec * 1e3, (unsigned long long)engine.completedPairs,
          _ring.size(), _ringCapacity, _bufferSeconds, spPhysFootprintGB(), (long)NSProcessInfo.processInfo.thermalState,
          _thermalCap, _pressureCap, _memoryCap, [self calibDescriptionLocked], _probeGpuUsEwma / 1e3, _tickUsEwma, _tickUsMax,
          _lastPlanned, _lastSelectedSegments, _lastSelectedSegments + _lastRejectedSegments);
}

#pragma mark - Session calibration on the work queue

- (void)beginCalibrationLocked:(int)mode sessions:(unsigned)current persistedTp:(double)persistedTp warmSec:(double)warmSec {
    _calibMode = mode;
    _calibrating = mode != SPBudgetCalibNone;
    _calibQueue.clear();
    _calibSamples.clear();
    _calibPersistedTp = persistedTp;
    _calibratedSessions = mode == SPBudgetCalibFull ? 0 : current;

    std::vector<unsigned> wanted;
    if (mode == SPBudgetCalibFull) wanted = {3, 4, 2};
    else if (mode == SPBudgetCalibHill) {
        if (current < 4) wanted.push_back(current + 1);
        if (current > 1) wanted.push_back(current - 1);
    }
    _calibQueue = {current};
    for (unsigned t : wanted) {
        if (t == current) continue;
        if (![self sessionsAdmissibleLocked:t]) continue;
        _calibQueue.push_back(t);
    }
    _calibTrial = current;
    _calibSaturated = 0;
    _calibDisturbed = false;
    _calibStartUs = spNowUs();
    _calibWarmUntilUs = _calibStartUs + (int64_t)(warmSec * 1e6);
    _calibWindowOpen = false;
}

- (void)calibrateStep {
    SPFRCEngine *engine = nil;
    unsigned trial = 0;
    uint64_t saturated = 0;
    int64_t started = 0;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        if (!_calibrating || !_engine || _engineState != 2) return;
        engine = _engine; trial = _calibTrial; saturated = _calibSaturated; started = _calibStartUs;
        const int64_t now = spNowUs();
        const bool warm = now >= _calibWarmUntilUs && [self ringNearlyFullLocked];
        if (!_calibWindowOpen) {
            if (!warm) return;
            _calibWindowOpen = true;
            _calibGen = _live.generation->load();
            _calibSaturated = 0;
            [engine resetThroughputWindow];
            return;
        }
        if (_live.generation->load() != _calibGen || _calibDisturbed) {
            if (spDebug() && _calibDisturbed) SPLOG(@"[Budget] 标定窗内停顿爆发 → 作废重测");
            _calibGen = _live.generation->load();
            _calibDisturbed = false;
            _calibSaturated = 0;
            [engine resetThroughputWindow];
            return;
        }
    }

    const uint64_t windowPairs = [engine throughputWindowPairs];
    const bool timeout = spNowUs() - started > 120000000;
    if ((windowPairs < 40 || saturated < 32) && !timeout) return;
    const double tp = [engine throughputWindowPairsPerSecond];
    const double latencyNow = engine.latencyEstimateSec;
    unsigned next = 0, best = 0;
    double bestTp = 0.0;
    NSString *key = nil;
    int mode = 0;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        const bool valid = windowPairs >= 40 && saturated >= 32;
        if (valid) _calibSamples.push_back({trial, tp});
        if (!_calibQueue.empty() && _calibQueue.front() == trial) _calibQueue.erase(_calibQueue.begin());
        if (spDebug()) SPLOG(@"[Budget] 标定(%d) 路=%u 吞吐 %.1f 对/s（对 %llu 积压提交 %llu 有效=%d）",
                             _calibMode, trial, tp, (unsigned long long)windowPairs, (unsigned long long)saturated, (int)valid);
        if (!timeout && valid) {
            if (_calibMode == SPBudgetCalibVerify) {
                if (spBudgetCalibrationStale(tp, _calibPersistedTp)) {
                    if (spDebug()) SPLOG(@"[Budget] 验证窗偏离持久化值（%.1f vs %.1f 对/s）→ 完整重标定", tp, _calibPersistedTp);
                    _calibMode = SPBudgetCalibFull;
                    _calibratedSessions = 0;
                    for (unsigned t : {3u, 4u, 2u}) if (t != trial) _calibQueue.push_back(t);
                }
            }
            if (_calibMode == SPBudgetCalibFull && _calibQueue.empty()) {
                bool tested1 = false;
                for (auto &sm : _calibSamples) if (sm.sessions == 1) tested1 = true;
                if (spBudgetCalibrationBest(_calibSamples, trial) == 2 && !tested1) _calibQueue.push_back(1);
            }

            while (!_calibQueue.empty() && ![self sessionsAdmissibleLocked:_calibQueue.front()]) {
                _calibQueue.erase(_calibQueue.begin());
            }
            if (!_calibQueue.empty()) next = _calibQueue.front();
        }
        if (next) {
            _calibTrial = next;
            _memoryDesiredSessions = next;
            _calibSaturated = 0;
            _calibWindowOpen = false;
            _calibWarmUntilUs = spNowUs() + 1500000;
        } else {
            const unsigned fallback = _calibratedSessions > 0 ? _calibratedSessions : trial;
            best = spBudgetCalibrationBest(_calibSamples, fallback);
            for (auto &sm : _calibSamples) if (sm.sessions == best) bestTp = sm.pairsPerSec;
            if (bestTp <= 0.0 && _calibMode == SPBudgetCalibVerify) bestTp = _calibPersistedTp;
            _calibrating = false;
            mode = _calibMode;
            _calibMode = SPBudgetCalibNone;
            _calibratedSessions = best;
            _memoryDesiredSessions = best;
            _calibLatencySec = latencyNow;
            _driftSinceUs = 0;
            key = _calibKey;
        }
    }
    if (next) {
        NSError *e = nil;
        if (![engine setSessionCount:next error:&e]) {
            std::lock_guard<std::mutex> lock(_mtx);
            _calibrating = false;
            _calibMode = SPBudgetCalibNone;
            if (_calibratedSessions == 0) _calibratedSessions = engine.sessionCount;
        } else {
            [engine resetThroughputWindow];
        }
        return;
    }
    NSError *e = nil;
    [engine setSessionCount:best error:&e];
    if (key && bestTp > 0.0) {
        [[NSUserDefaults standardUserDefaults] setObject:@{@"sessions": @(best), @"pairsPerSec": @(bestTp),
                                                           @"latencyMs": @(latencyNow * 1e3)}
                                                  forKey:key];
    }
    if (spDebug()) SPLOG(@"[Budget] 标定完成(%d)：路=%u（%.1f 对/s，延迟 %.0fms）", mode, best, bestTp, latencyNow * 1e3);
}

@end

#pragma mark - Routing policy descriptions

NSString *SPFrameGeneratorLocalizedPolicyStatus(int policyCode) {
    const SPInterpolationPolicyCode code = (SPInterpolationPolicyCode)policyCode;
    switch (code) {
        case SPInterpolationPolicyCode::Off:
            return NSLocalizedString(@"memc.policy.off", nil);
        case SPInterpolationPolicyCode::Unavailable:
            return NSLocalizedString(@"memc.policy.unavailable", nil);
        case SPInterpolationPolicyCode::DynamicHDR:
            return NSLocalizedString(@"memc.policy.dynamicHDR", nil);
        case SPInterpolationPolicyCode::Interlaced:
            return NSLocalizedString(@"memc.policy.interlaced", nil);
        case SPInterpolationPolicyCode::ScanUnknown:
            return NSLocalizedString(@"memc.policy.scanUnknown", nil);
        case SPInterpolationPolicyCode::FastPlayback:
            return NSLocalizedString(@"memc.policy.fastPlayback", nil);
        case SPInterpolationPolicyCode::PixelFormat:
            return NSLocalizedString(@"memc.policy.pixelFormat", nil);
        case SPInterpolationPolicyCode::ChromaSiting:
            return NSLocalizedString(@"memc.policy.chromaSiting", nil);
        case SPInterpolationPolicyCode::ResolutionLimit:
            return NSLocalizedString(@"memc.policy.resolutionLimit", nil);
        case SPInterpolationPolicyCode::MissingIOSurface:
            return NSLocalizedString(@"memc.policy.missingIOSurface", nil);

        default:
            break;
    }
    const char *statusUTF8 = sp::spInterpolationPolicyStatusUTF8(code);
    return statusUTF8 ? [NSString stringWithUTF8String:statusUTF8] : nil;
}
