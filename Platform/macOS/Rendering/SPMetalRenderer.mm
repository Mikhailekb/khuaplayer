#include "SPMetalRenderer.h"
#include "ShaderSource.h"
#include "SPDoviRPU.hpp"
#import "SPDoviFrame.h"
#include "SPVideoColorMetadata.hpp"
#include "SPShaderUniforms.h"
#include "SPPlanarPixelFormat.h"
#include "SPVideoOrientation.hpp"
#include <mutex>
#include <unordered_map>
#include <vector>
#include <unordered_set>

#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <AppKit/AppKit.h>
#import <simd/simd.h>
#if !SP_APP_STORE
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#endif

static_assert(sp::dovi_gpu::FloatCount == kSPDoviUniformFloatCount,
              "Dolby RPU serialization and Video.metal uniform counts differ");

// Pure output-mode policy.  A HDR attachment requires a retry only on an EDR
// display: an SDR display intentionally keeps mode 0 and tone-maps that same
// frame through the BGRA8 path.  EDR (sdrBoost) lifts SDR content into the
// EDR layer on a capable display; it never changes anything for HDR content
// or on a display without headroom.
static constexpr int spDesiredRendererOutputMode(bool displayEdrCapable,
                                                 bool hasHdr,
                                                 bool sdrBoost = false) {
    return (displayEdrCapable && (hasHdr || sdrBoost)) ? 1 : 0;
}
static constexpr bool spFrameNeedsOutputModeRetry(bool displayEdrCapable,
                                                  bool hasHdr,
                                                  int currentMode,
                                                  bool sdrBoost = false) {
    return spDesiredRendererOutputMode(displayEdrCapable, hasHdr, sdrBoost) != currentMode;
}
static_assert(spFrameNeedsOutputModeRetry(true, true, 0));   // PQ/HLG on EDR
static_assert(spFrameNeedsOutputModeRetry(true, false, 1));  // HDR -> SDR
static_assert(!spFrameNeedsOutputModeRetry(false, true, 0)); // SDR tone-map
static_assert(!spFrameNeedsOutputModeRetry(true, true, 1));  // already EDR
static_assert(spFrameNeedsOutputModeRetry(true, false, 0, true));   // EDR on SDR content
static_assert(!spFrameNeedsOutputModeRetry(true, false, 1, true));  // EDR already EDR
static_assert(!spFrameNeedsOutputModeRetry(false, false, 0, true)); // EDR without headroom
static_assert(!spFrameNeedsOutputModeRetry(true, true, 1, true));

static_assert(sp::spSDRLayerTagKey(sp::kSPGamutBT2020, sp::kSPTransferPQ, true) == 0);  // HDR tone-mapped to 709
static_assert(sp::spSDRLayerTagKey(sp::kSPGamutBT2020, sp::kSPTransferBT709, false) != 0); // 2020 SDR
static_assert(sp::spSDRLayerTagKey(sp::kSPGamutP3, sp::kSPTransferBT709, false) !=
              sp::spSDRLayerTagKey(sp::kSPGamutP3, sp::kSPTransferSRGB, false));

static constexpr bool spOutputConfigNeedsTransition(bool displayEdrCapable, bool hasHdr,
                                                    int currentMode, bool sdrBoost,
                                                    int sourceGamut, int transfer,
                                                    int appliedTagKey) {
    const int desired = spDesiredRendererOutputMode(displayEdrCapable, hasHdr, sdrBoost);
    if (desired != currentMode) return true;
    return desired == 0 && sp::spSDRLayerTagKey(sourceGamut, transfer, hasHdr) != appliedTagKey;
}
static constexpr int kSPTag709 = sp::spSDRLayerTagKey(sp::kSPGamutBT709, sp::kSPTransferBT709, false);
static_assert(spOutputConfigNeedsTransition(false, false, 0, false, sp::kSPGamutP3, sp::kSPTransferBT709, kSPTag709)); // tag 709→P3 pending
static_assert(!spOutputConfigNeedsTransition(false, false, 0, false, sp::kSPGamutP3, sp::kSPTransferBT709,
                                             sp::spSDRLayerTagKey(sp::kSPGamutP3, sp::kSPTransferBT709, false))); // tag applied
static_assert(!spOutputConfigNeedsTransition(true, false, 1, true, sp::kSPGamutP3, sp::kSPTransferBT709, 0)); // EDR layer: tag irrelevant
static_assert(!spOutputConfigNeedsTransition(false, true, 0, false, sp::kSPGamutBT2020, sp::kSPTransferPQ, 0)); // HDR→SDR keeps sRGB tag
static_assert(spOutputConfigNeedsTransition(false, false, 0, false, sp::kSPGamutBT709, sp::kSPTransferSRGB, kSPTag709)); // 709→sRGB transfer pending
// Effective boost = requested ∧ content is SDR ∧ the EDR layer is actually in
// use.  HDR content keeps its own path; on a display without headroom the mode
// stays 0, so the boost bit must stay clear too (no extra PSO, byte-identical
// SDR output, and the log/description report the truth).
static constexpr bool spEffectiveSdrBoost(bool requested, bool hasHdr, int outputMode) {
    return requested && !hasHdr && outputMode == 1;
}
static_assert(spEffectiveSdrBoost(true, false, 1));
static_assert(!spEffectiveSdrBoost(true, false, 0));
static_assert(!spEffectiveSdrBoost(true, true, 1));
static_assert(!spEffectiveSdrBoost(false, false, 1));

#include "SPRuntimeGates.hpp"

#if !SP_APP_STORE
// SP_FORCE_EDR headroom: 10x, or SP_EDR_HEADROOM when pinned for reproducible
// EDR goldens. Screen changes must not undo the value the core poll pins.
static CGFloat spForcedEDRHeadroom() {
    static const double pinned = spAutomation() && getenv("SP_EDR_HEADROOM")
                                     ? atof(getenv("SP_EDR_HEADROOM")) : 0.0;
    return pinned > 0 ? pinned : 10.0;
}
#endif

static CGColorSpaceRef spSDRLayerColorSpace(int tagKey) {
#if !SP_APP_STORE
    static const bool unmanaged = getenv("SP_NO_COLORMATCH") != nullptr;
    if (unmanaged) return NULL;
#endif
    static std::mutex mtx;
    static std::unordered_map<int, CGColorSpaceRef> cache;
    std::lock_guard<std::mutex> lock(mtx);
    auto it = cache.find(tagKey);
    if (it != cache.end()) return it->second;
    CGColorSpaceRef cs = NULL;
    if (tagKey != 0) {
        const int gamut = sp::spSDRLayerTagKeyGamut(tagKey);
        const int transfer = sp::spSDRLayerTagKeyTransfer(tagKey);
        NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithCapacity:4];
        attrs[(__bridge NSString *)kCVImageBufferColorPrimariesKey] =
            (__bridge NSString *)sp::spCVColorPrimariesForGamut(gamut);
        attrs[(__bridge NSString *)kCVImageBufferTransferFunctionKey] =
            (__bridge NSString *)sp::spCVTransferFunctionForTransfer(transfer);
        attrs[(__bridge NSString *)kCVImageBufferYCbCrMatrixKey] =
            (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        const double gammaLevel = sp::spCVGammaLevelForTransfer(transfer);
        if (gammaLevel > 0) attrs[(__bridge NSString *)kCVImageBufferGammaLevelKey] = @(gammaLevel);
        cs = CVImageBufferCreateColorSpaceFromAttachments((__bridge CFDictionaryRef)attrs);
    }
    if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    cache[tagKey] = cs;
    return cs;
}

static NSString *spSDRLayerTagDescription(int tagKey) {
    if (tagKey == 0) return @"sRGB(HDR→SDR)";
    return [NSString stringWithFormat:@"cv(gamut=%d trc=%d)",
            sp::spSDRLayerTagKeyGamut(tagKey), sp::spSDRLayerTagKeyTransfer(tagKey)];
}

#define SPLOG(fmt, ...) NSLog(@"[c%u]" fmt, self->_spLogId, ##__VA_ARGS__)

#if !SP_APP_STORE

static void spWriteRenderDump(id<MTLTexture> dumpTex, NSString *dumpPath,
                              unsigned logId) {

        if (dumpTex.pixelFormat == MTLPixelFormatRGBA16Float) {
            size_t w = dumpTex.width, h = dumpTex.height;
            size_t rowBytes = w * 4 * sizeof(__fp16);
            __fp16 *buf = (__fp16 *)malloc(rowBytes * h);
            if (buf) {
                [dumpTex getBytes:buf bytesPerRow:rowBytes
                       fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
                float mx = 0.0f;
                double over = 0;
                size_t n = w * h;
                for (size_t i = 0; i < n; i++) {
                    for (int c = 0; c < 3; c++) {
                        float v = (float)buf[i * 4 + c];
                        if (v > mx) mx = v;
                    }
                    if ((float)buf[i * 4 + 1] > 1.0f) over++;
                }
                NSLog(@"[c%u][Renderer] EDR 值域: 峰值=%.3f (%.0f nits) 超参考白像素=%.2f%%",
                      logId, mx, mx * 100.0f, 100.0 * over / (double)n);
                free(buf);
            }
        }
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CIImage *ci = [CIImage imageWithMTLTexture:dumpTex
                                           options:@{kCIImageColorSpace : (__bridge id)cs}];
        CGColorSpaceRelease(cs);
        if (ci) {
            ci = [ci imageByApplyingTransform:CGAffineTransformMake(1, 0, 0, -1, 0, ci.extent.size.height)];
            CIContext *cictx = [CIContext context];
            CGImageRef cg = [cictx createCGImage:ci fromRect:ci.extent];
            if (cg) {
                NSURL *url = [NSURL fileURLWithPath:dumpPath];
                CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
                    (__bridge CFURLRef)url, (__bridge CFStringRef)@"public.png", 1, NULL);
                if (dest) {
                    CGImageDestinationAddImage(dest, cg, NULL);
                    CGImageDestinationFinalize(dest);
                    CFRelease(dest);
                    NSLog(@"[c%u][Renderer] 渲染输出已存 %@", logId, dumpPath);
                }
                CGImageRelease(cg);
            } else {
                NSLog(@"[c%u][Renderer] 渲染输出编码失败（像素格式 %lu）",
                      logId, (unsigned long)dumpTex.pixelFormat);
            }
        }
}
#endif

// What the last committed frame of a DV session showed (media-info status).
enum class SPDoviFrameMode : uint8_t {
    Pending, BaseLayer, FixedIPT, Rpu, RpuWithEnhancement, MissingEnhancement
};

@implementation SPMetalRenderer {

    bool _dbgAttachmentsDumped;
    OSType _dbgLoggedPixFmts[2];
    int _dbgSplitDraws;
    CAMetalLayer *_layer;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLRenderPipelineState> _doviPipeline;  // DV-only fallback, prepared on selected-file open
    BOOL _doviMappingEnabled;
    NSMutableArray *_doviOutputWaiters; // OpenIssued only, protected by _cfgMtx
    uint64_t _doviStatusEpoch; // all fields below protected by _cfgMtx
    SPDoviFrameMode _doviFrameMode; // last committed DV frame's processing (media info)
    sp::DoviDisplaySelection _doviSelection;
    bool _doviHasLevel1;
    id<MTLLibrary> _shaderLib;

    id<MTLRenderPipelineState> _specPipeline;
    uint32_t _specPipelineKey;

    id<MTLRenderPipelineState> _specPipeline2;
    uint32_t _specPipelineKey2;
    std::mutex _specMtx;
    std::atomic<bool> _specBuilding;
    std::atomic<uint32_t> _specFailedKey;

    std::atomic<int64_t> _gpuTimeAccumNs;
    std::atomic<int> _gpuTimeFrames;
#if !SP_APP_STORE
    std::atomic<bool> _dumpPending;
    NSString *_dumpPath;
#endif
    std::atomic<bool> _logNextPresent;

#if !SP_APP_STORE
    std::mutex _vstatsMtx;
    double _vstatsPrevPresented;
    std::vector<double> _vstatsDeltas;
    int _vstatsZero;
    int _vstatsLongGaps;
#endif
    CVMetalTextureCacheRef _textureCache;

    int _primaries, _transfer, _range, _bits, _hasHdr;
    int _planar;
    int _sourceGamut;
    int _layerTagKey;

    BOOL _streamDeclaredMatrix;
    BOOL _streamDeclaredPrimaries;
    BOOL _displayEdrCapable;
    CGFloat _displayCurrentEDR;

    BOOL _sdrBoostRequested;
    BOOL _hdrShadowLiftEnabled;

    float _xdrHeadroomSmoothed;
    int64_t _xdrHeadroomAtUs;

    std::mutex _cfgMtx;
    // Rendering is drained on a renderer-specific serial queue because
    // nextDrawable can block for hundreds of milliseconds while occluded or
    // saturated. renderPixelBuffer and clearToBlack return after admission.
    // The queue is latest-wins: a newer frame replaces queued work, and a
    // temporary drawable failure is retried after 100 ms until presentation or
    // replacement. SP_RENDER_INLINE retains a synchronous diagnostic fallback.
    dispatch_queue_t _submitQueue;
    std::mutex _submitMtx;
    CVPixelBufferRef _submitPendingBuf;
    bool _submitPendingClear;
    bool _submitDrainScheduled;
    int _submitRetryCount;
    bool _submitRetryDelayed;

    bool _submitParked;

    id<MTLTexture> _submitPendingSubTex;
    CGRect _submitPendingSubRect;

    bool _submitPendingSpeculative;

    uint64_t _submitAcceptedInEpoch;

    std::atomic<uint64_t> _submitSessionEpoch;
    uint64_t _submitPendingEpoch;

    std::atomic<bool> _submitsSuspended;

    std::atomic<uint64_t> _cfgGeneration;

    std::atomic<bool> _outputModeSwitchPending;
    std::atomic<uint64_t> _committedFrames;
    std::atomic<uint64_t> _hardRenderFailures;
    float _peakNits;
    int _outputMode;
    float _displayPeakNits;

    CGSize _viewportPixelSize;
    float _sampleAspect;
    float _forcedAspect;
    float _cropAspect;   // Independent crop ratio (>0 enabled; 0 disabled).
    BOOL _doviIPT;

    id<MTLBuffer> _doviZeroBuf;
    id<MTLTexture> _subtitleTexture;
    CVPixelBufferRef _compareBuffer;

    CVPixelBufferRef _compareConverted;
    CVPixelBufferRef _compareConvertedSource;

    BOOL _compareSplitEnabled;
    CGRect _subtitleRect;
    int _aspectMode, _rotation, _mirror;
    sp::VideoOrientation _streamOrientation; // container display matrix; _rotation/_mirror act on top
    float _brightness, _contrast, _saturation, _gamma, _hue;

    float _fxStrength;
    float _fxColorStrength;
    CGPoint _fxAnchorPx;

    id<MTLTexture> _fxLevels[7];
    MTLPixelFormat _fxTexFormat;
    NSUInteger _fxTexW, _fxTexH;
    id<MTLRenderPipelineState> _fxDownPipe, _fxCompPipe;
    MTLPixelFormat _fxPipeFormat;
    int64_t _fxLastUseUs;
    int64_t _fxAllocFailUs;
    bool _fxFailLogged;

}

static inline void spBindDovi(id<MTLRenderCommandEncoder> enc,
                              const SPDoviUniforms *data,
                              id<MTLBuffer> zeroBuf) {
    if (data) {
        [enc setFragmentBytes:data length:sizeof(*data) atIndex:1];
    } else if (zeroBuf) {
        [enc setFragmentBuffer:zeroBuf offset:0 atIndex:1];
    } else {
        static const SPDoviUniforms z = {};
        [enc setFragmentBytes:&z length:sizeof(z) atIndex:1];
    }
}

enum class SPSubmitOutcome {
    Committed,
    StaleEpoch,
    ConfigGenRace,
    OutputModeSwitch,
    Transient,
};

struct SPCVTexGuard {
    CVMetalTextureRef refs[10] = {};
    bool armed = false;
    ~SPCVTexGuard() {
        if (!armed) return;
        for (CVMetalTextureRef r : refs) {
            if (r) CFRelease(r);
        }
    }
};

struct SPAspectModel { float dispAspect, eff, cw, ch; };
static inline SPAspectModel spAspectModel(float vidW, float vidH, float sar,
                                          float forcedAspect, float cropAspect) {
    float s = sar > 0 ? sar : 1.0f;
    float aV = (vidW > 0 && vidH > 0) ? vidW * s / vidH : 16.0f / 9.0f;
    if (forcedAspect > 0.1f) aV = forcedAspect;
    float eff = forcedAspect, cw = 0.0f, ch = 0.0f;
    if (cropAspect > 0.1f) {

        cw = MIN(1.0f, cropAspect / aV);
        ch = MIN(1.0f, aV / cropAspect);
        eff = cropAspect;
        aV = cropAspect;
    }
    return {aV, eff, cw, ch};
}

// Aspect overrides and crop ratios describe the upright picture the user sees
// before any manual rotation. With a quarter-turn container orientation, solve
// the model in upright space (axes swapped, SAR inverted) and map the result
// back to coded texture space, where uniform 27 is the coded-axis ratio and
// 28/29 are texture u/v keep fractions.
static inline SPAspectModel spOrientedAspectModel(float vidW, float vidH, float sar,
                                                  float forcedAspect, float cropAspect,
                                                  sp::VideoOrientation stream) {
    if (!stream.swapsAxes()) return spAspectModel(vidW, vidH, sar, forcedAspect, cropAspect);
    const float s = sar > 0 ? sar : 1.0f;
    SPAspectModel up = spAspectModel(vidH, vidW, 1.0f / s, forcedAspect, cropAspect);
    return {up.dispAspect, up.eff > 0.0f ? 1.0f / up.eff : 0.0f, up.ch, up.cw};
}

static id<MTLDevice> spSharedMetalDevice(void) {
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice(); });
    return device;
}

static CGColorSpaceRef spSDRLayerColorSpace(int tagKey);
extern "C" void SPPrewarmMetalDevice(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        (void)spSharedMetalDevice();

        (void)spSDRLayerColorSpace(kSPTag709);
    });
}

// The shader library and pipeline cache are process-wide. They depend only on
// the shared device and specialization parameters, so per-renderer copies would
// duplicate compilation work (about 150 ms per source fallback). Immutable
// shared ownership also keeps background specialization from observing a
// released library.
static id<MTLLibrary> spSharedShaderLibrary(unsigned logId) {
    static id<MTLLibrary> lib;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *error = nil;
        int64_t t0 = spNowUs();
        id<MTLDevice> device = spSharedMetalDevice();

        id<MTLLibrary> l = [device newDefaultLibraryWithBundle:
                                [NSBundle bundleForClass:SPMetalRenderer.class]
                                                         error:&error];
        bool precompiled = (l != nil);
        if (!l) {
            l = [device newLibraryWithSource:@(kSPShaderSource) options:nil error:&error];
        }
        if (spDebug()) {
            NSLog(@"[c%u][Renderer] shader 加载: %.1fms (%@，进程级共享)", logId,
                  (spNowUs() - t0) / 1000.0,
                  precompiled ? @"预编译 metallib" : @"源码编译兜底");
        }
        if (!l) NSLog(@"[c%u][Renderer] 着色器编译失败: %@", logId, error);
        lib = l;
    });
    return lib;
}

static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *
spPipelineCacheLocked(NSLock **outLock) {
    static NSMutableDictionary *cache;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
        lock = [[NSLock alloc] init];
    });
    *outLock = lock;
    return cache;
}

static id<MTLRenderPipelineState> spCachedPipeline(uint64_t key) {
    NSLock *lock = nil;
    NSMutableDictionary *cache = spPipelineCacheLocked(&lock);
    [lock lock];
    id<MTLRenderPipelineState> p = cache[@(key)];
    [lock unlock];
    return p;
}

static void spStorePipeline(uint64_t key, id<MTLRenderPipelineState> pipe) {
    if (!pipe) return;
    NSLock *lock = nil;
    NSMutableDictionary *cache = spPipelineCacheLocked(&lock);
    [lock lock];
    cache[@(key)] = pipe;
    [lock unlock];
}

static inline uint64_t spGenericPipeKey(MTLPixelFormat fmt, bool dovi) {
    return 0x1000000000ULL | (uint64_t(dovi) << 32) | (uint64_t)fmt;
}
static inline uint64_t spSpecPipeKey(uint32_t contentKey) {
    return 0x2000000000ULL | (uint64_t)contentKey;
}

static inline uint64_t spDragFxPipeKey(int kind, MTLPixelFormat fmt) {
    return (kind == 0 ? 0x3000000000ULL : 0x4000000000ULL) | (uint64_t)fmt;
}

static constexpr int64_t kSPDragFxIdleReleaseUs = 3000000;
static constexpr float kSPDragFxNearLevel = 1.5f;
static constexpr float kSPDragFxFarLevel = 5.0f;
static constexpr int kSPDragFxLevelCount = 5; // = ceil(kSPDragFxFarLevel)，≤ 6
static_assert(kSPDragFxLevelCount >= 1 && kSPDragFxLevelCount <= 6);
static_assert((float)kSPDragFxLevelCount >= kSPDragFxFarLevel &&
              (float)(kSPDragFxLevelCount - 1) < kSPDragFxFarLevel,
              "kSPDragFxLevelCount must equal ceil(kSPDragFxFarLevel)");
static_assert(kSPDragFxNearLevel <= kSPDragFxFarLevel);

- (instancetype)initWithLayer:(CAMetalLayer *)layer logId:(unsigned)logId {
    self = [super init];
    if (self) {
        _spLogId = logId;
        _layer = layer;
        int64_t tDev0 = 0;
        if (spDebug()) {
            tDev0 = spNowUs();
        }
        _device = spSharedMetalDevice();
        if (tDev0) {
            SPLOG(@"[Launch] Metal 设备获取 %.1fms",
                  (spNowUs() - tDev0) / 1000.0);
        }
        if (!_device) return nil;

        _doviZeroBuf = [_device newBufferWithLength:sizeof(SPDoviUniforms)
                                            options:MTLResourceStorageModeShared];
        if (_doviZeroBuf) memset(_doviZeroBuf.contents, 0, sizeof(SPDoviUniforms));

        _layer.device = _device;

#if SP_APP_STORE
        _layer.framebufferOnly = YES;
#else
        _layer.framebufferOnly = getenv("SP_RENDERDUMP") ? NO : YES;
#endif

#if SP_APP_STORE
        _layer.maximumDrawableCount = 3;
#else
        _layer.maximumDrawableCount =
            (getenv("SP_DRAWABLES") && atoi(getenv("SP_DRAWABLES")) == 2) ? 2 : 3;
#endif

        NSScreen *scr = NSScreen.screens.firstObject;
        CGFloat maxEDR = scr ? scr.maximumExtendedDynamicRangeColorComponentValue : 1.0;
        CGFloat potEDR = scr ? scr.maximumPotentialExtendedDynamicRangeColorComponentValue : 1.0;
#if !SP_APP_STORE
        const char *forceEDR = getenv("SP_FORCE_EDR");
        if (forceEDR) { maxEDR = spForcedEDRHeadroom(); potEDR = 10.0; }
        if (getenv("SP_NO_EDR")) potEDR = 1.0;
#endif
        _displayEdrCapable = (potEDR > 1.01);
        _displayCurrentEDR = maxEDR;
        _sdrBoostRequested = NO;
        _hdrShadowLiftEnabled = NO;
        _xdrHeadroomSmoothed = 0.0f;
        _xdrHeadroomAtUs = 0;

        _outputMode = 0;
        _displayPeakNits = 1000.0f;
        _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;

        _layerTagKey = kSPTag709;
        {

            const int64_t tCs0 = spDebug() ? spNowUs() : 0;
            _layer.colorspace = spSDRLayerColorSpace(_layerTagKey);
            if (tCs0) SPLOG(@"[Renderer] 初始层色彩空间（CoreMedia709）取得 %.2fms",
                            (spNowUs() - tCs0) / 1000.0);
        }
        if (spDebug()) {
            SPLOG(@"[Renderer] 显示器 EDR: current=%.2f potential=%.2f → %@",
                  maxEDR, potEDR, _displayEdrCapable ? @"有能力（HDR 内容时启用）" : @"无（一律 SDR tone map）");
        }

        _queue = [_device newCommandQueue];
        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_textureCache);

        dispatch_queue_attr_t submitAttr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _submitQueue = dispatch_queue_create(
            [NSString stringWithFormat:@"dev.khuaplayer.render-submit.c%u", logId].UTF8String,
            submitAttr);
        _primaries = 0; _transfer = 0; _range = 0; _bits = 8; _hasHdr = 0;
        _planar = 0;
        _specPipelineKey2 = UINT32_MAX;
        _sourceGamut = sp::kSPGamutBT709;
        _peakNits = 1000.0f;
        _viewportPixelSize = CGSizeMake(1920, 1080);
        _sampleAspect = 1.0f;
        _forcedAspect = 0.0f;
        _cropAspect = 0.0f;
        _aspectMode = 0; _rotation = 0; _mirror = 0;
        _brightness = 0; _contrast = 1; _saturation = 1; _gamma = 1; _hue = 0;
        _specPipelineKey = UINT32_MAX;
        _specBuilding.store(false);
        _specFailedKey.store(UINT32_MAX);
        _outputModeSwitchPending.store(false);
        _gpuTimeAccumNs.store(0);
        _gpuTimeFrames.store(0);

        int64_t tPso0 = 0;
        if (spDebug()) {
            tPso0 = spNowUs();
        }
        [self buildPipeline];
        if (tPso0) {
            SPLOG(@"[Launch] 渲染管线构建 %.1fms",
                  (spNowUs() - tPso0) / 1000.0);
        }
    }
    return self;
}

- (id<MTLDevice>)device { return _device; }

- (void)spSetDisplayEDRHeadroomLocked:(CGFloat)currentEDR {

    _displayCurrentEDR = currentEDR;
    if (_outputMode != 1) return;

    float peak = (float)(MAX(currentEDR, 1.0) * 100.0);
    if (fabsf(peak - _displayPeakNits) > 1.0f) {
        if (spDebug()) {
            SPLOG(@"[Renderer] EDR 余量变化: %.0f → %.0f nits (headroom %.2f)",
                  _displayPeakNits, peak, currentEDR);
        }
        _displayPeakNits = peak;
    }
}

- (void)setDisplayEDRHeadroom:(CGFloat)currentEDR {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    [self spSetDisplayEDRHeadroomLocked:currentEDR];
}

- (void)updateOutputModeWithMaxEDR:(CGFloat)currentEDR potentialEDR:(CGFloat)potentialEDR {
#if !SP_APP_STORE
    if (getenv("SP_FORCE_EDR")) { currentEDR = spForcedEDRHeadroom(); potentialEDR = 10.0; }
    if (getenv("SP_NO_EDR")) { potentialEDR = 1.0; }
#endif
    // Capability is based on potentialEDR, not the currently available headroom.
    // currentEDR can remain 1.0 until EDR content is presented; using it as the
    // gate would prevent the EDR path from ever activating.
    {

        std::lock_guard<std::mutex> lock(_cfgMtx);
        _displayEdrCapable = (potentialEDR > 1.01);
        _displayCurrentEDR = currentEDR;
    }
    [self applyOutputMode];
}

- (void)applyOutputMode {

    const int64_t queued = spDebug() && _logNextPresent.load(std::memory_order_relaxed) ? spNowUs() : 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        const int64_t entered = queued ? spNowUs() : 0;
        [self applyOutputModeOnMain];
        if (queued) SPLOG(@"[RendererTiming] mode queue_ms=%.3f apply_ms=%.3f",
                         (entered - queued) / 1000.0, (spNowUs() - entered) / 1000.0);
    });
}

// Opening-session publication barrier.  Stream color/SAR/DoVi setters publish
// their render fields synchronously under _cfgMtx; only CAMetalLayer mode
// changes must run on main.  When the output mode and generic PSO already
// match, waiting behind AppKit work is unnecessary.  Queued applyOutputMode
// blocks read the latest fields and do not restore an older configuration.
//
// Same-mode HDR only refreshes cached headroom/displayPeakNits under _cfgMtx;
// it does not query NSScreen or mutate the layer.  Mode changes and missing
// pipelines still require the main-thread layer/rebuild path below.
- (void)synchronizeOutputModeWithCompletion:(void (^)(BOOL ready))completion {
    const int64_t started = spDebug() ? spNowUs() : 0;
    BOOL readyInline = NO;
    __block BOOL delivered = NO; // deferred completion is consumed only on main
    void (^deferred)(BOOL) = nil;
    {
        std::lock_guard<std::mutex> cfgLock(_cfgMtx);
        const int desiredMode =
            spDesiredRendererOutputMode(_displayEdrCapable, _hasHdr, _sdrBoostRequested);

        readyInline = !spOutputConfigNeedsTransition(_displayEdrCapable, _hasHdr, _outputMode,
                                                     _sdrBoostRequested, _sourceGamut, _transfer,
                                                     _layerTagKey) &&
                      _pipeline != nil && (!_doviMappingEnabled || _doviPipeline != nil) &&
                      _textureCache != NULL;
        if (readyInline && desiredMode == 1) {
            [self spSetDisplayEDRHeadroomLocked:_displayCurrentEDR];
        }
        if (!readyInline && _doviMappingEnabled && completion) {
            // A setter's already-queued layer transaction can make us ready
            // before this barrier's own main block. Publish from that first
            // matching transaction, avoiding unrelated AppKit work in between.
            // Allocate waiters only for an actual DV open, never Bootstrap.
            deferred = [^(BOOL ready) {
                if (delivered) return;
                delivered = YES;
                if (started) SPLOG(@"[RendererTiming] barrier dovi_early=1 total_ms=%.3f ready=%d",
                                  (spNowUs() - started) / 1000.0, (int)ready);
                completion(ready);
            } copy];
            if (!_doviOutputWaiters) _doviOutputWaiters = [NSMutableArray new];
            [_doviOutputWaiters addObject:deferred];
        }
    }
    // Never invoke client code while holding the renderer configuration lock.
    if (readyInline) {
        if (started) SPLOG(@"[RendererTiming] barrier inline=1 total_ms=%.3f", (spNowUs() - started) / 1000.0);
        if (completion) completion(YES);
        return;
    }
    // Fallback block is FIFO-after the setters' queued apply blocks. Calling
    // the OnMain body once more is intentionally idempotent and makes this
    // completion independent of whether either preceding apply already ran.
    // DV's waiter may have already delivered from one of those transactions.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (deferred && delivered) return;
        const int64_t entered = started ? spNowUs() : 0;
        [self applyOutputModeOnMain];
        BOOL ready = NO;
        {
            std::lock_guard<std::mutex> cfgLock(self->_cfgMtx);
            ready = self->_pipeline != nil && (!self->_doviMappingEnabled || self->_doviPipeline != nil) &&
                    self->_textureCache != NULL;
            if (deferred) [self->_doviOutputWaiters removeObjectIdenticalTo:deferred];
        }
        if (started) SPLOG(@"[RendererTiming] barrier inline=0 queue_ms=%.3f apply_ms=%.3f ready=%d",
                          (entered - started) / 1000.0, (spNowUs() - entered) / 1000.0, (int)ready);
        if (deferred) deferred(ready);
        else if (completion) completion(ready);
    });
}

- (void)applyOutputModeOnMain {
    NSArray *readyWaiters = nil;
    {
        const int64_t beforeLock = spDebug() && _logNextPresent.load(std::memory_order_relaxed) ? spNowUs() : 0;
        std::lock_guard<std::mutex> cfgLock(_cfgMtx);
        if (beforeLock) SPLOG(@"[RendererTiming] mode_lock wait_ms=%.3f dovi=%d",
                             (spNowUs() - beforeLock) / 1000.0, (int)_doviMappingEnabled);
        [self applyOutputModeLocked];
        if (_doviOutputWaiters.count && _pipeline && (!_doviMappingEnabled || _doviPipeline) && _textureCache) {
            readyWaiters = [_doviOutputWaiters copy];
            [_doviOutputWaiters removeAllObjects];
        }
    }
    // Client code may re-enter the renderer; never call it under _cfgMtx.
    // Core binds each callback to its open generation before publishing ready.
    for (void (^waiter)(BOOL) in readyWaiters) waiter(YES);
}

// Requires _cfgMtx and main. Layer publication and its PSOs are one transaction.
- (void)applyOutputModeLocked {
    int mode = spDesiredRendererOutputMode(_displayEdrCapable, _hasHdr, _sdrBoostRequested);
    CGFloat currentEDR = _displayCurrentEDR;
    if (mode == _outputMode) {
        if (mode == 1) [self spSetDisplayEDRHeadroomLocked:currentEDR];
        if (mode == 0) {

            const int key = sp::spSDRLayerTagKey(_sourceGamut, _transfer, _hasHdr);
            if (key != _layerTagKey) {
                CGColorSpaceRef want = spSDRLayerColorSpace(key);
                _layer.colorspace = want;
                _layerTagKey = key;
                if (spDebug()) SPLOG(@"[Renderer] SDR 层标签 → %@ (gamut=%d trc=%d hdr=%d)", want ? spSDRLayerTagDescription(key) : @"(nil 直出)", _sourceGamut, _transfer, _hasHdr);
            }
        }
        // A previous pixel-format rebuild may have failed after invalidating
        // the old PSO.  Configuration synchronization is also the bounded
        // retry point; never report ready while the generic fallback is nil.
        if (!_pipeline || (_doviMappingEnabled && !_doviPipeline)) [self buildPipeline];
        return;
    }
    _outputMode = mode;

    _cfgGeneration.fetch_add(1, std::memory_order_relaxed);
    if (mode == 1) {
        _displayPeakNits = (float)(MAX(currentEDR, 1.0) * 100.0);

        _layer.pixelFormat = MTLPixelFormatRGBA16Float;
        _layer.wantsExtendedDynamicRangeContent = YES;
        CGColorSpaceRef p3 = CGColorSpaceCreateWithName(kCGColorSpaceExtendedDisplayP3);
        _layer.colorspace = p3;
        CGColorSpaceRelease(p3);
    } else {
        _displayPeakNits = 1000.0f;
        _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        _layer.wantsExtendedDynamicRangeContent = NO;
        _layerTagKey = sp::spSDRLayerTagKey(_sourceGamut, _transfer, _hasHdr);
        _layer.colorspace = spSDRLayerColorSpace(_layerTagKey);
    }
    if (spDebug()) {
        SPLOG(@"[Renderer] 输出路径 → %@ (内容HDR=%d EDR=%d 屏EDR能力=%d current=%.2f peak=%.0fnits)",
              mode == 1 ? (_hasHdr ? @"EDR 直通" : @"EDR 提亮") : @"SDR tone map",
              _hasHdr, (int)spEffectiveSdrBoost(_sdrBoostRequested, _hasHdr, _outputMode),
              (int)_displayEdrCapable, currentEDR, _displayPeakNits);
    }

    {
        std::lock_guard<std::mutex> specLock(_specMtx);
        _specPipelineKey = UINT32_MAX;
        _specPipeline = nil;
        _specPipelineKey2 = UINT32_MAX;
        _specPipeline2 = nil;
    }
    // A failed rebuild must not leave the previous pixel-format PSO looking
    // "ready".  Reusing a BGRA8 PSO after the layer moved to RGBA16F (or the
    // reverse) is a format mismatch, not a usable fallback.
    _pipeline = nil;
    _doviPipeline = nil;
    [self buildPipeline];
}

- (void)dealloc {
    if (_submitPendingBuf) {
        CVPixelBufferRelease(_submitPendingBuf);
        _submitPendingBuf = NULL;
    }
    if (_compareBuffer) {
        CVPixelBufferRelease(_compareBuffer);
        _compareBuffer = NULL;
    }
    [self releaseCompareConvertedLocked];
    if (_textureCache) {
        CVMetalTextureCacheFlush(_textureCache, 0);
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

- (BOOL)isReady { return _pipeline != nil; }

// The synchronous renderer fallback is available only in internal builds.
static bool spRenderInlineMode(void) {
#if SP_INTERNAL_BUILD && !SP_APP_STORE
    static const bool on = getenv("SP_RENDER_INLINE") != nullptr;
    return on;
#else
    return false;
#endif
}

- (void)clearToBlack {
    if (spRenderInlineMode()) { (void)[self clearToBlackInline]; return; }
    bool wakeNow = false;
    {
        std::lock_guard<std::mutex> lk(_submitMtx);
        if (_submitPendingBuf) {
            CVPixelBufferRelease(_submitPendingBuf);
            _submitPendingBuf = NULL;
        }
        _submitPendingSubTex = nil;
        _submitPendingClear = true;
        _submitPendingEpoch = _submitSessionEpoch.load(std::memory_order_relaxed);
        _submitPendingSpeculative = false;
        _submitRetryCount = 0;
        _submitParked = false;
        if (_submitDrainScheduled) {
            wakeNow = _submitRetryDelayed;
            _submitRetryDelayed = false;
        } else {
            _submitDrainScheduled = true;
            wakeNow = true;
        }
    }
    if (wakeNow) dispatch_async(_submitQueue, ^{ [self spDrainSubmits]; });
}

- (void)discardPendingSubmits {
    {
    std::lock_guard<std::mutex> lk(_submitMtx);

    _submitSessionEpoch.fetch_add(1, std::memory_order_relaxed);
    if (_submitPendingBuf) {
        CVPixelBufferRelease(_submitPendingBuf);
        _submitPendingBuf = NULL;
    }
    _submitPendingClear = false;
    _submitPendingSubTex = nil;
    _submitPendingSpeculative = false;
    _submitAcceptedInEpoch = 0;
    _submitParked = false;
    _submitRetryCount = 0;
    }

    if (_textureCache) CVMetalTextureCacheFlush(_textureCache, 0);
}

- (void)kickSubmitDrain {
    if (spRenderInlineMode()) return;
    bool schedule = false;
    {
        std::lock_guard<std::mutex> lk(_submitMtx);
        if ((_submitPendingBuf || _submitPendingClear) && !_submitDrainScheduled) {
            _submitRetryCount = 0;
            _submitParked = false;
            _submitDrainScheduled = true;
            schedule = true;
        }
    }
    if (schedule) dispatch_async(_submitQueue, ^{ [self spDrainSubmits]; });
}

- (uint64_t)committedFrameCount {
    return _committedFrames.load(std::memory_order_relaxed);
}

- (uint64_t)hardRenderFailureCount {
    return _hardRenderFailures.load(std::memory_order_relaxed);
}

- (BOOL)clearToBlackInline {
    return [self clearToBlackOutcomeWithEpoch:
                     _submitSessionEpoch.load(std::memory_order_relaxed)] ==
           SPSubmitOutcome::Committed;
}

- (SPSubmitOutcome)clearToBlackOutcomeWithEpoch:(uint64_t)taskEpoch {
    id<MTLCommandQueue> queue;
    CAMetalLayer *layer;
    {

        std::lock_guard<std::mutex> cfgLock(_cfgMtx);
        if (!_queue || !_layer) return SPSubmitOutcome::Transient;
        queue = _queue;
        layer = _layer;
        [self spReleaseDragFxTexturesLocked];
    }
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return SPSubmitOutcome::Transient;
    if (taskEpoch != _submitSessionEpoch.load(std::memory_order_relaxed)) {

        return SPSubmitOutcome::StaleEpoch;
    }
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = drawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLCommandBuffer> cmd = [queue commandBuffer];

    if (!cmd) return SPSubmitOutcome::Transient;
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
    if (!enc) return SPSubmitOutcome::Transient;
    [enc endEncoding];
    [cmd presentDrawable:drawable];
    [cmd commit];
    return SPSubmitOutcome::Committed;
}

- (NSString *)outputModeDescription {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    if (!_hasHdr) {
        if (spEffectiveSdrBoost(_sdrBoostRequested, _hasHdr, _outputMode)) {
            return [NSString stringWithFormat:NSLocalizedString(@"renderer.xdrBoostFmt", nil),
                    MAX(_displayCurrentEDR, 1.0)];
        }
        return @"SDR";
    }
    if (_outputMode == 1) {
        return [NSString stringWithFormat:NSLocalizedString(@"renderer.edrPassthroughFmt", nil),
                MAX(_displayCurrentEDR, 1.0)];
    }
    return NSLocalizedString(@"renderer.sdrToneMapped", nil);
}

- (id<MTLTexture>)subtitleTexture { return _subtitleTexture; }
- (void)setSubtitleTexture:(id<MTLTexture>)t {
    std::lock_guard<std::mutex> lock(_submitMtx);
    _subtitleTexture = t;
}

- (void)setCompareBuffer:(CVPixelBufferRef)buffer {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    if (_compareBuffer == buffer) return;
    if (buffer) CVPixelBufferRetain(buffer);
    if (_compareBuffer) CVPixelBufferRelease(_compareBuffer);
    _compareBuffer = buffer;
    if (!buffer) [self releaseCompareConvertedLocked];
}

- (void)releaseCompareConvertedLocked {
    if (_compareConverted) { CVPixelBufferRelease(_compareConverted); _compareConverted = NULL; }
    if (_compareConvertedSource) { CVPixelBufferRelease(_compareConvertedSource); _compareConvertedSource = NULL; }
}

- (void)setCompareSplitEnabled:(BOOL)enabled {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    _compareSplitEnabled = enabled;
}

- (CGRect)subtitleRect { return _subtitleRect; }
- (void)setSubtitleRect:(CGRect)r {

    std::lock_guard<std::mutex> lock(_submitMtx);
    _subtitleRect = r;
}

- (void)setAspectMode:(int)mode { std::lock_guard<std::mutex> lock(_cfgMtx); _aspectMode = mode; }
- (void)setForcedAspect:(float)ratio {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    _forcedAspect = (ratio > 0.1f && ratio < 10.0f) ? ratio : 0.0f;
}
- (void)setCropAspect:(float)ratio {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    _cropAspect = (ratio > 0.1f && ratio < 10.0f) ? ratio : 0.0f;
}
- (void)setRotation:(int)deg { std::lock_guard<std::mutex> lock(_cfgMtx); _rotation = ((deg % 360) + 360) % 360 / 90; }
- (void)setMirror:(int)m { std::lock_guard<std::mutex> lock(_cfgMtx); _mirror = m; }
// Geometry is media-session state: aspect correction, crop, rotation and mirror
// reset for each item. Process-scoped color-adjustment hooks are intentionally
// unaffected because they have no user-facing menu state.
- (void)resetPictureTransform {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    bool hadState = _forcedAspect > 0.0f || _cropAspect > 0.0f ||
                    _rotation != 0 || _mirror != 0;
    if (hadState && spDebug()) {
        SPLOG(@"[Renderer] 画面几何参数跨片清除: forced=%.3f crop=%.3f rot=%d mirror=%d → 默认",
              _forcedAspect, _cropAspect, _rotation * 90, _mirror);
    }
    _forcedAspect = 0.0f;
    _cropAspect = 0.0f;
    _rotation = 0;
    _mirror = 0;
}

- (void)setSDRBoostEnabled:(BOOL)enabled {
    {
        std::lock_guard<std::mutex> lock(_cfgMtx);
        if (_sdrBoostRequested == enabled) return;
        _sdrBoostRequested = enabled;
    }
    [self applyOutputMode];
}
- (BOOL)sdrBoostEnabled { std::lock_guard<std::mutex> lock(_cfgMtx); return _sdrBoostRequested; }
- (void)setHdrShadowLiftEnabled:(BOOL)enabled { std::lock_guard<std::mutex> lock(_cfgMtx); _hdrShadowLiftEnabled = enabled; }
- (BOOL)hdrShadowLiftEnabled { std::lock_guard<std::mutex> lock(_cfgMtx); return _hdrShadowLiftEnabled; }
- (BOOL)displayEdrCapable { std::lock_guard<std::mutex> lock(_cfgMtx); return _displayEdrCapable; }
- (CGFloat)displayEDRHeadroom { std::lock_guard<std::mutex> lock(_cfgMtx); return MAX(_displayCurrentEDR, 1.0); }
- (void)setBrightness:(float)v { std::lock_guard<std::mutex> lock(_cfgMtx); _brightness = v; }
- (void)setContrast:(float)v { std::lock_guard<std::mutex> lock(_cfgMtx); _contrast = v; }
- (void)setSaturation:(float)v { std::lock_guard<std::mutex> lock(_cfgMtx); _saturation = v; }
- (void)setGamma:(float)v { std::lock_guard<std::mutex> lock(_cfgMtx); _gamma = v; }
- (void)setHue:(float)v { std::lock_guard<std::mutex> lock(_cfgMtx); _hue = v; }

- (void)warmUpGPU {

    id<MTLRenderPipelineState> pipeline = nil;
    MTLPixelFormat fmt = MTLPixelFormatBGRA8Unorm;
    {
        std::lock_guard<std::mutex> lock(_cfgMtx);
        pipeline = _pipeline;
        if (_layer.pixelFormat != MTLPixelFormatInvalid) fmt = _layer.pixelFormat;
    }
    if (!_device || !pipeline) return;
    @autoreleasepool {
        id<MTLCommandQueue> q = [_device newCommandQueue];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                     width:8 height:8 mipmapped:NO];
        id<MTLTexture> target = [_device newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = target;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
        if (!cb || !enc) return;
        [enc setRenderPipelineState:pipeline];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
    }
}

- (id<MTLRenderPipelineState>)buildGenericPipelineDovi:(BOOL)dovi {
    const int64_t started = spDebug() ? spNowUs() : 0;
    NSError *error = nil;

    id<MTLLibrary> lib = spSharedShaderLibrary(_spLogId);
    if (!lib) return nil;
    _shaderLib = lib;

    const MTLPixelFormat fmt = _layer.pixelFormat;
    if (id<MTLRenderPipelineState> cached = spCachedPipeline(spGenericPipeKey(fmt, dovi))) {
        if (started) SPLOG(@"[RendererTiming] generic dovi=%d format=%lu cached=1 total_ms=%.3f main=%d",
                          (int)dovi, (unsigned long)fmt, (spNowUs() - started) / 1000.0, (int)NSThread.isMainThread);
        return cached;
    }
    // Keep color/range/layout dynamic but eliminate the opposite DV branch.
    // No DV PSO is compiled during ordinary-video Bootstrap or GPU prewarm.
    MTLFunctionConstantValues *emptyCv = [[MTLFunctionConstantValues alloc] init];
    int dv = dovi ? 1 : 0;
    [emptyCv setConstantValue:&dv type:MTLDataTypeInt atIndex:5];
    const int64_t functionStarted = started ? spNowUs() : 0;
    id<MTLFunction> vs = [lib newFunctionWithName:@"videoVertex" constantValues:emptyCv error:&error];
    id<MTLFunction> fs = [lib newFunctionWithName:@"videoFragment" constantValues:emptyCv error:&error];
    // Do not call newArgumentEncoderWithBufferIndex here: buffer(0) is not an
    // argument buffer, and the invalid query aborts through a Metal assertion.
    if (!vs || !fs) {
        SPLOG(@"[Renderer] 着色器入口缺失");
        return nil;
    }
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vs;
    desc.fragmentFunction = fs;
    desc.colorAttachments[0].pixelFormat = fmt;
    error = nil;
    const int64_t pipelineStarted = started ? spNowUs() : 0;
    id<MTLRenderPipelineState> pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (started) SPLOG(@"[RendererTiming] generic dovi=%d format=%lu cached=0 function_ms=%.3f pso_ms=%.3f total_ms=%.3f main=%d",
                      (int)dovi, (unsigned long)fmt, (pipelineStarted - functionStarted) / 1000.0,
                      (spNowUs() - pipelineStarted) / 1000.0, (spNowUs() - started) / 1000.0, (int)NSThread.isMainThread);
    if (!pipeline) {
        SPLOG(@"[Renderer] 管线创建失败: %@", error);
    } else {
        spStorePipeline(spGenericPipeKey(fmt, dovi), pipeline);
    }
    return pipeline;
}

- (void)buildPipeline {
    if (!_pipeline) _pipeline = [self buildGenericPipelineDovi:NO];
    if (_doviMappingEnabled && !_doviPipeline) _doviPipeline = [self buildGenericPipelineDovi:YES];
}

#pragma mark - Parameters

- (void)setColorimetryWithPrimaries:(int)primaries
                           transfer:(int)trc
                         colorspace:(int)colorspace
                              range:(int)range
                           peakNits:(float)peakNits {
    _logNextPresent.store(true);

    std::lock_guard<std::mutex> cfgLock(_cfgMtx);

    switch (colorspace) {
        case 9: case 10: _primaries = 1; break; // AVCOL_SPC_BT2020_NCL/CL
        case 5: case 6:  _primaries = 2; break; // AVCOL_SPC_BT470BG / SMPTE170M (601)
        case 7:  _primaries = 3; break;         // AVCOL_SPC_SMPTE240M
        case 1:  _primaries = 0; break;         // AVCOL_SPC_BT709
        default:
            switch (primaries) {
                case 9:  _primaries = 1; break;  // AVCOL_PRI_BT2020
                case 6:  _primaries = 2; break;  // AVCOL_PRI_SMPTE170M (601)
                case 5:  _primaries = 2; break;  // AVCOL_PRI_BT470BG (601)
                case 7:  _primaries = 3; break;  // AVCOL_PRI_SMPTE240M
                default: _primaries = 0; break;
            }
            break;
    }

    const sp::SPRendererTransfer streamTransfer = sp::spRendererTransferForAVTrc(trc);
    _transfer = streamTransfer.index;
    _hasHdr = streamTransfer.hdr ? 1 : 0;

    bool priDeclared = (primaries > 0 && primaries != 2 /*AVCOL_PRI_UNSPECIFIED*/);

    _sourceGamut = sp::spRendererSourceGamutForAV(primaries, colorspace);

    _streamDeclaredPrimaries = priDeclared;
    _streamDeclaredMatrix = (colorspace == 1 || colorspace == 5 || colorspace == 6 ||
                             colorspace == 7 || colorspace == 9 || colorspace == 10);

    _range = (range == 2) ? 1 : 0;
    _bits = 8;
    _peakNits = (peakNits > 0) ? peakNits : 1000.0f;
    [self applyOutputMode];
}

- (void)scheduleFrameOutputModeTransitionLocked {
    if (_outputModeSwitchPending.exchange(true, std::memory_order_acq_rel)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyOutputModeOnMain];
        self->_outputModeSwitchPending.store(false, std::memory_order_release);
        dispatch_async(self->_submitQueue, ^{ [self spDrainSubmits]; });
    });
}

- (BOOL)updateColorimetryFromFrame:(CVPixelBufferRef)buffer {

    const BOOL diagnostic = spDebug() && !_dbgAttachmentsDumped;
    CFStringRef trc = (CFStringRef)CVBufferGetAttachment(buffer, kCVImageBufferTransferFunctionKey, NULL);
    CFStringRef rawPri = (!_streamDeclaredPrimaries || diagnostic)
        ? (CFStringRef)CVBufferGetAttachment(buffer, kCVImageBufferColorPrimariesKey, NULL) : NULL;
    CFStringRef pri = _streamDeclaredPrimaries ? NULL : rawPri;

    CFStringRef rawMat = (!_streamDeclaredMatrix || diagnostic)
        ? (CFStringRef)CVBufferGetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, NULL) : NULL;
    CFStringRef mat = _streamDeclaredMatrix ? NULL : rawMat;

    if (spDebug()) {
        if (!_dbgAttachmentsDumped) {
            _dbgAttachmentsDumped = true;
            SPLOG(@"[Renderer] 帧附件: pri=%@ trc=%@ mat=%@",
                  rawPri ? (__bridge NSString *)rawPri : @"(无)",
                  trc ? (__bridge NSString *)trc : @"(无)",
                  rawMat ? (__bridge NSString *)rawMat : @"(无)");
        }
    }
    if (!trc && !pri && !mat) {
        BOOL needsModeRetry =
            spOutputConfigNeedsTransition(_displayEdrCapable, _hasHdr, _outputMode,
                                          _sdrBoostRequested, _sourceGamut, _transfer, _layerTagKey);
        if (needsModeRetry) [self scheduleFrameOutputModeTransitionLocked];
        return needsModeRetry;
    }

    BOOL changed = NO;
    if (trc) {

        const sp::SPRendererTransfer frameTransfer = sp::spRendererTransferForCVTrc(trc);
        const int newTrc = frameTransfer.index;
        const int newHdr = frameTransfer.hdr ? 1 : 0;
        if (_transfer != newTrc || _hasHdr != newHdr) {

            if (newHdr == 1 || (_transfer == 0 && _hasHdr == 0)) {
                _transfer = newTrc; _hasHdr = newHdr; changed = YES;
                if (spDebug()) SPLOG(@"[Renderer] 帧色彩: trc=%d hasHdr=%d (来自 VT attachment)", newTrc, newHdr);
            }
        }
    }
    if (mat) {
        int newPri = _primaries;
        if (CFEqual(mat, kCVImageBufferYCbCrMatrix_ITU_R_2020)) newPri = 1;
        else if (CFEqual(mat, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) newPri = 2;
        else if (CFEqual(mat, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995)) newPri = 3;
        else if (CFEqual(mat, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) newPri = 0;
        if (_primaries != newPri) { _primaries = newPri; changed = YES; }
    } else if (pri && !_streamDeclaredPrimaries && !_streamDeclaredMatrix) {
        int newPri = 0;
        if (CFEqual(pri, kCVImageBufferColorPrimaries_ITU_R_2020)) newPri = 1;
        else if (CFEqual(pri, kCVImageBufferColorPrimaries_SMPTE_C)) newPri = 2;
        else if (CFEqual(pri, kCVImageBufferColorPrimaries_EBU_3213)) newPri = 2;
        else if (CFEqual(pri, kCVImageBufferColorPrimaries_ITU_R_709_2)) newPri = 0;
        if (_primaries != newPri) { _primaries = newPri; changed = YES; }
    }

    if (pri && !_streamDeclaredPrimaries) {
        int ng = sp::spRendererSourceGamutForCV(pri);
        if (_sourceGamut != ng) { _sourceGamut = ng; changed = YES; }
    }

    BOOL needsModeRetry =
        spOutputConfigNeedsTransition(_displayEdrCapable, _hasHdr, _outputMode,
                                      _sdrBoostRequested, _sourceGamut, _transfer, _layerTagKey);
    if (needsModeRetry) {
        [self scheduleFrameOutputModeTransitionLocked];
    } else if (changed) {

        [self applyOutputMode];
    }
    return needsModeRetry;
}

- (void)setSampleAspect:(float)sar {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    _sampleAspect = (sar > 0.01f && sar < 100.0f) ? sar : 1.0f;
}

- (void)setStreamOrientationTurns:(int)turnsCCW mirrored:(BOOL)mirrored {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    _streamOrientation = sp::VideoOrientation{(uint8_t)(((turnsCCW % 4) + 4) % 4), mirrored != NO};
}

- (void)setDoviIPT:(BOOL)on {
    {

        std::lock_guard<std::mutex> lock(_cfgMtx);
        _doviIPT = on;
        if (on) {
            _doviMappingEnabled = YES;

            _hasHdr = 1;
            _transfer = 1;
            _primaries = 1;  // BT.2020
            _sourceGamut = sp::kSPGamutBT2020;
        }
    }
    [self applyOutputMode];
}

- (void)setDoviMappingEnabled:(BOOL)enabled {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    _doviMappingEnabled = enabled;
    _doviFrameMode = SPDoviFrameMode::Pending;
}

- (NSString *)doviProcessingDescription {
    std::lock_guard<std::mutex> lock(_cfgMtx);
    if (!_doviMappingEnabled) return nil;
    if (_doviFrameMode == SPDoviFrameMode::Pending ||
        _doviStatusEpoch != _submitSessionEpoch.load(std::memory_order_relaxed))
        return NSLocalizedString(@"dovi.status.pending", nil);
    switch (_doviFrameMode) {
        case SPDoviFrameMode::BaseLayer: return NSLocalizedString(@"dovi.status.base", nil);
        case SPDoviFrameMode::FixedIPT: return NSLocalizedString(@"dovi.status.fixed", nil);
        case SPDoviFrameMode::MissingEnhancement: return NSLocalizedString(@"dovi.status.missingEL", nil);
        default: break;
    }
    NSString *mapping = _doviFrameMode == SPDoviFrameMode::RpuWithEnhancement ? @"BL + EL + RPU" : @"BL + RPU";
    NSString *display = _doviHasLevel1 ? @"L1" : nil;
    switch (_doviSelection) {
        case sp::DoviDisplaySelection::L1: break;
        case sp::DoviDisplaySelection::L2: display = @"L1 + L2"; break;
        case sp::DoviDisplaySelection::CM4L3: display = @"CM4 (L1 + L3)"; break;
        case sp::DoviDisplaySelection::CM4L8: display = NSLocalizedString(@"dovi.status.cm4Basic", nil); break;
        case sp::DoviDisplaySelection::InvalidCM4: display = NSLocalizedString(@"dovi.status.invalidCM4", nil); break;
        case sp::DoviDisplaySelection::UnavailableTarget: display = NSLocalizedString(@"dovi.status.unavailableTarget", nil); break;
    }
    return display ? [NSString stringWithFormat:@"%@ · %@", mapping, display] : mapping;
}

- (void)setViewportPixelSize:(CGSize)size {
    if (size.width > 0 && size.height > 0) {
        std::lock_guard<std::mutex> lock(_cfgMtx);
        _viewportPixelSize = size;
        _layer.drawableSize = size;

        _cfgGeneration.fetch_add(1, std::memory_order_relaxed);
    }
}

#pragma mark - Window depth effect

- (void)setDragEffectStrength:(float)strength colorStrength:(float)colorStrength anchorPx:(CGPoint)anchor {
    bool becameIdle = false;
    {
        std::lock_guard<std::mutex> lock(_cfgMtx);

        const bool wasNonZero = _fxStrength > 0.0f || _fxColorStrength > 0.0f;
        _fxStrength = (strength > 0.0f && isfinite(strength)) ? MIN(strength, 1.0f) : 0.0f;
        _fxColorStrength = (colorStrength > 0.0f && isfinite(colorStrength)) ? MIN(colorStrength, 1.0f) : 0.0f;
        _fxAnchorPx = anchor;
        becameIdle = wasNonZero && _fxStrength == 0.0f && _fxColorStrength == 0.0f;
    }

    if (becameIdle) {
        __weak SPMetalRenderer *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPDragFxIdleReleaseUs * NSEC_PER_USEC) + 100 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            SPMetalRenderer *strongSelf = weakSelf;
            if (!strongSelf) return;
            std::lock_guard<std::mutex> lock(strongSelf->_cfgMtx);
            if (strongSelf->_fxStrength > 0.0f || strongSelf->_fxColorStrength > 0.0f) return;
            if (strongSelf->_fxLevels[0] && spNowUs() - strongSelf->_fxLastUseUs >= kSPDragFxIdleReleaseUs) {
                [strongSelf spReleaseDragFxTexturesLocked];
            }
        });
    }
}

- (void)prewarmDragEffectPipelines {
    MTLPixelFormat fmt;
    id<MTLLibrary> lib;
    id<MTLDevice> dev;
    {
        std::lock_guard<std::mutex> lock(_cfgMtx);
        fmt = _layer.pixelFormat;
        lib = _shaderLib;
        dev = _device;
    }
    if (!lib || !dev || fmt == MTLPixelFormatInvalid) return;
    if (spCachedPipeline(spDragFxPipeKey(0, fmt)) && spCachedPipeline(spDragFxPipeKey(1, fmt))) return;
    static std::mutex inflightMtx;
    static std::unordered_set<uint64_t> inflight;
    {
        std::lock_guard<std::mutex> lock(inflightMtx);
        if (!inflight.insert((uint64_t)fmt).second) return;
    }
    const unsigned logId = _spLogId;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int64_t t0 = spDebug() ? spNowUs() : 0;
        id<MTLFunction> vs = [lib newFunctionWithName:@"dragFxVertex"];
        id<MTLFunction> fsDown = [lib newFunctionWithName:@"dragFxDownsample"];
        id<MTLFunction> fsComp = [lib newFunctionWithName:@"dragFxComposite"];
        if (vs && fsDown && fsComp) {
            MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
            desc.vertexFunction = vs;
            desc.colorAttachments[0].pixelFormat = fmt;
            NSError *error = nil;
            if (!spCachedPipeline(spDragFxPipeKey(0, fmt))) {
                desc.fragmentFunction = fsDown;
                spStorePipeline(spDragFxPipeKey(0, fmt), [dev newRenderPipelineStateWithDescriptor:desc error:&error]);
            }
            if (!spCachedPipeline(spDragFxPipeKey(1, fmt))) {
                desc.fragmentFunction = fsComp;
                spStorePipeline(spDragFxPipeKey(1, fmt), [dev newRenderPipelineStateWithDescriptor:desc error:&error]);
            }
        }
        if (t0) NSLog(@"[c%u][DragFx] PSO 预热 %.2fms（格式 %lu）", logId, (spNowUs() - t0) / 1000.0, (unsigned long)fmt);
        std::lock_guard<std::mutex> lock(inflightMtx);
        inflight.erase((uint64_t)fmt);
    });
}

- (void)spReleaseDragFxTexturesLocked {
    if (!_fxLevels[0]) return;
    for (int i = 0; i < 7; i++) _fxLevels[i] = nil;
    _fxTexW = _fxTexH = 0;
    _fxTexFormat = MTLPixelFormatInvalid;
    if (spDebug()) SPLOG(@"[DragFx] 金字塔纹理已释放");
}

- (BOOL)spEnsureDragFxResourcesLockedForFormat:(MTLPixelFormat)fmt
                                          width:(NSUInteger)w
                                         height:(NSUInteger)h {
    if (w == 0 || h == 0 || !_shaderLib) return NO;
    if (!_fxDownPipe || !_fxCompPipe || _fxPipeFormat != fmt) {
        int64_t t0 = spDebug() ? spNowUs() : 0;
        id<MTLRenderPipelineState> down = spCachedPipeline(spDragFxPipeKey(0, fmt));
        id<MTLRenderPipelineState> comp = spCachedPipeline(spDragFxPipeKey(1, fmt));
        if (!down || !comp) {
            id<MTLFunction> vs = [_shaderLib newFunctionWithName:@"dragFxVertex"];
            id<MTLFunction> fsDown = [_shaderLib newFunctionWithName:@"dragFxDownsample"];
            id<MTLFunction> fsComp = [_shaderLib newFunctionWithName:@"dragFxComposite"];
            if (!vs || !fsDown || !fsComp) {
                if (!_fxFailLogged) { _fxFailLogged = true; SPLOG(@"[DragFx] shader 入口缺失"); }
                return NO;
            }
            NSError *error = nil;
            MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
            desc.vertexFunction = vs;
            desc.colorAttachments[0].pixelFormat = fmt;
            if (!down) {
                desc.fragmentFunction = fsDown;
                down = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
                if (down) spStorePipeline(spDragFxPipeKey(0, fmt), down);
            }
            if (!comp) {
                desc.fragmentFunction = fsComp;
                comp = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
                if (comp) spStorePipeline(spDragFxPipeKey(1, fmt), comp);
            }
            if (!down || !comp) {
                if (!_fxFailLogged) { _fxFailLogged = true; SPLOG(@"[DragFx] PSO 创建失败: %@", error); }
                return NO;
            }
        }
        _fxDownPipe = down;
        _fxCompPipe = comp;
        _fxPipeFormat = fmt;
        if (t0) SPLOG(@"[DragFx] PSO 就绪 %.2fms（格式 %lu）", (spNowUs() - t0) / 1000.0, (unsigned long)fmt);
    }
    if (!_fxLevels[0] || _fxTexFormat != fmt || _fxTexW != w || _fxTexH != h) {

        if (_fxAllocFailUs && spNowUs() - _fxAllocFailUs < 1000000) return NO;
        int64_t t0 = spDebug() ? spNowUs() : 0;
        [self spReleaseDragFxTexturesLocked];
        NSUInteger lw = w, lh = h;
        for (int i = 0; i <= kSPDragFxLevelCount; i++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:fmt width:lw height:lh mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            _fxLevels[i] = [_device newTextureWithDescriptor:td];
            if (!_fxLevels[i]) {
                _fxAllocFailUs = spNowUs();
                [self spReleaseDragFxTexturesLocked];
                if (!_fxFailLogged) { _fxFailLogged = true; SPLOG(@"[DragFx] 纹理创建失败 (%lux%lu)", (unsigned long)lw, (unsigned long)lh); }
                return NO;
            }
            lw = MAX((NSUInteger)1, (lw + 1) / 2);
            lh = MAX((NSUInteger)1, (lh + 1) / 2);
        }
        _fxAllocFailUs = 0;
        _fxTexFormat = fmt;
        _fxTexW = w;
        _fxTexH = h;
        if (t0) SPLOG(@"[DragFx] 金字塔纹理 %lux%lu ×%d 级 %.2fms", (unsigned long)w, (unsigned long)h, kSPDragFxLevelCount + 1, (spNowUs() - t0) / 1000.0);
    }
    return YES;
}

- (BOOL)spEncodeDragFxInto:(id<MTLCommandBuffer>)cmd
                  drawable:(id<MTLTexture>)target
                  strength:(float)strength
             colorStrength:(float)colorStrength
                    anchor:(CGPoint)anchor {

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    for (int i = 1; i <= kSPDragFxLevelCount; i++) {
        id<MTLTexture> src = _fxLevels[i - 1];
        rpd.colorAttachments[0].texture = _fxLevels[i];
        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
        if (!enc) return NO;
        simd_float2 texel = simd_make_float2(1.0f / (float)src.width, 1.0f / (float)src.height);
        [enc setRenderPipelineState:_fxDownPipe];
        [enc setFragmentTexture:src atIndex:0];
        [enc setFragmentBytes:&texel length:sizeof(texel) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }
    SPDragFxUniforms u;
    memset(u.values, 0, sizeof(u.values));
    u.values[0] = (float)target.width;
    u.values[1] = (float)target.height;
    u.values[2] = (float)anchor.x;
    u.values[3] = (float)anchor.y;
    u.values[4] = strength;
    u.values[5] = kSPDragFxNearLevel;
    u.values[6] = kSPDragFxFarLevel;
    u.values[7] = (float)kSPDragFxLevelCount;
    u.values[8] = 0.06f;
    u.values[9] = colorStrength;
    u.values[10] = 0.22f; // dim
    u.values[11] = 0.30f; // desat
    u.values[12] = 0.12f;
    u.values[13] = 0.05f;
    u.values[14] = 0.004f;
    u.values[15] = 1.0f;
    rpd.colorAttachments[0].texture = target;
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
    if (!enc) return NO;
    [enc setRenderPipelineState:_fxCompPipe];

    for (int i = 0; i < 7; i++) [enc setFragmentTexture:_fxLevels[MIN(i, kSPDragFxLevelCount)] atIndex:i];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];

    const float outputCeiling = target.pixelFormat == MTLPixelFormatRGBA16Float ? 65504.0f : 1.0f;
    [enc setFragmentBytes:&outputCeiling length:sizeof(outputCeiling) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    return YES;
}

#pragma mark - Content-specific pipelines

- (uint32_t)specKeyHdr:(bool)hdr dovi:(bool)dovi gamut:(int)gamut sdrInHdrLayer:(bool)sdrInHdrLayer {
    return (uint32_t)((_primaries & 0xF) | ((_transfer & 0xF) << 4) |
                      ((_bits == 10 ? 1 : 0) << 8) | ((_range & 1) << 9) |
                      ((hdr ? 1 : 0) << 10) | ((dovi ? 1 : 0) << 11) |
                      ((_outputMode & 1) << 12) | ((sdrInHdrLayer ? 1 : 0) << 13) |
                      ((_planar & 1) << 14) |
                      ((spEffectiveSdrBoost(_sdrBoostRequested, _hasHdr, _outputMode) ? 1u : 0u) << 15) |
                      ((gamut & 7) << 16));
}

- (uint32_t)currentSpecKey {
    return [self specKeyHdr:_hasHdr dovi:_doviIPT gamut:_sourceGamut sdrInHdrLayer:false];
}

- (void)publishSpecPipelineLocked:(id<MTLRenderPipelineState>)pipe key:(uint32_t)key {
    if (_specPipeline && _specPipelineKey != key) {
        _specPipeline2 = _specPipeline;
        _specPipelineKey2 = _specPipelineKey;
    }
    _specPipeline = pipe;
    _specPipelineKey = key;
}

- (void)buildSpecializedPipelineForKey:(uint32_t)key {
    bool expected = false;
    if (!_specBuilding.compare_exchange_strong(expected, true)) return;
    int prim = key & 0xF, trc = (key >> 4) & 0xF;
    int bits = ((key >> 8) & 1) ? 10 : 8;
    int range = (key >> 9) & 1, hdr = (key >> 10) & 1;
    int dovi = (key >> 11) & 1, outMode = (key >> 12) & 1;
    int gamut = (key >> 16) & 7, planar = (key >> 14) & 1;
    int sdrInHdrLayer = (key >> 13) & 1;
    int sdrBoost = (key >> 15) & 1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{

        if (id<MTLRenderPipelineState> cached = spCachedPipeline(spSpecPipeKey(key))) {
            std::lock_guard<std::mutex> lock(self->_specMtx);
            [self publishSpecPipelineLocked:cached key:key];
            self->_specBuilding.store(false);
            if (spDebug()) SPLOG(@"[Renderer] 特化管线缓存命中 key=0x%x", key);
            return;
        }
        const int64_t t0 = spNowUs(); // µs
        MTLFunctionConstantValues *cv = [[MTLFunctionConstantValues alloc] init];
        int v[11] = {prim, trc, bits, range, hdr, dovi, outMode, gamut, planar, sdrBoost, sdrInHdrLayer};
        for (int i = 0; i < 11; i++) {
            [cv setConstantValue:&v[i] type:MTLDataTypeInt atIndex:(NSUInteger)i];
        }
        NSError *err = nil;
        id<MTLFunction> fs = [self->_shaderLib newFunctionWithName:@"videoFragment"
                                                    constantValues:cv error:&err];
        id<MTLFunction> vs = fs ? [self->_shaderLib newFunctionWithName:@"videoVertex"] : nil;
        id<MTLRenderPipelineState> pipe = nil;
        if (fs && vs) {
            MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
            desc.vertexFunction = vs;
            desc.fragmentFunction = fs;

            desc.colorAttachments[0].pixelFormat =
                outMode ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
            pipe = [self->_device newRenderPipelineStateWithDescriptor:desc error:&err];
        }
        if (pipe) {
            spStorePipeline(spSpecPipeKey(key), pipe);
            std::lock_guard<std::mutex> lock(self->_specMtx);
            [self publishSpecPipelineLocked:pipe key:key];
            if (spDebug()) {
                SPLOG(@"[Renderer] 特化管线就绪 key=0x%x (%.1fms)", key,
                      (spNowUs() - t0) / 1e3);
            }
        } else {
            self->_specFailedKey.store(key);
            SPLOG(@"[Renderer] 特化管线编译失败 key=0x%x: %@", key, err);
        }
        self->_specBuilding.store(false);
    });
}

#pragma mark - Rendering

- (BOOL)renderPixelBuffer:(CVPixelBufferRef)buffer {
    return [self spAcceptSubmit:buffer speculative:NO];
}

- (BOOL)renderSpeculativeFirstFrame:(CVPixelBufferRef)buffer {
    return [self spAcceptSubmit:buffer speculative:YES];
}

- (BOOL)spAcceptSubmit:(CVPixelBufferRef)buffer speculative:(BOOL)speculative {
    if (spRenderInlineMode()) {
        return [self renderPixelBufferInline:buffer speculative:speculative];
    }

    if (!_pipeline || !_textureCache || !buffer) return NO;
    bool wakeNow = false;
    {
        std::lock_guard<std::mutex> lk(_submitMtx);

        if (speculative && _submitAcceptedInEpoch != 0) return NO;
        if (_submitPendingBuf) CVPixelBufferRelease(_submitPendingBuf);
        _submitPendingBuf = CVPixelBufferRetain(buffer);
        _submitPendingClear = false;
        _submitPendingEpoch = _submitSessionEpoch.load(std::memory_order_relaxed);
        _submitPendingSpeculative = speculative;
        _submitAcceptedInEpoch++;
        _submitRetryCount = 0;
        _submitParked = false;
        _submitPendingSubTex = _subtitleTexture;
        _submitPendingSubRect = _subtitleRect;
        if (_submitsSuspended.load(std::memory_order_relaxed)) {

            wakeNow = false;
        } else if (_submitDrainScheduled) {

            wakeNow = _submitRetryDelayed;
            _submitRetryDelayed = false;
        } else {
            _submitDrainScheduled = true;
            wakeNow = true;
        }
    }
    if (wakeNow) dispatch_async(_submitQueue, ^{ [self spDrainSubmits]; });
    return YES;
}

- (void)setSubmitsSuspended:(BOOL)suspended {
    _submitsSuspended.store(suspended, std::memory_order_relaxed);
}

- (void)spDrainSubmits {
    for (;;) @autoreleasepool {
        CVPixelBufferRef buf = NULL;
        bool clear = false;
        id<MTLTexture> subTex = nil;
        CGRect subRect = CGRectZero;
        bool speculative = false;
        uint64_t taskEpoch = 0;
        {
            std::lock_guard<std::mutex> lk(_submitMtx);
            _submitRetryDelayed = false;
            if (_submitParked) {
                _submitDrainScheduled = false;
                return;
            }

            if (_submitsSuspended.load(std::memory_order_relaxed) &&
                !_submitPendingClear) {
                _submitDrainScheduled = false;
                return;
            }
            buf = _submitPendingBuf;
            _submitPendingBuf = NULL;
            clear = _submitPendingClear;
            _submitPendingClear = false;
            subTex = _submitPendingSubTex;
            subRect = _submitPendingSubRect;
            taskEpoch = _submitPendingEpoch;
            speculative = _submitPendingSpeculative;
            if (!buf && !clear) {
                _submitDrainScheduled = false;
                return;
            }
        }
        SPSubmitOutcome outcome;
        if (clear && !buf) {
            outcome = [self clearToBlackOutcomeWithEpoch:taskEpoch];
        } else {
            outcome = [self renderPixelBufferOutcome:buf
                                        pairedSubTex:subTex
                                       pairedSubRect:subRect
                                           taskEpoch:taskEpoch
                                         speculative:speculative];
        }
        if (outcome != SPSubmitOutcome::Committed) {
            const bool waitsForOutputMode =
                outcome == SPSubmitOutcome::OutputModeSwitch;

            if (outcome == SPSubmitOutcome::StaleEpoch) {
                if (buf) CVPixelBufferRelease(buf);
                continue;
            }
            std::lock_guard<std::mutex> lk(_submitMtx);

            if (!_submitPendingBuf && !_submitPendingClear) {
                _submitPendingBuf = buf;
                _submitPendingClear = clear;
                _submitPendingSubTex = subTex;
                _submitPendingSubRect = subRect;
                _submitPendingEpoch = taskEpoch;
                _submitPendingSpeculative = speculative;
                if (waitsForOutputMode) {

                    return;
                }
                if (_submitRetryCount < 50) {
                    _submitRetryCount++;

                    if (outcome == SPSubmitOutcome::ConfigGenRace) {
                        dispatch_async(_submitQueue, ^{ [self spDrainSubmits]; });
                    } else {
                        _submitRetryDelayed = true;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                                       _submitQueue, ^{ [self spDrainSubmits]; });
                    }
                    return;
                }
                NSLog(@"[c%u][Renderer] 提交重试超限，滞留待唤醒（新帧/窗口恢复可见）",
                      _spLogId);
                _submitParked = true;
                _submitDrainScheduled = false;
                return;
            }

            if (buf) CVPixelBufferRelease(buf);
            if (waitsForOutputMode) {

                return;
            }
            continue;
        }
        if (buf) CVPixelBufferRelease(buf);
    }
}

- (BOOL)renderPixelBufferInline:(CVPixelBufferRef)buffer {
    return [self renderPixelBufferInline:buffer speculative:NO];
}

- (BOOL)renderPixelBufferInline:(CVPixelBufferRef)buffer
                    speculative:(BOOL)speculative {
    id<MTLTexture> liveSubTex;
    CGRect liveSubRect;
    {

        std::lock_guard<std::mutex> lk(_submitMtx);
        if (speculative && _submitAcceptedInEpoch != 0) return NO;
        _submitAcceptedInEpoch++;
        liveSubTex = _subtitleTexture;
        liveSubRect = _subtitleRect;
    }
    return [self renderPixelBufferOutcome:buffer
                             pairedSubTex:liveSubTex
                            pairedSubRect:liveSubRect
                                taskEpoch:_submitSessionEpoch.load(
                                              std::memory_order_relaxed)
                              speculative:speculative] ==
           SPSubmitOutcome::Committed;
}

// Encode the retained frame and its immutable DV attachments. Failure reasons
// distinguish stale epochs, output transitions, transient failures and commits.
- (SPSubmitOutcome)renderPixelBufferOutcome:(CVPixelBufferRef)buffer
                               pairedSubTex:(id<MTLTexture>)subTex
                              pairedSubRect:(CGRect)subRect
                                  taskEpoch:(uint64_t)taskEpoch
                                speculative:(BOOL)speculative {

    if (taskEpoch != _submitSessionEpoch.load(std::memory_order_relaxed)) {
        return SPSubmitOutcome::StaleEpoch;
    }

    std::unique_lock<std::mutex> cfgLock(_cfgMtx);
    if (!_pipeline || !_textureCache) {

        if (!_pipeline && _textureCache) {
            [self scheduleFrameOutputModeTransitionLocked];
        }
        return SPSubmitOutcome::Transient;
    }

    if (taskEpoch != _submitSessionEpoch.load(std::memory_order_relaxed)) {
        return SPSubmitOutcome::StaleEpoch;
    }

    // Stream configuration owns DV eligibility; a recycled attachment must not
    // promote an ordinary session or add attachment lookups to its frame path.
    const SPDoviUniforms *frameDovi = _doviMappingEnabled ? spDoviFrameUniforms(buffer) : nullptr;
    if (frameDovi && frameDovi->values[sp::dovi_gpu::Valid] < 0.5f) frameDovi = nullptr;
    const bool reconstructedDovi = frameDovi && spDoviFrameIsReconstructed(buffer);
    CVPixelBufferRef enhancement = frameDovi ? spDoviEnhancementFrame(buffer) : nullptr;
    const bool needsEnhancement = frameDovi && !reconstructedDovi &&
                                  frameDovi->values[sp::dovi_gpu::NeedsEnhancement] > .5f;
    bool missingEnhancement = needsEnhancement && !spDoviEnhancementBits(enhancement);
    if (missingEnhancement) frameDovi = nullptr;
    if ((frameDovi || _doviIPT) && !_doviPipeline) {
        [self scheduleFrameOutputModeTransitionLocked];
        return SPSubmitOutcome::OutputModeSwitch;
    }
    // Metadata can promote a P8.2 SDR-compatible stream to PQ presentation.
    // Do not replace the declared base-layer colorimetry: damaged frames still
    // need those original tags for their compatible fallback.
    if (frameDovi) {
        _hasHdr = 1;
        if (spOutputConfigNeedsTransition(_displayEdrCapable, _hasHdr, _outputMode,
                _sdrBoostRequested, _sourceGamut, _transfer, _layerTagKey)) {
            [self scheduleFrameOutputModeTransitionLocked];
            return SPSubmitOutcome::OutputModeSwitch;
        }
    }

    if (!_doviIPT && !frameDovi) {
        if ([self updateColorimetryFromFrame:buffer]) {

            return SPSubmitOutcome::OutputModeSwitch;
        }
    }

    OSType fmt = CVPixelBufferGetPixelFormatType(buffer);
    int planeCount = (int)CVPixelBufferGetPlaneCount(buffer);
    if (planeCount < 2) {
        SPLOG(@"[Renderer] 不支持的像素格式: %c%c%c%c", (char)(fmt>>24)&0xFF, (char)(fmt>>16)&0xFF, (char)(fmt>>8)&0xFF, (char)fmt&0xFF);
        _hardRenderFailures.fetch_add(1, std::memory_order_relaxed);
        return SPSubmitOutcome::Transient;
    }

    const BOOL planar = spPixelFormatIsPlanar3(fmt) && planeCount == 3;
    BOOL is10Bit = spPixelFormatIsTenBit(fmt);

    if (spDebug() && fmt != _dbgLoggedPixFmts[0] && fmt != _dbgLoggedPixFmts[1]) {
        _dbgLoggedPixFmts[1] = _dbgLoggedPixFmts[0];
        _dbgLoggedPixFmts[0] = fmt;
        SPLOG(@"[Renderer] 上屏像素格式: %c%c%c%c (%d bit, range=%s, %d 平面)",
              (char)((fmt>>24)&0xFF), (char)((fmt>>16)&0xFF),
              (char)((fmt>>8)&0xFF), (char)(fmt&0xFF),
              is10Bit ? 10 : 8,
              spPixelFormatIsFullRange(fmt) ? "full" : "video", planeCount);
    }
    _bits = is10Bit ? 10 : 8;
    _planar = planar ? 1 : 0;

    _range = spPixelFormatIsFullRange(fmt) ? 1 : 0;

    size_t w0 = CVPixelBufferGetWidthOfPlane(buffer, 0);
    size_t h0 = CVPixelBufferGetHeightOfPlane(buffer, 0);
    size_t w1 = CVPixelBufferGetWidthOfPlane(buffer, 1);
    size_t h1 = CVPixelBufferGetHeightOfPlane(buffer, 1);

    MTLPixelFormat yFmt  = is10Bit ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm;
    MTLPixelFormat uvFmt = planar ? yFmt
                                  : (is10Bit ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm);

    SPCVTexGuard texGuard;
    CVMetalTextureRef yRef = NULL, uvRef = NULL, vRef = NULL;
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache,
                                              buffer, NULL, yFmt, w0, h0, 0, &yRef);
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache,
                                              buffer, NULL, uvFmt, w1, h1, 1, &uvRef);
    if (planar) {
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache,
                                                  buffer, NULL, uvFmt, w1, h1, 2, &vRef);
    }
    texGuard.refs[0] = yRef;
    texGuard.refs[1] = uvRef;
    texGuard.refs[4] = vRef;
    texGuard.armed = true;
    if (!yRef || !uvRef || (planar && !vRef)) {
        _hardRenderFailures.fetch_add(1, std::memory_order_relaxed);
        return SPSubmitOutcome::Transient;
    }
    id<MTLTexture> yTex = CVMetalTextureGetTexture(yRef);
    id<MTLTexture> uvTex = CVMetalTextureGetTexture(uvRef);
    id<MTLTexture> vTex = vRef ? CVMetalTextureGetTexture(vRef) : nil;
    if (!yTex || !uvTex || (planar && !vTex)) {
        _hardRenderFailures.fetch_add(1, std::memory_order_relaxed);
        return SPSubmitOutcome::Transient;
    }

    id<MTLTexture> elYTex = nil, elUVTex = nil;
    if (frameDovi && needsEnhancement) {
        // A resource failure must not turn full FEL metadata into BL-only DV.
        if (spDoviCreateEnhancementTextures(_textureCache, enhancement, &texGuard.refs[6])) {
            elYTex = CVMetalTextureGetTexture(texGuard.refs[6]);
            elUVTex = CVMetalTextureGetTexture(texGuard.refs[7]);
        }
        if (!elYTex || !elUVTex) { frameDovi = nullptr; missingEnhancement = true; }
    }

    CVMetalTextureRef cmpYRef = NULL, cmpUVRef = NULL, cmpVRef = NULL;
    id<MTLTexture> cmpYTex = nil, cmpUVTex = nil, cmpVTex = nil;
    id<MTLTexture> cmpElYTex = nil, cmpElUVTex = nil;
    CVPixelBufferRef cmpEnhancement = nullptr;
    SPDoviUniforms compareDoviSnapshot;
    CVPixelBufferRef cmpSrc = _compareBuffer;
    if (cmpSrc && _compareSplitEnabled && !frameDovi) {
        const OSType cmpFmt = CVPixelBufferGetPixelFormatType(cmpSrc);
        if (cmpFmt != fmt && spPixelFormatIsPlanar3(cmpFmt) &&
            spPixelFormatBiPlanarEquivalent(cmpFmt) == fmt) {
            if (_compareConvertedSource != cmpSrc) {
                [self releaseCompareConvertedLocked];
                _compareConverted = spCreateBiPlanarCopy(cmpSrc);
                _compareConvertedSource = CVPixelBufferRetain(cmpSrc);
            }
            cmpSrc = _compareConverted;
        }
    }
    const OSType compareFormat = cmpSrc ? CVPixelBufferGetPixelFormatType(cmpSrc) : fmt;
    const bool comparePlanar = cmpSrc && spPixelFormatIsPlanar3(compareFormat) && CVPixelBufferGetPlaneCount(cmpSrc)==3;
    const bool compare10 = spPixelFormatIsTenBit(compareFormat);
    if (cmpSrc && _compareSplitEnabled &&
        (compareFormat == fmt || (frameDovi && spDoviFrameUniforms(_compareBuffer))) &&
        CVPixelBufferGetWidthOfPlane(cmpSrc, 0) == w0 &&
        CVPixelBufferGetHeightOfPlane(cmpSrc, 0) == h0) {
        const MTLPixelFormat cmpYFmt=compare10 ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm;
        const MTLPixelFormat cmpCFmt=comparePlanar ? cmpYFmt : compare10 ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm;
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache,
                                                  cmpSrc, NULL, cmpYFmt, w0, h0, 0, &cmpYRef);
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache,
                                                  cmpSrc, NULL, cmpCFmt, w1, h1, 1, &cmpUVRef);
        if (comparePlanar) {
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache,
                                                      cmpSrc, NULL, cmpCFmt, w1, h1, 2, &cmpVRef);
        }
        cmpYTex = cmpYRef ? CVMetalTextureGetTexture(cmpYRef) : nil;
        cmpUVTex = cmpUVRef ? CVMetalTextureGetTexture(cmpUVRef) : nil;
        cmpVTex = cmpVRef ? CVMetalTextureGetTexture(cmpVRef) : nil;
        if (!cmpYTex || !cmpUVTex || (comparePlanar && !cmpVTex)) {
            if (cmpYRef) { CFRelease(cmpYRef); cmpYRef = NULL; }
            if (cmpUVRef) { CFRelease(cmpUVRef); cmpUVRef = NULL; }
            if (cmpVRef) { CFRelease(cmpVRef); cmpVRef = NULL; }
            cmpYTex = nil;
            cmpUVTex = nil;
            cmpVTex = nil;
        }
    }
    texGuard.refs[2] = cmpYRef;
    texGuard.refs[3] = cmpUVRef;
    texGuard.refs[5] = cmpVRef;
    if (cmpYTex && frameDovi) {
        const auto *cmpDovi = spDoviFrameUniforms(_compareBuffer);
        // FRC pairs require identical descriptions. Reject stale comparison
        // frames rather than display their pixels through another frame's RPU.
        const bool cmpReconstructed = spDoviFrameIsReconstructed(_compareBuffer);
        if (!cmpDovi || memcmp(cmpDovi,frameDovi,sizeof(*frameDovi))) cmpYTex = nil;
        else if (cmpDovi->values[sp::dovi_gpu::NeedsEnhancement] > .5f && !cmpReconstructed) {
            cmpEnhancement = spDoviEnhancementFrame(_compareBuffer);
            if (spDoviCreateEnhancementTextures(_textureCache, cmpEnhancement, &texGuard.refs[8])) {
                cmpElYTex = CVMetalTextureGetTexture(texGuard.refs[8]);
                cmpElUVTex = CVMetalTextureGetTexture(texGuard.refs[9]);
            }
            if (!cmpElYTex || !cmpElUVTex) cmpYTex = nil;
        }
        if (cmpYTex)
            spDoviPrepareDrawSnapshot(compareDoviSnapshot, *cmpDovi, cmpSrc, cmpEnhancement, cmpReconstructed);
    }

    const uint64_t cfgGenAtDrawable = _cfgGeneration.load(std::memory_order_relaxed);
    cfgLock.unlock();
    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    if (!drawable) {
        return SPSubmitOutcome::Transient;
    }
    cfgLock.lock();
    if (taskEpoch != _submitSessionEpoch.load(std::memory_order_relaxed)) {

        return SPSubmitOutcome::StaleEpoch;
    }
    if (_cfgGeneration.load(std::memory_order_relaxed) != cfgGenAtDrawable) {

        return SPSubmitOutcome::ConfigGenRace;
    }

    const float fxStrength = _fxStrength;
    const float fxColorStrength = _fxColorStrength;
    const CGPoint fxAnchor = _fxAnchorPx;
    BOOL fxActive = NO;
    if (MAX(fxStrength, fxColorStrength) > 0.001f) {
        fxActive = [self spEnsureDragFxResourcesLockedForFormat:drawable.texture.pixelFormat
                                                          width:drawable.texture.width
                                                         height:drawable.texture.height];
        if (fxActive) _fxLastUseUs = spNowUs();
    } else if (_fxLevels[0] && spNowUs() - _fxLastUseUs > kSPDragFxIdleReleaseUs) {
        [self spReleaseDragFxTexturesLocked];
    }

    SPColorUniforms uniforms;
    memset(uniforms.uvals, 0, sizeof(uniforms.uvals));
    uniforms.uvals[0] = (float)CVPixelBufferGetWidth(buffer);   // vidW
    uniforms.uvals[1] = (float)CVPixelBufferGetHeight(buffer);  // vidH
    uniforms.uvals[2] = (float)_viewportPixelSize.width;        // vpW
    uniforms.uvals[3] = (float)_viewportPixelSize.height;       // vpH
    uniforms.uvals[4] = _primaries;
    uniforms.uvals[5] = _transfer;
    uniforms.uvals[6] = _range;
    uniforms.uvals[7] = _bits;
    uniforms.uvals[8] = frameDovi || _doviIPT || _transfer == 1 || _transfer == 2;
    uniforms.uvals[9] = _peakNits;
    uniforms.uvals[10] = _sampleAspect;

    {
        SPAspectModel am27 = spOrientedAspectModel(uniforms.uvals[0], uniforms.uvals[1],
                                                   _sampleAspect, _forcedAspect, _cropAspect,
                                                   _streamOrientation);
        uniforms.uvals[27] = am27.eff;
        uniforms.uvals[28] = am27.cw;
        uniforms.uvals[29] = am27.ch;
    }
    uniforms.uvals[11] = (frameDovi || _doviIPT) ? 1 : 0;
    uniforms.uvals[12] = (float)subRect.origin.x;
    uniforms.uvals[13] = (float)subRect.origin.y;
    uniforms.uvals[14] = (float)subRect.size.width;
    uniforms.uvals[15] = (float)subRect.size.height;
    uniforms.uvals[16] = subTex ? 1 : 0;
    uniforms.uvals[17] = _aspectMode;
    {
        // Manual rotation/mirror act on the upright picture: compose them after
        // the container orientation into the single rotate-then-mirror pair the
        // vertex shader implements.
        const sp::VideoOrientation shown = sp::composeVideoOrientation(
            sp::videoOrientationFromUserControls(_rotation, _mirror), _streamOrientation);
        uniforms.uvals[18] = shown.turnsCCW;
        uniforms.uvals[19] = shown.hflip ? 1 : 0;
    }
    uniforms.uvals[20] = _brightness;
    uniforms.uvals[21] = _contrast;
    uniforms.uvals[22] = _saturation;
    uniforms.uvals[23] = _gamma;
    uniforms.uvals[32] = _hue;
    uniforms.uvals[33] = _hdrShadowLiftEnabled ? 1.0f : 0.0f;
    uniforms.uvals[24] = _displayPeakNits;
    uniforms.uvals[25] = _outputMode;
    uniforms.uvals[26] = frameDovi ? sp::kSPGamutBT2020 : _sourceGamut;
    uniforms.uvals[30] = _planar;
    if (spEffectiveSdrBoost(_sdrBoostRequested, _hasHdr, _outputMode)) {

        const float target = (float)MAX(_displayCurrentEDR * 0.85, 1.0);
        const int64_t nowUs = spNowUs();
        if (_xdrHeadroomSmoothed <= 0.0f || _xdrHeadroomAtUs == 0 || target <= _xdrHeadroomSmoothed) {
            _xdrHeadroomSmoothed = target;
        } else {
            const float dt = (float)MAX(nowUs - _xdrHeadroomAtUs, (int64_t)0) / 1e6f;
            const float a = 1.0f - expf(-dt / 0.3f);
            _xdrHeadroomSmoothed += (target - _xdrHeadroomSmoothed) * a;
            if (fabsf(target - _xdrHeadroomSmoothed) < 0.005f) _xdrHeadroomSmoothed = target;
        }
        _xdrHeadroomAtUs = nowUs;
        uniforms.uvals[31] = _xdrHeadroomSmoothed;
    } else {
        uniforms.uvals[31] = 0.0f;
        _xdrHeadroomSmoothed = 0.0f;
        _xdrHeadroomAtUs = 0;
    }

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    if (!cmd) {

        return SPSubmitOutcome::Transient;
    }
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];

    rpd.colorAttachments[0].texture = fxActive ? _fxLevels[0] : drawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

    // Frame-local RPU survives reorder, retry, redraw and seek cancellation.
    SPDoviUniforms doviSnapshot;
    const SPDoviUniforms *doviData = NULL;
    sp::DoviDisplaySelection displaySelection = sp::DoviDisplaySelection::L1;
    if (frameDovi) {
        spDoviPrepareDrawSnapshot(doviSnapshot, *frameDovi, buffer, enhancement, reconstructedDovi);
        // SDR output is normalized to the 100-nit reference display; 203 nits
        // in toneMap is the HDR input reference-white convention (BT.2408).
        const float targetNits = _outputMode == 1 ? uniforms.uvals[24] : 100.f;
        const auto targetGamut = _outputMode == 1 ? sp::DoviDisplayGamut::P3D65 : sp::DoviDisplayGamut::BT709;
        displaySelection = sp::doviPrepareDisplay(doviSnapshot.values, targetNits, targetGamut, w0, h0);
        doviData = &doviSnapshot;
        if (cmpYTex)
            sp::doviPrepareDisplay(compareDoviSnapshot.values, targetNits, targetGamut, w0, h0);
    } else if (_doviIPT) {
        // P5 has no compatible base. Missing RPU uses the fixed fallback
        // transform, never another frame's metadata.
        static const SPDoviUniforms fallback = [] {
            SPDoviUniforms u;
            sp::doviToGpuFloats(sp::DoviReshape{}, u.values);
            return u;
        }();
        doviData = &fallback;
    } else if (_hasHdr && !uniforms.uvals[8]) {
        // P8.2 damaged-RPU fallback after the layer has entered the HDR path.
        // That layer is P3/extended-sRGB or tone-mapped sRGB, not source 709.
        static const SPDoviUniforms fallback = [] {
            SPDoviUniforms u{}; u.values[sp::dovi_gpu::SdrInHdrLayer] = 1; return u;
        }();
        doviData = &fallback;
    }

    id<MTLRenderPipelineState> fallbackPipeline = uniforms.uvals[11] ? _doviPipeline : _pipeline;
    id<MTLRenderPipelineState> activePipeline = fallbackPipeline;
#if SP_APP_STORE
    static const bool noSpec = false;
#else
    static const bool noSpec = getenv("SP_NO_SPEC") != nullptr;
#endif
    if (!noSpec) {
        // Specialize the effective frame path, including a P8.2 SDR fallback
        // while the session's layer remains EDR. Curves stay dynamic uniforms.
        const bool frameHdr = uniforms.uvals[8] != 0;
        const uint32_t key = [self specKeyHdr:frameHdr dovi:uniforms.uvals[11] != 0
                                        gamut:(int)uniforms.uvals[26]
                                sdrInHdrLayer:_hasHdr && !frameHdr];
        {
            std::lock_guard<std::mutex> lock(_specMtx);
            if (_specPipeline && _specPipelineKey == key) activePipeline = _specPipeline;
            else if (_specPipeline2 && _specPipelineKey2 == key) activePipeline = _specPipeline2;
        }
        if (activePipeline == fallbackPipeline && _specFailedKey.load() != key) {
            [self buildSpecializedPipelineForKey:key];
        }
    }

    {
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
    if (!enc) {

        return SPSubmitOutcome::Transient;
    }
    [enc setRenderPipelineState:activePipeline];
    [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    spBindDovi(enc, doviData, _doviZeroBuf);
    [enc setFragmentTexture:subTex atIndex:2];

    [enc setFragmentTexture:(vTex ?: uvTex) atIndex:3];
    [enc setFragmentTexture:(elYTex ?: yTex) atIndex:4];
    [enc setFragmentTexture:(elUVTex ?: uvTex) atIndex:5];
    if (cmpYTex && _compareSplitEnabled) {

        NSUInteger dw = drawable.texture.width, dh = drawable.texture.height;
        NSUInteger midX = dw / 2;
        [enc setScissorRect:(MTLScissorRect){0, 0, midX, dh}];
        [enc setFragmentTexture:cmpYTex atIndex:0];
        [enc setFragmentTexture:cmpUVTex atIndex:1];
        if (cmpVTex) [enc setFragmentTexture:cmpVTex atIndex:3];
        if (frameDovi) {
            // DV source and reconstructed synthetic output can differ in bit
            // depth, range and plane layout (P9 NV12 or P10 planar -> P010).
            // The already-built generic DV pipeline reads this draw's layout.
            SPColorUniforms compareUniforms=uniforms;
            compareUniforms.uvals[6]=spPixelFormatIsFullRange(compareFormat);
            compareUniforms.uvals[7]=compare10 ? 10 : 8;
            compareUniforms.uvals[30]=comparePlanar;
            [enc setRenderPipelineState:_doviPipeline];
            [enc setFragmentBytes:&compareUniforms length:sizeof(compareUniforms) atIndex:0];
            spBindDovi(enc,&compareDoviSnapshot,_doviZeroBuf);
            [enc setFragmentTexture:cmpElYTex ?: cmpYTex atIndex:4];
            [enc setFragmentTexture:cmpElUVTex ?: cmpUVTex atIndex:5];
        }
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc setScissorRect:(MTLScissorRect){midX, 0, dw - midX, dh}];
        [enc setFragmentTexture:yTex atIndex:0];
        [enc setFragmentTexture:uvTex atIndex:1];
        if (vTex) [enc setFragmentTexture:vTex atIndex:3];
        if (frameDovi) {
            [enc setRenderPipelineState:activePipeline];
            [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            spBindDovi(enc,doviData,_doviZeroBuf);
            [enc setFragmentTexture:elYTex ?: yTex atIndex:4];
            [enc setFragmentTexture:elUVTex ?: uvTex atIndex:5];
        }
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        if (spDebug()) {
            if (_dbgSplitDraws++ < 3) SPLOG(@"[Renderer] 分屏对比 draw（左=compare 右=当前）");
        }
    } else {
        [enc setFragmentTexture:yTex atIndex:0];
        [enc setFragmentTexture:uvTex atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [enc endEncoding];
    }
    if (fxActive) {

        if (![self spEncodeDragFxInto:cmd drawable:drawable.texture
                             strength:fxStrength colorStrength:fxColorStrength anchor:fxAnchor]) {
            return SPSubmitOutcome::Transient;
        }
    }

#if !SP_APP_STORE
    static const bool vstatsOn = getenv("SP_VSTATS") != nullptr;
    if (vstatsOn) {
        __weak SPMetalRenderer *wself = self;
        [drawable addPresentedHandler:^(id<MTLDrawable> d) {
            SPMetalRenderer *sself = wself;
            if (!sself) return;
            double t = d.presentedTime;
            if (t <= 0) {
                std::lock_guard<std::mutex> lk(sself->_vstatsMtx);
                int z = ++sself->_vstatsZero;

                if (z <= 4 || z % 240 == 0)
                    NSLog(@"[c%u][VStats] presentedTime=0 已累计 %d 次", sself->_spLogId, z);
                return;
            }
            std::lock_guard<std::mutex> lk(sself->_vstatsMtx);
            double prev = sself->_vstatsPrevPresented;
            sself->_vstatsPrevPresented = t;
            if (prev > 0 && t > prev) {
                if (t - prev < 1.0) {
                    sself->_vstatsDeltas.push_back(t - prev);
                } else {

                    int g = ++sself->_vstatsLongGaps;
                    NSLog(@"[c%u][VStats] 跨秒间隔 %.2fs 已累计 %d 次（暂停/seek 或冻结）",
                          sself->_spLogId, t - prev, g);
                }
            }
            if (sself->_vstatsDeltas.size() >= 240) {
                double sum = 0, mx = 0;
                for (double v : sself->_vstatsDeltas) { sum += v; if (v > mx) mx = v; }
                double mean = sum / sself->_vstatsDeltas.size();
                double var = 0; int judder = 0;
                for (double v : sself->_vstatsDeltas) {
                    var += (v - mean) * (v - mean);
                    if (fabs(v - mean) > mean * 0.25) judder++;
                }
                NSLog(@"[c%u][VStats] n=%zu 上屏间隔 均值=%.2fms σ=%.2fms 最大=%.1fms 抖动=%d (%.1f%%)",
                      sself->_spLogId, sself->_vstatsDeltas.size(), mean * 1e3,
                      sqrt(var / sself->_vstatsDeltas.size()) * 1e3, mx * 1e3,
                      judder, 100.0 * judder / sself->_vstatsDeltas.size());
                sself->_vstatsDeltas.clear();
            }
        }];
    }
#endif
    if (spDebug() && _logNextPresent.exchange(false)) {
        int64_t tCommit = spNowUs();
        const unsigned logId = _spLogId;
        [drawable addPresentedHandler:^(id<MTLDrawable> d) {

            NSLog(@"[c%u][Renderer] 首帧真实上屏 presented（commit 后 %.1fms）",
                  logId, (spNowUs() - tCommit) / 1000.0);
        }];
    }
#if !SP_APP_STORE

    id<MTLTexture> dumpTex = nil;
    NSString *dumpPath = nil;
    if (_dumpPending.load()) {
        _dumpPending.store(false);
        dumpPath = _dumpPath;
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:drawable.texture.pixelFormat
                                         width:drawable.texture.width
                                        height:drawable.texture.height
                                     mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        dumpTex = [_device newTextureWithDescriptor:td];
        if (dumpTex) {
            id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
            if (!blit) {

                SPLOG(@"[Renderer] 金图 blit encoder 创建失败，本帧不 dump");
                dumpTex = nil;
            } else {
            [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(drawable.texture.width, drawable.texture.height, 1)
                        toTexture:dumpTex destinationSlice:0 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
            }
        }
    }
#endif
    [cmd presentDrawable:drawable];

    CVMetalTextureRef elYRef = texGuard.refs[6], elUVRef = texGuard.refs[7];
    CVMetalTextureRef cmpElYRef = texGuard.refs[8], cmpElUVRef = texGuard.refs[9];
    texGuard.armed = false;
    BOOL usedSpec = (activePipeline != fallbackPipeline);
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        CFRelease(yRef);
        CFRelease(uvRef);
        if (vRef) CFRelease(vRef);
        if (cmpYRef) CFRelease(cmpYRef);
        if (cmpUVRef) CFRelease(cmpUVRef);
        if (cmpVRef) CFRelease(cmpVRef);
        if (elYRef) CFRelease(elYRef);
        if (elUVRef) CFRelease(elUVRef);
        if (cmpElYRef) CFRelease(cmpElYRef);
        if (cmpElUVRef) CFRelease(cmpElUVRef);
        if (spDebug()) {

            int64_t ns = (int64_t)((cb.GPUEndTime - cb.GPUStartTime) * 1e9);
            if (ns > 0) {
                int64_t acc = self->_gpuTimeAccumNs.fetch_add(ns) + ns;
                int n = self->_gpuTimeFrames.fetch_add(1) + 1;
                if (n >= 120) {
                    self->_gpuTimeAccumNs.store(0);
                    self->_gpuTimeFrames.store(0);
                    SPLOG(@"[Renderer] GPU 帧时间均值=%.3fms (%d帧, 管线=%@)",
                          acc / 1e6 / n, n, usedSpec ? @"特化" : @"泛型");
                }
            }
        }
    }];
    [cmd commit];

    if (!speculative &&
        taskEpoch == _submitSessionEpoch.load(std::memory_order_relaxed)) {
        _committedFrames.fetch_add(1, std::memory_order_relaxed);
        if (_doviMappingEnabled) {
            _doviStatusEpoch = taskEpoch;
            _doviSelection = displaySelection;
            _doviHasLevel1 = frameDovi && frameDovi->values[sp::dovi_gpu::HasLevel1] > .5f;
            _doviFrameMode = frameDovi
                ? (frameDovi->values[sp::dovi_gpu::NeedsEnhancement] > .5f ? SPDoviFrameMode::RpuWithEnhancement
                                                                           : SPDoviFrameMode::Rpu)
                : _doviIPT ? SPDoviFrameMode::FixedIPT
                : (missingEnhancement ||
                   CVBufferGetAttachment(buffer, kSPDoviMissingEnhancement, nullptr) == kCFBooleanTrue)
                    ? SPDoviFrameMode::MissingEnhancement : SPDoviFrameMode::BaseLayer;
        }
    }

    cfgLock.unlock();
#if !SP_APP_STORE
    if (dumpTex && dumpPath) {
        [cmd waitUntilCompleted];
        spWriteRenderDump(dumpTex, dumpPath, _spLogId);
    }
#endif
    return SPSubmitOutcome::Committed;
}

- (void)requestRenderDumpToPath:(NSString *)path {
#if !SP_APP_STORE
    _dumpPath = [path copy];
    _dumpPending.store(true);
#endif
}

@end
