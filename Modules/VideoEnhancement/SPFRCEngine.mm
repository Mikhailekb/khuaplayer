#import "SPFRCEngine.h"
#include <atomic>
#import "SPMotionFrameCompatibility.hpp"
#import "SPRuntimeGates.hpp"

#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <mutex>
#include <vector>

static NSError *SPFRCError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"dev.khuaplayer.FRCEngine" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

// Display metadata stays immutable. Reconstruction has already consumed any EL.
static void SPFRCCopyStaticAttachments(CVPixelBufferRef source, CVPixelBufferRef destination, bool reconstructed) {
    // Each engine owns its output pool and fixed reconstruction mode. Ordinary
    // engines never attach DV data, so their outputs need no DV pool cleanup.
    if (reconstructed) sp::spMotionCopyDoviMetadata(source, destination);
    for (size_t i = 0; i < sp::kMotionStaticImageAttachmentKeyCount; ++i) {
        CFStringRef key = sp::kMotionStaticImageAttachmentKeys[i];
        CVAttachmentMode mode = kCVAttachmentMode_ShouldNotPropagate;
        CFTypeRef value = CVBufferCopyAttachment(source, key, &mode);
        if (!value) { CVBufferRemoveAttachment(destination, key); continue; }
        CVBufferSetAttachment(destination, key, value, mode);
        CFRelease(value);
    }
    if (reconstructed) {
        CVBufferSetAttachment(destination, kSPDoviReconstructedFrame, kCFBooleanTrue, kCVAttachmentMode_ShouldNotPropagate);
        CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(destination, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, kCVAttachmentMode_ShouldPropagate);
        CVBufferRemoveAttachment(destination, kCVImageBufferChromaLocationBottomFieldKey);
        CVBufferRemoveAttachment(destination, kCVImageBufferCGColorSpaceKey);
        CVBufferRemoveAttachment(destination, kCVImageBufferICCProfileKey);
        CVBufferRemoveAttachment(destination, kCVImageBufferGammaLevelKey);
    }
}

struct SPFRCSlot {
    id processor = nil;
    BOOL busy = NO;
    BOOL retiring = NO;
    CVPixelBufferRef rgbaA = nullptr;
    CVPixelBufferRef rgbaB = nullptr;
    CVPixelBufferRef rgbaOut = nullptr;
    CVPixelBufferRef sourceA = nullptr;
    uint64_t token = 0;
    int64_t startUs = 0;
    int64_t expectedFinishUs = 0;
    SPFRCEngineCompletion completion = nil;
    int64_t frcStartUs = 0;
    double convertGpuSec = 0.0;
};

@implementation SPFRCEngine {
    SPFrameBudgetMetal *_metal;
    dispatch_queue_t _q;
    std::mutex _mtx;
    std::vector<SPFRCSlot> _slots;
    CVPixelBufferPoolRef _outputPool;
    NSDictionary *_outputAux;
    BOOL _invalidated;
    double _latencyEwma;
    double _frcCoreEwma;
    double _convertGpuEwma;
    uint64_t _completed, _failed;
    int64_t _windowStartUs;
    uint64_t _windowPairs;
}

static std::atomic<int> gFRCAvailability{-1};

+ (BOOL)isAvailable {
    const int v = gFRCAvailability.load(std::memory_order_acquire);
    if (v >= 0) return v != 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL available = NO;
        if (@available(macOS 15.4, *)) {
            available = VTFrameRateConversionConfiguration.isSupported;
        }
        gFRCAvailability.store(available ? 1 : 0, std::memory_order_release);
    });
    return gFRCAvailability.load(std::memory_order_acquire) != 0;
}

+ (int)availabilityIfResolved {
    return gFRCAvailability.load(std::memory_order_acquire);
}

+ (void)resolveAvailabilityAsync {
    if (gFRCAvailability.load(std::memory_order_acquire) >= 0) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ (void)[SPFRCEngine isAvailable]; });
}

- (nullable instancetype)initWithMetal:(SPFrameBudgetMetal *)metal
                              sessions:(unsigned)sessions
                        outputCapacity:(NSUInteger)outputCapacity
                                 error:(NSError **)error {
    if (!(self = [super init])) return nil;
    if (!self.class.isAvailable) {
        if (error) *error = SPFRCError(1, @"VTFrameRateConversion unavailable");
        return nil;
    }
    _metal = metal;
    _q = dispatch_queue_create("dev.khuaplayer.frc-engine",
                               dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    const uint64_t pixels = (uint64_t)metal.width * metal.height;
    _latencyEwma = pixels >= 6000000ULL ? 0.165 : (pixels >= 1800000ULL ? 0.055 : 0.030);
    NSDictionary *poolAttrs = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(metal.outputPixelFormat),
        (__bridge NSString *)kCVPixelBufferWidthKey: @(metal.width),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(metal.height),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };

    NSDictionary *poolOpts = @{(__bridge NSString *)kCVPixelBufferPoolMaximumBufferAgeKey: @2.0};
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolOpts,
                                (__bridge CFDictionaryRef)poolAttrs, &_outputPool) != kCVReturnSuccess) {
        if (error) *error = SPFRCError(2, @"output pool");
        return nil;
    }
    _outputAux = @{(__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey: @(MAX((NSUInteger)4, outputCapacity))};
    _windowStartUs = spNowUs();
    if (![self setSessionCount:MAX(1u, MIN(8u, sessions)) error:error]) {
        [self invalidate];
        return nil;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
    if (spDebug()) NSLog(@"[FRC] 引擎释放（完成 %llu 失败 %llu）", (unsigned long long)_completed, (unsigned long long)_failed);
    if (_outputPool) { CFRelease(_outputPool); _outputPool = nullptr; }
}

- (SPFrameBudgetMetal *)metal { return _metal; }

- (unsigned)sessionCount {
    std::lock_guard<std::mutex> lock(_mtx);
    unsigned n = 0;
    for (auto &s : _slots) if (!s.retiring) n++;
    return n;
}

- (unsigned)busyCount {
    std::lock_guard<std::mutex> lock(_mtx);
    unsigned n = 0;
    for (auto &s : _slots) if (s.busy) n++;
    return n;
}

- (double)latencyEstimateSec {
    std::lock_guard<std::mutex> lock(_mtx);
    return _latencyEwma;
}
- (double)frcCoreEstimateSec { std::lock_guard<std::mutex> lock(_mtx); return _frcCoreEwma; }
- (double)conversionGPUEstimateSec { std::lock_guard<std::mutex> lock(_mtx); return _convertGpuEwma; }

- (void)noteConvertGPUSeconds:(double)sec forToken:(uint64_t)token {
    std::lock_guard<std::mutex> lock(_mtx);
    for (auto &s : _slots) if (s.busy && s.token == token) { s.convertGpuSec += sec; break; }
}

- (uint64_t)completedPairs { std::lock_guard<std::mutex> lock(_mtx); return _completed; }
- (uint64_t)failedPairs { std::lock_guard<std::mutex> lock(_mtx); return _failed; }

- (void)resetThroughputWindow {
    std::lock_guard<std::mutex> lock(_mtx);
    _windowStartUs = spNowUs();
    _windowPairs = 0;
}

- (double)throughputWindowPairsPerSecond {
    std::lock_guard<std::mutex> lock(_mtx);
    const double elapsed = (spNowUs() - _windowStartUs) / 1e6;
    return elapsed > 0.05 ? (double)_windowPairs / elapsed : 0.0;
}

- (uint64_t)throughputWindowPairs { std::lock_guard<std::mutex> lock(_mtx); return _windowPairs; }

#pragma mark - Sessions

static CVPixelBufferRef SPFRCCreateRGBA(uint32_t w, uint32_t h) {
    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef b = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_64RGBAHalf,
                            (__bridge CFDictionaryRef)attrs, &b) != kCVReturnSuccess) return nullptr;
    return b;
}

static void SPFRCReleaseSlotBuffers(SPFRCSlot &s) {
    if (s.rgbaA) { CVPixelBufferRelease(s.rgbaA); s.rgbaA = nullptr; }
    if (s.rgbaB) { CVPixelBufferRelease(s.rgbaB); s.rgbaB = nullptr; }
    if (s.rgbaOut) { CVPixelBufferRelease(s.rgbaOut); s.rgbaOut = nullptr; }
}

- (BOOL)openSlot:(SPFRCSlot &)slot error:(NSError **)error {
    if (@available(macOS 15.4, *)) {
        VTFrameRateConversionConfiguration *cfg = [[VTFrameRateConversionConfiguration alloc]
            initWithFrameWidth:_metal.width frameHeight:_metal.height usePrecomputedFlow:NO
            qualityPrioritization:VTFrameRateConversionConfigurationQualityPrioritizationNormal
            revision:VTFrameRateConversionConfigurationRevision1];
        if (!cfg) {
            if (error) *error = SPFRCError(3, @"FRC configuration rejected");
            return NO;
        }
        VTFrameProcessor *proc = [[VTFrameProcessor alloc] init];
        NSError *e = nil;
        if (![proc startSessionWithConfiguration:cfg error:&e]) {
            if (error) *error = e ?: SPFRCError(4, @"FRC session");
            return NO;
        }
        slot.processor = proc;
        slot.rgbaA = SPFRCCreateRGBA(_metal.width, _metal.height);
        slot.rgbaB = SPFRCCreateRGBA(_metal.width, _metal.height);
        slot.rgbaOut = SPFRCCreateRGBA(_metal.width, _metal.height);
        if (!slot.rgbaA || !slot.rgbaB || !slot.rgbaOut) {
            SPFRCReleaseSlotBuffers(slot);
            [proc endSession];
            slot.processor = nil;
            if (error) *error = SPFRCError(5, @"RGBA buffers");
            return NO;
        }
        return YES;
    }
    if (error) *error = SPFRCError(1, @"VTFrameRateConversion unavailable");
    return NO;
}

- (void)closeSlot:(SPFRCSlot &)slot {
    if (@available(macOS 15.4, *)) {
        if (slot.processor) [(VTFrameProcessor *)slot.processor endSession];
    }
    slot.processor = nil;
    SPFRCReleaseSlotBuffers(slot);
}

- (BOOL)setSessionCount:(unsigned)sessions error:(NSError **)error {
    sessions = MAX(1u, MIN(8u, sessions));

    std::vector<SPFRCSlot> added;
    unsigned current;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        if (_invalidated) return NO;
        current = 0;
        for (auto &s : _slots) if (!s.retiring) current++;
    }
    if (sessions > current) {
        const int64_t t0 = spNowUs();
        for (unsigned i = current; i < sessions; ++i) {
            SPFRCSlot s;
            if (![self openSlot:s error:error]) {
                for (auto &a : added) [self closeSlot:a];
                return NO;
            }
            added.push_back(s);
        }
        std::vector<SPFRCSlot> toClose;
        {
            std::lock_guard<std::mutex> lock(_mtx);
            if (_invalidated) {
                toClose = std::move(added);
            } else {

                for (auto &s : _slots) if (s.retiring && !added.empty()) { s.retiring = NO; toClose.push_back(added.back()); added.pop_back(); }
                for (auto &s : added) _slots.push_back(s);
            }
        }
        for (auto &s : toClose) [self closeSlot:s];
        if (spDebug()) NSLog(@"[FRC] 会话数 %u→%u（建会话 %.0fms）", current, sessions, (spNowUs() - t0) / 1e3);
        return YES;
    }
    std::vector<SPFRCSlot> toClose;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        unsigned keep = sessions;
        for (size_t i = 0; i < _slots.size(); ++i) {
            SPFRCSlot &s = _slots[i];
            if (s.retiring) continue;
            if (keep > 0) { keep--; continue; }
            if (s.busy) { s.retiring = YES; continue; }
            toClose.push_back(s);
            _slots.erase(_slots.begin() + (long)i);
            --i;
        }
    }
    for (auto &s : toClose) [self closeSlot:s];
    if (spDebug()) NSLog(@"[FRC] 会话数 %u→%u", current, sessions);
    return YES;
}

- (void)invalidate {
    std::vector<SPFRCSlot> toClose;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        if (_invalidated) return;
        _invalidated = YES;
        for (size_t i = 0; i < _slots.size(); ++i) {
            if (_slots[i].busy) { _slots[i].retiring = YES; continue; }
            toClose.push_back(_slots[i]);
            _slots.erase(_slots.begin() + (long)i);
            --i;
        }
    }
    for (auto &s : toClose) [self closeSlot:s];
}

- (void)flushIdleOutputBuffers {
    if (_outputPool) CVPixelBufferPoolFlush(_outputPool, kCVPixelBufferPoolFlushExcessBuffers);
}

- (void)copySlotBusyRemaining:(double *)out count:(unsigned)count {
    std::lock_guard<std::mutex> lock(_mtx);
    const int64_t now = spNowUs();
    unsigned n = 0;
    for (auto &s : _slots) {
        if (s.retiring || n >= count) continue;
        out[n++] = s.busy ? MAX(0.0, (s.expectedFinishUs - now) / 1e6) : 0.0;
    }
    for (; n < count; ++n) out[n] = 0.0;
}

#pragma mark - Submission

- (BOOL)submitPairWithFrameA:(CVPixelBufferRef)frameA
                      frameB:(CVPixelBufferRef)frameB
                       token:(uint64_t)token
                  completion:(SPFRCEngineCompletion)completion {
    if (!frameA || !frameB || !completion) return NO;
    size_t idx = SIZE_MAX;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        if (_invalidated) return NO;
        for (size_t i = 0; i < _slots.size(); ++i) {
            if (!_slots[i].busy && !_slots[i].retiring) { idx = i; break; }
        }
        if (idx == SIZE_MAX) return NO;
        SPFRCSlot &s = _slots[idx];
        s.busy = YES;
        s.token = token;
        s.startUs = spNowUs();
        s.expectedFinishUs = s.startUs + (int64_t)(_latencyEwma * 1e6);
        s.completion = completion;
        s.sourceA = CVPixelBufferRetain(frameA);
    }
    [_metal adoptColorMatrixFromFrame:frameA];
    const uint64_t slotToken = token;
    NSMutableArray *owners = [NSMutableArray array];
    id<MTLCommandBuffer> cb = [_metal.commandQueue commandBuffer];
    CVPixelBufferRef rgbaA, rgbaB;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        rgbaA = _slots[idx].rgbaA; rgbaB = _slots[idx].rgbaB;
    }
    const BOOL ok = [_metal encodeConvertFrame:frameA toRGBA:rgbaA commandBuffer:cb owners:owners] &&
                    [_metal encodeConvertFrame:frameB toRGBA:rgbaB commandBuffer:cb owners:owners];
    if (!ok) {
        [self completeToken:slotToken output:nullptr error:SPFRCError(6, @"input conversion encode")];
        return YES;
    }

    SPFRCEngine *s = self;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)owners;
        if (done.status != MTLCommandBufferStatusCompleted) {
            [s completeToken:slotToken output:nullptr error:SPFRCError(7, @"input conversion GPU")];
            return;
        }
        [s noteConvertGPUSeconds:(done.GPUEndTime - done.GPUStartTime) forToken:slotToken];
        dispatch_async(s->_q, ^{ [s processToken:slotToken]; });
    }];
    [cb commit];
    return YES;
}

- (BOOL)lookupToken:(uint64_t)token slot:(SPFRCSlot *)out {
    std::lock_guard<std::mutex> lock(_mtx);
    for (auto &s : _slots) {
        if (s.busy && s.token == token) { *out = s; return YES; }
    }
    return NO;
}

- (void)processToken:(uint64_t)token {
    SPFRCSlot slot;
    if (![self lookupToken:token slot:&slot]) return;
    if (@available(macOS 15.4, *)) {
        VTFrameProcessorFrame *fa = [[VTFrameProcessorFrame alloc] initWithBuffer:slot.rgbaA
                                                            presentationTimeStamp:CMTimeMake(0, 48000)];
        VTFrameProcessorFrame *fb = [[VTFrameProcessorFrame alloc] initWithBuffer:slot.rgbaB
                                                            presentationTimeStamp:CMTimeMake(2002, 48000)];
        VTFrameProcessorFrame *fo = [[VTFrameProcessorFrame alloc] initWithBuffer:slot.rgbaOut
                                                            presentationTimeStamp:CMTimeMake(1001, 48000)];
        VTFrameRateConversionParameters *params = fa && fb && fo ? [[VTFrameRateConversionParameters alloc]
            initWithSourceFrame:fa nextFrame:fb opticalFlow:nil interpolationPhase:@[@0.5f]
            submissionMode:VTFrameRateConversionParametersSubmissionModeRandom
            destinationFrames:@[fo]] : nil;
        if (!params) {
            [self completeToken:token output:nullptr error:SPFRCError(8, @"FRC parameters")];
            return;
        }
        {
            std::lock_guard<std::mutex> lock(_mtx);
            for (auto &s : _slots) if (s.busy && s.token == token) { s.frcStartUs = spNowUs(); break; }
        }
        SPFRCEngine *s = self;
        [(VTFrameProcessor *)slot.processor processWithParameters:params
                                               completionHandler:^(id<VTFrameProcessorParameters> p, NSError *err) {
            (void)p;
            const int64_t doneUs = spNowUs();
            dispatch_async(s->_q, ^{
                {
                    std::lock_guard<std::mutex> lock(s->_mtx);
                    for (auto &sl : s->_slots) {
                        if (!sl.busy || sl.token != token || sl.frcStartUs == 0) continue;
                        const double core = (doneUs - sl.frcStartUs) / 1e6;
                        s->_frcCoreEwma = s->_frcCoreEwma <= 0.0 ? core : 0.75 * s->_frcCoreEwma + 0.25 * core;
                        break;
                    }
                }
                if (err) [s completeToken:token output:nullptr error:err];
                else [s convertBackToken:token];
            });
        }];
        return;
    }
    [self completeToken:token output:nullptr error:SPFRCError(1, @"unavailable")];
}

- (void)convertBackToken:(uint64_t)token {
    SPFRCSlot slot;
    if (![self lookupToken:token slot:&slot]) return;
    CVPixelBufferRef out = nullptr;
    const CVReturn r = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault, _outputPool, (__bridge CFDictionaryRef)_outputAux, &out);
    if (r != kCVReturnSuccess || !out) {
        [self completeToken:token output:nullptr
                      error:SPFRCError(r == kCVReturnWouldExceedAllocationThreshold ? 9 : 10,
                                       r == kCVReturnWouldExceedAllocationThreshold ? @"output pool exhausted" : @"output alloc")];
        return;
    }
    NSMutableArray *owners = [NSMutableArray array];
    id<MTLCommandBuffer> cb = [_metal.commandQueue commandBuffer];
    if (![_metal encodeConvertRGBA:slot.rgbaOut toFrame:out commandBuffer:cb owners:owners]) {
        CVPixelBufferRelease(out);
        [self completeToken:token output:nullptr error:SPFRCError(11, @"output conversion encode")];
        return;
    }
    SPFRCCopyStaticAttachments(slot.sourceA, out, _metal.doviReconstruction);
    SPFRCEngine *s = self;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)owners;
        if (done.status != MTLCommandBufferStatusCompleted) {
            CVPixelBufferRelease(out);
            [s completeToken:token output:nullptr error:SPFRCError(12, @"output conversion GPU")];
            return;
        }
        [s noteConvertGPUSeconds:(done.GPUEndTime - done.GPUStartTime) forToken:token];
        [s completeToken:token output:out error:nil];
    }];
    [cb commit];
}

- (void)completeToken:(uint64_t)token output:(CVPixelBufferRef)output error:(NSError *)error {
    SPFRCEngineCompletion completion = nil;
    CVPixelBufferRef sourceA = nullptr;
    double latency = 0.0;
    SPFRCSlot retired;
    BOOL closeRetired = NO;
    {
        std::lock_guard<std::mutex> lock(_mtx);
        size_t idx = SIZE_MAX;
        for (size_t i = 0; i < _slots.size(); ++i) {
            if (_slots[i].busy && _slots[i].token == token) { idx = i; break; }
        }
        if (idx == SIZE_MAX) {
            if (output) CVPixelBufferRelease(output);
            return;
        }
        SPFRCSlot &s = _slots[idx];
        latency = (spNowUs() - s.startUs) / 1e6;
        completion = s.completion;
        sourceA = s.sourceA;
        s.completion = nil;
        s.sourceA = nullptr;
        s.busy = NO;
        s.token = 0;
        const double convert = s.convertGpuSec;
        s.convertGpuSec = 0.0;
        s.frcStartUs = 0;
        if (!error) {
            _completed++;
            _windowPairs++;
            _latencyEwma = _latencyEwma <= 0.0 ? latency : (0.75 * _latencyEwma + 0.25 * latency);
            if (convert > 0.0) _convertGpuEwma = _convertGpuEwma <= 0.0 ? convert : (0.75 * _convertGpuEwma + 0.25 * convert);
        } else {
            _failed++;
        }
        if (s.retiring) {
            retired = s;
            closeRetired = YES;
            _slots.erase(_slots.begin() + (long)idx);
        }
    }
    if (closeRetired) [self closeSlot:retired];
    if (sourceA) CVPixelBufferRelease(sourceA);
    if (completion) completion(token, output, latency, error);
    else if (output) CVPixelBufferRelease(output);
}

@end
