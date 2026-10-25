#import "SPTimelineThumbnailer.h"
#import "SPVideoDecoder.h"
#import "SPFFmpegDecoder.h"
#import "SPDoviDecoder.h"
#import "SPDoviFrame.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include "ShaderSource.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

#include <cstring>
#include <pthread.h>
#include <sys/resource.h>

extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
}

#include "SPThumbSchedulingPolicy.hpp"
#include "SPThumbKeyPolicy.hpp"
#include "SPThumbBlackBorder.hpp"
#include "TsRapScan.hpp"
#include "SPDoviRPU.hpp"
#include "SPVideoOrientation.hpp"
#include "SPPersistentThumbnailStore.hpp"
#include "../Core/HTTPRangeIO.hpp"
#include "../Core/SPDoviConfig.hpp"
#include "../Core/SPDoviPacketJoiner.hpp"
#include "../Core/SPDoviStreamAssociation.hpp"

using spthumb::SPThumbClaim;
using spthumb::SPThumbHoldVerdict;
using spthumb::SPThumbOpenResult;
using spthumb::SPThumbTaskKind;
using spthumb::kImmuneBase;

#include "SPRuntimeGates.hpp"

#define SPLOG(fmt, ...) NSLog(@"[c%u]" fmt, self->_spLogId, ##__VA_ARGS__)

struct SPThumbShared {
    unsigned logId = 0;

    AVCodecParameters *videoPar = nullptr;
    int videoStreamIndex = -1;
    int videoStreamId = 0;
    bool doviIPT = false;
    ~SPThumbShared() { if (videoPar) avcodec_parameters_free(&videoPar); }
    std::mutex mtx;
    std::condition_variable cv;
    std::atomic<bool> stop{false};

    std::atomic<uint64_t> yieldSeq{0};
    std::atomic<int64_t> lastYieldWallUs{0};

    std::atomic<bool> everInteracted{false};

    int64_t hoverTargetUs = -1;

    int64_t activeHoverTargetUs = INT64_MIN;

    uint64_t activeHoverBase = 0;
    std::atomic<uint64_t> hoverSeq{0};

    std::atomic<uint64_t> cancelSeq{0};
    bool sweepArmed = false;

    std::atomic<uint64_t> cbYieldBase{0};
    std::atomic<uint64_t> cbHoverBase{0};
    std::atomic<uint64_t> cbCancelBase{kImmuneBase};
    std::string path;
    int64_t durationUs = 0;
    int64_t originUs = 0;
    bool remote = false;
    bool http = false;
    std::string persistentDirectory;
    int64_t persistentIntervalUs = 0;
    std::atomic<bool> persistentSweepFinished{false};
    std::atomic<bool> persistentHoverPending{false};
    std::atomic<unsigned> pendingPublications{0};

    int colorPrimaries = 2, colorTrc = 2, colorSpace = 2, colorRange = 0;

    std::vector<int64_t> evictedKeys;
};

static int spThumbInterruptCb(void *opaque) {
    auto *s = (SPThumbShared *)opaque;
    return spthumb::taskInterrupted(s->stop.load(),
                                    s->http ? s->cbYieldBase.load() : s->yieldSeq.load(), s->cbYieldBase.load(),
                                    s->hoverSeq.load(), s->cbHoverBase.load(),
                                    s->cancelSeq.load(), s->cbCancelBase.load())
               ? 1 : 0;
}

static void spThumbFitSize(int w, int h, AVRational sar, int *ow, int *oh,
                           sp::VideoOrientation orient = {}, double maxWidth = 384.0) {
    double dw = w > 0 ? w : 2, dh = h > 0 ? h : 2;
    if (sar.num > 0 && sar.den > 0) dw = dw * sar.num / sar.den;
    const double maxHeight = maxWidth * 9.0 / 16.0;
    const double boxW = orient.swapsAxes() ? maxHeight : maxWidth;
    const double boxH = orient.swapsAxes() ? maxWidth : maxHeight;
    double s = std::min(boxW / dw, boxH / dh);
    if (s > 1.0) s = 1.0;
    *ow = std::max((int)llround(dw * s) & ~1, 2);
    *oh = std::max((int)llround(dh * s) & ~1, 2);
}

static NSData *spThumbEncodeImage(CGImageRef cg, CFStringRef uti, double quality) {
    NSMutableData *md = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)md, uti, 1, NULL);
    if (!dst) return nil;
    NSDictionary *props = @{
        (__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality),
    };
    CGImageDestinationAddImage(dst, cg, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok ? md : nil;
}

static bool spThumbBlackBorders(CVPixelBufferRef buf, bool fullRangeOverride, int fullRangeValue,
                                size_t *top, size_t *bot, size_t *left, size_t *right) {
    const OSType fmt = CVPixelBufferGetPixelFormatType(buf);
    const bool tenBit =
        fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    bool fullRange =
        fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    if (fullRangeOverride) fullRange = fullRangeValue != 0;
    if (CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return false;
    }
    const size_t W = CVPixelBufferGetWidthOfPlane(buf, 0);
    const size_t H = CVPixelBufferGetHeightOfPlane(buf, 0);
    const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 0);
    if (!base || W < 16 || H < 16) {
        CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
        return false;
    }

    const unsigned thresh = (fullRange ? 0 : 16) + 4;
    const auto edges = tenBit
        ? spthumb::findBlackBorders<true>(base, W, H, stride, thresh)
        : spthumb::findBlackBorders<false>(base, W, H, stride, thresh);
    CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    *top = edges.top; *bot = edges.bottom; *left = edges.left; *right = edges.right;
    if (*top + *bot + *left + *right == 0) return false;

    if (*top == H / 4 && *bot == H / 4 && *left == W / 4 && *right == W / 4) return false;
    if (W - *left - *right < W / 2 || H - *top - *bot < H / 2) return false;
    return true;
}

static CIImage *spThumbCropLetterbox(CIImage *ci, CVPixelBufferRef buf) {
    size_t top = 0, bot = 0, left = 0, right = 0;
    if (!spThumbBlackBorders(buf, false, 0, &top, &bot, &left, &right)) return ci;
    const size_t W = CVPixelBufferGetWidthOfPlane(buf, 0);
    const size_t H = CVPixelBufferGetHeightOfPlane(buf, 0);

    const CGRect r = CGRectMake((CGFloat)left, (CGFloat)bot,
                                (CGFloat)(W - left - right),
                                (CGFloat)(H - top - bot));
    return [[ci imageByCroppingToRect:r]
        imageByApplyingTransform:CGAffineTransformMakeTranslation(-r.origin.x,
                                                                  -r.origin.y)];
}

static CIImage *spThumbFitCI(CIImage *ci, AVRational sar = {1,1},
                             sp::VideoOrientation orient = {}, double maxWidth = 384.0) {
    // DV decodes at native size to preserve reshape inputs. Compatible BL
    // fallback still needs its coded pixel aspect before fitting the image.
    if (sar.num > 0 && sar.den > 0 && sar.num != sar.den)
        ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(av_q2d(sar),1)];
    if (!orient.isIdentity()) {
        // Core Image space is y-up like the orientation matrix; re-anchor the
        // rotated extent at the origin. Pure geometry: no resampling or color work.
        int m[4];
        sp::videoOrientationMatrix(orient, m);
        ci = [ci imageByApplyingTransform:CGAffineTransformMake(m[0], m[2], m[1], m[3], 0, 0)];
        ci = [ci imageByApplyingTransform:CGAffineTransformMakeTranslation(
                 -ci.extent.origin.x, -ci.extent.origin.y)];
    }
    CGFloat w = ci.extent.size.width, h = ci.extent.size.height;
    double s = std::min(maxWidth / w, (maxWidth * 9.0 / 16.0) / h);
    if (s >= 1.0) return ci;
    CIFilter *f = [CIFilter filterWithName:@"CILanczosScaleTransform"];
    [f setValue:ci forKey:kCIInputImageKey];
    [f setValue:@(s) forKey:kCIInputScaleKey];
    CIImage *out = f.outputImage;
    return out ?: ci;
}

static CGImageRef spThumbRenderCG(CIContext *ciCtx, CGColorSpaceRef srgb,
                                  CVPixelBufferRef buf, int hdrTrc,
                                  bool *outHDR, unsigned logId, AVRational sar = {1,1},
                                  sp::VideoOrientation orient = {}, double maxWidth = 384.0)
    CF_RETURNS_RETAINED {
    *outHDR = false;
    if (hdrTrc == 16 /*PQ*/ || hdrTrc == 18 /*HLG*/) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:buf];
        if (ci) ci = spThumbFitCI(spThumbCropLetterbox(ci, buf),sar,orient,maxWidth);
        CGColorSpaceRef hdrSpace = CGColorSpaceCreateWithName(
            hdrTrc == 16 ? kCGColorSpaceITUR_2100_PQ : kCGColorSpaceITUR_2100_HLG);
        if (ci && hdrSpace) {

            CGImageRef cg = [ciCtx createCGImage:ci
                                        fromRect:ci.extent
                                          format:kCIFormatRGBA16
                                      colorSpace:hdrSpace];
            CGColorSpaceRelease(hdrSpace);
            if (cg) {
                *outHDR = true;
                return cg;
            }
            if (spDebug()) {
                NSLog(@"[c%u][Thumb] CI RGBA16/PQ 渲染失败，跌落 SDR", logId);
            }
        } else if (hdrSpace) {
            CGColorSpaceRelease(hdrSpace);
        }

    }
    CIImage *ci = [CIImage imageWithCVPixelBuffer:buf
                                          options:@{kCIImageToneMapHDRtoSDR : @YES}];
    if (!ci) return NULL;
    ci = spThumbFitCI(spThumbCropLetterbox(ci, buf),sar,orient,maxWidth);
    return [ciCtx createCGImage:ci
                       fromRect:ci.extent
                         format:kCIFormatRGBA8
                     colorSpace:srgb];
}

// HEIC quality 0.8 and JPEG quality 0.72 balance artifacting and size at
// 384x216. SDR remains an sRGB JPEG path.
static NSData *spThumbEncodeCG(CGImageRef cg, bool isHDR) {
    return spThumbEncodeImage(cg, isHDR ? CFSTR("public.heic") : CFSTR("public.jpeg"),
                              isHDR ? 0.8 : 0.72);
}

struct SPThumbDoviGpu {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pso;
    CVMetalTextureCacheRef texCache = NULL;
    id<MTLBuffer> outBuf;
    bool triedSetup = false;
    bool ready() const { return pso != nil && queue != nil && texCache != NULL; }
    void teardown() {
        if (texCache) { CFRelease(texCache); texCache = NULL; }
        pso = nil; queue = nil; outBuf = nil; device = nil; triedSetup = false;
    }
};

static bool spThumbDoviGpuSetup(SPThumbDoviGpu &g, unsigned logId) {
    if (g.triedSetup) return g.ready();
    g.triedSetup = true;
    g.device = MTLCreateSystemDefaultDevice();
    if (!g.device) return false;
    NSError *error = nil;

    id<MTLLibrary> lib = [g.device newDefaultLibraryWithBundle:
                              [NSBundle bundleForClass:SPTimelineThumbnailer.class]
                                                       error:&error];
    if (!lib) {
        lib = [g.device newLibraryWithSource:@(kSPShaderSource) options:nil error:&error];
    }
    id<MTLFunction> fn = [lib newFunctionWithName:@"doviThumbConvert"];
    if (!fn) {
        NSLog(@"[c%u][Thumb] DoVi 转换核加载失败: %@", logId, error);
        return false;
    }
    g.pso = [g.device newComputePipelineStateWithFunction:fn error:&error];
    g.queue = [g.device newCommandQueue];
    CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, g.device, NULL, &g.texCache);
    if (!g.ready()) NSLog(@"[c%u][Thumb] DoVi 转换核建管线失败: %@", logId, error);
    return g.ready();
}

// One state per thumbnail seek. Prefer metadata inspected on the actual output
// picture; other backends use the conservative packet/PTS parser. A picture's
// explicit absent/invalid verdict must also override the packet cache.
struct SPThumbDoviState {
    std::unique_ptr<sp::DoviParser> parser;
    std::map<int64_t, std::array<float, sp::dovi_gpu::FloatCount>> frames;
    AVRational tb;
    AVCodecID codec = AV_CODEC_ID_NONE;
    int profile = 0, lengthSize = 0;
    bool dualLayer = false, rejectUnsupportedRPU = false, requiresMetadata = false;
    explicit SPThumbDoviState(const AVCodecParameters *par, AVRational timebase) : tb(timebase) {
        const auto *cfg = sp::doviConfig(par);
        const auto metadataPolicy = sp::doviMetadataPolicy(cfg);
        rejectUnsupportedRPU = metadataPolicy.rejectUnsupportedRPU;
        requiresMetadata = metadataPolicy.requireFrameMetadata;
        if (!cfg || !sp::doviMappingSupported(par)) return;
        profile = cfg->dv_profile;
        codec = par->codec_id;
        dualLayer = sp::doviHEVCDualLayerSupported(par);
        if (dualLayer) return; // the paired decorator owns RPU + EL
        parser = std::make_unique<sp::DoviParser>(profile, cfg->dv_bl_signal_compatibility_id,
                                                 cfg->dv_md_compression);
        lengthSize = sp::doviNalLengthSize(par);
        if (profile == 10) parser->setAV1Config(par->extradata,std::max(par->extradata_size,0));
    }
    void feed(const AVPacket *pkt, id<SPVideoDecoding> decoder = nil) {
        if (!parser || !pkt || pkt->size <= 0) return;
        if (profile == 10 && [decoder isKindOfClass:SPFFmpegDecoder.class] &&
            ((SPFFmpegDecoder *)decoder).doviPictureMetadataActive) return;
        size_t size = 0;
        if (const auto *extra = av_packet_get_side_data(pkt, AV_PKT_DATA_NEW_EXTRADATA, &size)) {
            parser->reset();
            if (profile == 10) parser->setAV1Config(extra,size);
            lengthSize = sp::doviNalLengthSize(codec, extra, size);
        }
        sp::DoviReshape rp;
        const auto parsed = profile == 10 ? parser->parseAV1(pkt->data, pkt->size, rp)
                                         : parser->parse(pkt->data, pkt->size, lengthSize, rp);
        if (rejectUnsupportedRPU && parsed == sp::DoviParser::Result::Unsupported) requiresMetadata = true;
        if (pkt->pts == AV_NOPTS_VALUE) return;
        const int64_t pts = av_rescale_q(pkt->pts, tb, AV_TIME_BASE_Q);
        frames.erase(pts);
        // This single-layer helper must never apply a residual-dependent RPU.
        // Dual-layer metadata and enhancement are handled by the paired decorator.
        if (rp.valid && !rp.needsEnhancement) sp::doviToGpuFloats(rp, frames[pts].data());
        while (frames.size() > 96) frames.erase(frames.begin());
    }
    const float *find(int64_t pts) const {
        const auto it = frames.find(pts);
        return it == frames.end() ? nullptr : it->second.data();
    }
    const float *find(const SPDecodedVideoOutput& out) const {
        if (dualLayer || (profile == 10 &&
            CVBufferGetAttachment(out.pixelBuffer,kSPDoviPictureMetadata,nullptr))) {
            const auto *metadata = spDoviFrameUniforms(out.pixelBuffer);
            return metadata ? metadata->values : nullptr;
        }
        return find(out.ptsUs);
    }
};

// Worker-private, supported HEVC dual-layer inputs only. Other inputs read
// directly. The same bounded join preserves exact timestamps and explicit track/PID
// association. Read-ahead bytes count against the preview's existing budget.
struct SPThumbDoviPackets {
    AVFormatContext *ctx;
    int base, enhancement = -1, enhancementId = -1;
    int pmtVersion = -2;
    unsigned streamCount = 0;
    bool extraNeeded = false;
    sp::DoviPacketJoiner joiner;
    SPThumbDoviPackets(AVFormatContext *c, int b) : ctx(c), base(b) {
        // Establish the BL even before EL is known. A PMT discovered inside
        // the first raw read can then activate pairing without that first EL
        // escaping through the unconfigured joiner's raw-reader fast path.
        joiner.configure(base,-1,ctx->streams[base]->time_base,{0,1},0);
        refresh();
    }
    void flush() { joiner.clear(); }
    void refresh() {
        const AVProgram *program = av_find_program_from_stream(ctx, nullptr, base);
        const int version = program ? program->pmt_version : -1;
        if (streamCount == ctx->nb_streams && pmtVersion == version) return;
        streamCount = ctx->nb_streams; pmtVersion = version;
        const int next = sp::doviUniqueEnhancement(ctx, base);
        const auto *el = next >= 0 ? ctx->streams[next] : nullptr;
        const int id = el ? el->id : -1;
        if (el) {
            sp::doviPublishCombinedConfig(ctx->streams[base]->codecpar, el->codecpar);
            extraNeeded = true;
        }
        if (next != enhancement || id != enhancementId) {
            joiner.changeAssociation(next,el ? el->time_base : AVRational{0,1},
                                    el ? sp::doviNalLengthSize(el->codecpar) : 0);
        }
        enhancement = next; enhancementId = id;
    }
    template<class Interrupted>
    int read(AVPacket *out, int64_t budget, int64_t& bytes, Interrupted&& interrupted) {
        bytes = 0;
        const int ret = joiner.read(out, [&](AVPacket *pkt) {
            if (interrupted()) return AVERROR_EXIT;
            if (bytes >= budget) return AVERROR(EAGAIN);
            const int r = av_read_frame(ctx,pkt);
            if (r < 0) return r;
            bytes += std::max(pkt->size,0);
            refresh();
            if (pkt->stream_index == enhancement && extraNeeded) {
                const auto *par = ctx->streams[enhancement]->codecpar;
                size_t size = 0;
                if (!av_packet_get_side_data(pkt,AV_PKT_DATA_NEW_EXTRADATA,&size) &&
                    par->extradata_size > 0 && par->extradata_size <= 65536) {
                    if (auto *extra = av_packet_new_side_data(pkt,AV_PKT_DATA_NEW_EXTRADATA,par->extradata_size))
                        memcpy(extra,par->extradata,par->extradata_size);
                }
                extraNeeded = false;
            }
            return r;
        });
        if (ret >= 0) if (const auto *el = sp::doviPacketEnhancement(out); el && el->packet->pos >= 0)
            out->pos = out->pos >= 0 ? std::min(out->pos,el->packet->pos) : el->packet->pos;
        return ret;
    }
};

// Orientation in y-down pixel space. A point (x, y) of a w x h image maps to the
// oriented image (axes swapped for quarter turns); doubled coordinates keep
// pixel centers integral.
static void spThumbOrientPoint(double x, double y, size_t w, size_t h,
                               sp::VideoOrientation o, double *ox, double *oy) {
    int m[4];
    sp::videoOrientationMatrix(o, m);
    const double ow = o.swapsAxes() ? h : w, oh = o.swapsAxes() ? w : h;
    const double u = x - w / 2.0, v = h / 2.0 - y; // centered, y-up
    *ox = m[0] * u + m[1] * v + ow / 2.0;
    *oy = oh / 2.0 - (m[2] * u + m[3] * v);
}

// Exact pixel permutation (any packed pixel size) into a tightly packed buffer.
static NSData *spThumbOrientPixels(const uint8_t *src, size_t w, size_t h, size_t bpp,
                                   sp::VideoOrientation o) {
    NSMutableData *out = [NSMutableData dataWithLength:w * h * bpp];
    if (!out) return nil;
    int m[4];
    sp::videoOrientationMatrix(o, m);
    const long ow = o.swapsAxes() ? (long)h : (long)w, oh = o.swapsAxes() ? (long)w : (long)h;
    uint8_t *dst = (uint8_t *)out.mutableBytes;
    for (long y = 0; y < (long)h; y++) {
        const long Y2 = (long)h - 2 * y - 1;
        for (long x = 0; x < (long)w; x++) {
            const long X2 = 2 * x + 1 - (long)w;
            const long dx = (m[0] * X2 + m[1] * Y2 + ow - 1) / 2;
            const long dy = (oh - 1 - (m[2] * X2 + m[3] * Y2)) / 2;
            memcpy(dst + ((size_t)dy * ow + dx) * bpp, src + ((size_t)y * w + x) * bpp, bpp);
        }
    }
    return out;
}

static CGImageRef spThumbRenderDoviCG(SPThumbDoviGpu &g, CVPixelBufferRef buf,
                                      const float *dovi, unsigned logId,
                                      CVPixelBufferRef enhancement = nullptr,
                                      AVRational sar = {1,1},
                                      sp::VideoOrientation orient = {}, double maxWidth = 384.0)
    CF_RETURNS_RETAINED {
    const OSType fmt = CVPixelBufferGetPixelFormatType(buf);
    const bool is10 = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                      fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    const bool is8 = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                     fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if ((!is10 && !is8) || CVPixelBufferGetPlaneCount(buf) < 2) return NULL;
    const bool fel = dovi[sp::dovi_gpu::NeedsEnhancement] > .5f;
    if (fel && !spDoviEnhancementBits(enhancement)) return NULL;
    const size_t W = CVPixelBufferGetWidthOfPlane(buf, 0), H = CVPixelBufferGetHeightOfPlane(buf, 0);
    const size_t W1 = CVPixelBufferGetWidthOfPlane(buf, 1), H1 = CVPixelBufferGetHeightOfPlane(buf, 1);
    if (W == 0 || H == 0 || W1 == 0 || H1 == 0) return NULL;
    int ow=0, oh=0;
    spThumbFitSize((int)W,(int)H,sar,&ow,&oh,orient,maxWidth);
    const size_t outW=ow, outH=oh;
    CVMetalTextureRef yRef = NULL, uvRef = NULL;
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, g.texCache, buf, NULL,
                                              is10 ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm,
                                              W, H, 0, &yRef);
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, g.texCache, buf, NULL,
                                              is10 ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm,
                                              W1, H1, 1, &uvRef);
    if (!yRef || !uvRef) {
        if (yRef) CFRelease(yRef);
        if (uvRef) CFRelease(uvRef);
        return NULL;
    }
    CVMetalTextureRef elRefs[2] = {};
    if (fel && !spDoviCreateEnhancementTextures(g.texCache, enhancement, elRefs)) {
        CFRelease(yRef); CFRelease(uvRef);
        return NULL;
    }
    CVMetalTextureRef elYRef = elRefs[0], elUVRef = elRefs[1];
    const size_t bytes = outW * outH * 8;
    if (!g.outBuf || g.outBuf.length < bytes) {
        g.outBuf = [g.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    }
    CGImageRef cg = NULL;
    if (g.outBuf) {
        id<MTLCommandBuffer> cmd = [g.queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:g.pso];
        [enc setTexture:CVMetalTextureGetTexture(yRef) atIndex:0];
        [enc setTexture:CVMetalTextureGetTexture(uvRef) atIndex:1];
        [enc setTexture:CVMetalTextureGetTexture(fel ? elYRef : yRef) atIndex:2];
        [enc setTexture:CVMetalTextureGetTexture(fel ? elUVRef : uvRef) atIndex:3];
        SPDoviUniforms rpu, snapshot; memcpy(rpu.values, dovi, sizeof(rpu));
        spDoviPrepareDrawSnapshot(snapshot, rpu, buf, fel ? enhancement : nullptr, false);
        [enc setBytes:&snapshot length:sizeof(snapshot) atIndex:0];
        const int32_t meta[4] = {is10 ? 10 : 8, ow, oh, 0};
        [enc setBytes:meta length:sizeof(meta) atIndex:1];
        [enc setBuffer:g.outBuf offset:0 atIndex:2];
        const MTLSize tg = MTLSizeMake(16, 16, 1);
        const MTLSize groups = MTLSizeMake((outW + 15) / 16, (outH + 15) / 16, 1);
        [enc dispatchThreadgroups:groups threadsPerThreadgroup:tg];
        [enc endEncoding];
        [cmd commit];
        [cmd waitUntilCompleted];
        if (!enc || cmd.status != MTLCommandBufferStatusCompleted) {
            NSLog(@"[c%u][Thumb] DoVi 转换核执行失败: %@", logId, cmd.error);
        } else {
            NSData *data = orient.isIdentity()
                ? [NSData dataWithBytes:g.outBuf.contents length:bytes]
                : spThumbOrientPixels((const uint8_t *)g.outBuf.contents, outW, outH, 8, orient);
            const size_t imgW = orient.swapsAxes() ? outH : outW;
            const size_t imgH = orient.swapsAxes() ? outW : outH;
            CGDataProviderRef prov = data ? CGDataProviderCreateWithCFData((__bridge CFDataRef)data) : NULL;
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
            if (prov && cs) {
                cg = CGImageCreate(imgW, imgH, 16, 64, imgW * 8, cs,
                                   (CGBitmapInfo)kCGImageAlphaNoneSkipLast |
                                       (CGBitmapInfo)kCGBitmapByteOrder16Little,
                                   prov, NULL, false, kCGRenderingIntentDefault);
            }
            if (cs) CGColorSpaceRelease(cs);
            if (prov) CGDataProviderRelease(prov);
        }
    }
    CFRelease(yRef);
    CFRelease(uvRef);
    if (elYRef) CFRelease(elYRef);
    if (elUVRef) CFRelease(elUVRef);
    if (!cg) return NULL;

    size_t top = 0, bot = 0, left = 0, right = 0;
    if (spThumbBlackBorders(buf, true, dovi[sp::dovi_gpu::FullRange] > 0.5f ? 1 : 0, &top, &bot, &left, &right)) {
        CGRect keep = CGRectMake((CGFloat)left * outW/W, (CGFloat)top * outH/H,
                                 (CGFloat)(W - left - right) * outW/W, (CGFloat)(H - top - bot) * outH/H);
        if (!orient.isIdentity()) {
            double x0, y0, x1, y1;
            spThumbOrientPoint(CGRectGetMinX(keep), CGRectGetMinY(keep), outW, outH, orient, &x0, &y0);
            spThumbOrientPoint(CGRectGetMaxX(keep), CGRectGetMaxY(keep), outW, outH, orient, &x1, &y1);
            keep = CGRectMake(std::min(x0, x1), std::min(y0, y1), fabs(x1 - x0), fabs(y1 - y0));
        }
        CGImageRef cropped = CGImageCreateWithImageInRect(cg, keep);
        if (cropped) {
            CGImageRelease(cg);
            cg = cropped;
        }
    }
    return cg;
}

// Only HEVC setup's parameter-set fallback reads this hint. Keep its existing
// owning snapshot semantics: NSData's copy property may materialize borrowed
// no-copy data anyway. Other codecs need no whole-keyframe allocation at all.
static NSData *spThumbFirstPacketHint(const AVCodecParameters *par,
                                      const AVPacket *pkt) {
    if (!par || par->codec_id != AV_CODEC_ID_HEVC || !pkt ||
        !pkt->data || pkt->size <= 0) return nil;
    return [NSData dataWithBytes:pkt->data length:(NSUInteger)pkt->size];
}

@interface SPTimelineThumbnailer ()
// Internal configuration, deliberately absent from the public bridge header.
- (BOOL)configurePersistentCacheDirectory:(NSURL *)directory intervalSeconds:(double)seconds;
@property (nonatomic, readonly) BOOL persistentPreparationPending;
- (void)_mainStoreJPEG:(NSData *)jpeg
              forKeyUs:(int64_t)keyUs
      resolvedTargetUs:(int64_t)resolvedTargetUs
           previewImage:(nullable id)previewImage
              dustValid:(BOOL)dustValid dustHue:(float)dustHue dustSat:(float)dustSat dustLuma:(float)dustLuma;
- (void)_mainStoreDustKeys:(NSData *)keys sweepSpacingUs:(int64_t)spacing;
- (void)_mainStorePreviewImage:(id)image
                      forKeyUs:(int64_t)keyUs
              resolvedTargetUs:(int64_t)resolvedTargetUs;
- (void)_mainNoteResolvedTargetUs:(int64_t)targetUs forKeyUs:(int64_t)keyUs;
- (void)_mainNotePersistentBucketUs:(int64_t)bucketUs forKeyUs:(int64_t)keyUs;
- (void)_lruInsert:(id)image forKeyUs:(int64_t)keyUs;
@end

static bool spThumbDustColor(CGImageRef cg, float *hue, float *sat, float *luma);

static void spThumbQueuePublication(std::shared_ptr<SPThumbShared> shared, dispatch_block_t block) {
    if (!shared || shared->stop.load()) return;
    if (shared->persistentIntervalUs <= 0) {
        dispatch_async(dispatch_get_main_queue(), block);
        return;
    }
    unsigned pending = shared->pendingPublications.load();
    do {
        if (pending >= 4) return;
    } while (!shared->pendingPublications.compare_exchange_weak(pending, pending + 1));
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!shared->stop.load()) block();
        shared->pendingPublications.fetch_sub(1);
    });
}

static void spThumbPublishImage(__weak SPTimelineThumbnailer *target,
                                CGImageRef cg, int64_t keyUs,
                                int64_t resolvedTargetUs,
                                std::shared_ptr<SPThumbShared> shared) {
    if (!cg) return;
    id boxed = CFBridgingRelease(CGImageRetain(cg));
    spThumbQueuePublication(shared, ^{
        SPTimelineThumbnailer *s = target;
        if (s) [s _mainStorePreviewImage:boxed
                                forKeyUs:keyUs
                        resolvedTargetUs:resolvedTargetUs];
    });
}

// Optional diagnostic override for hover I/O priority. Background sweeps remain
// throttled. Parse once; a negative value leaves the normal policy unchanged.
static int spThumbHoverIOPolicyOverride() {
#if SP_APP_STORE
    return -1;
#else
    static const int policy = [] {
        const char *e = getenv("SP_THUMB_IOPOL");
        if (!e) return -1;
        if (strcmp(e, "throttle") == 0) return IOPOL_THROTTLE;
        if (strcmp(e, "utility") == 0) return IOPOL_UTILITY;
        if (strcmp(e, "standard") == 0) return IOPOL_STANDARD;
        return -1;
    }();
    return policy;
#endif
}

static void spThumbApplyIOTier(spthumb::SPThumbIOTier tier, bool hoverTask) {
    int policy = IOPOL_THROTTLE;
    switch (tier) {
        case spthumb::SPThumbIOTier::Standard: policy = IOPOL_STANDARD; break;
        case spthumb::SPThumbIOTier::Utility:  policy = IOPOL_UTILITY;  break;
        case spthumb::SPThumbIOTier::Throttle: policy = IOPOL_THROTTLE; break;
    }
    if (hoverTask) {
        const int override_ = spThumbHoverIOPolicyOverride();
        if (override_ >= 0) policy = override_;
    }
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, policy);
}

// Each preview worker owns its AVIO. It never shares or seeks playback's input.
// A cancelled custom input is retired rather than leaving AVIO's sticky error
// in a shadow demuxer that would otherwise never issue another read.
struct SPThumbHTTPInput {
    std::unique_ptr<sp::HTTPRangeIO> input;
    AVIOContext *io = nullptr;
    void reset() {
        if (io) { av_freep(&io->buffer); avio_context_free(&io); }
        input.reset();
    }
    ~SPThumbHTTPInput() { reset(); }
    int attach(AVFormatContext *context, const std::string &url,
               std::function<bool()> interrupted, std::function<bool()> admitted) {
        reset();
        input = std::make_unique<sp::HTTPRangeIO>(url, std::move(interrupted), 15.0);
        input->setReadAdmission(std::move(admitted));
        const int result = input->open();
        if (result < 0) { reset(); return result; }
        constexpr int bytes = 32 * 1024;
        auto *buffer = static_cast<uint8_t *>(av_malloc(bytes));
        if (!buffer) { reset(); return AVERROR(ENOMEM); }
        io = avio_alloc_context(buffer, bytes, 0, input.get(),
            [](void *opaque, uint8_t *destination, int count) {
                return static_cast<sp::HTTPRangeIO *>(opaque)->read(destination, count);
            }, nullptr, [](void *opaque, int64_t offset, int whence) {
                return static_cast<sp::HTTPRangeIO *>(opaque)->seek(offset, whence);
            });
        if (!io) { av_free(buffer); reset(); return AVERROR(ENOMEM); }
        io->seekable = AVIO_SEEKABLE_NORMAL;
        context->pb = io;
        context->flags |= AVFMT_FLAG_CUSTOM_IO;
        return 0;
    }
};

static void spThumbWorkerMain(std::shared_ptr<SPThumbShared> sh,
                              SPThumbIdleProbe probe,
                              SPThumbSeekBusyProbe seekBusy,
                              __weak SPTimelineThumbnailer *weakSelf) {
    pthread_setname_np("sp.thumbs");

    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);

    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE);

    AVFormatContext *ctx = nullptr;
    SPThumbHTTPInput httpInput;
    id<SPVideoDecoding> dec = nil;
    std::unique_ptr<SPThumbDoviPackets> doviPackets;
    CIContext *ciCtx = nil;
    SPThumbDoviGpu doviGpu;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    int vs = -1;
    int hdrTrc = 0;
    sp::VideoOrientation orient; // container display matrix, baked into each image
    bool opened = false, openFailed = false, decoderFailed = false;
    bool planBuilt = false;
    std::vector<int64_t> keyAbsUs;
    std::vector<int64_t> plan;
    size_t planIdx = 0;
    int planFail = 0;
    bool sweepLogged = false;
    bool persistentHasMisses = false;
    int64_t persistentRetryAfterUs = 0;
    std::set<int64_t> done;
    int generated = 0;
    int64_t sweepT0 = 0;

    bool indexTrusted = true;

    int64_t keyPtsOffsetUs = 0;
    bool keyPtsCalibrated = false;
    int64_t tsGopUs = 0;

    sp::SPTsRapLimits tsLim = sp::spThumbTsRapLimits();
    std::vector<spthumb::SPThumbFailNote> failNotes;
    int decoderSetupFails = 0;
    double lastCostMs = 0;
    int64_t httpRetryAfterUs = 0;
    std::unique_ptr<spthumb::PersistentThumbnailStore> persistent;
    if (!sh->persistentDirectory.empty() && sh->persistentIntervalUs > 0) {
        persistent = std::make_unique<spthumb::PersistentThumbnailStore>(
            [NSURL fileURLWithPath:[NSString stringWithUTF8String:sh->persistentDirectory.c_str()]],
            sh->durationUs, sh->persistentIntervalUs, sh->videoStreamIndex, sh->videoStreamId,
            sh->videoPar ? sh->videoPar->width : 0, sh->videoPar ? sh->videoPar->height : 0);
        plan = spthumb::persistentPreviewPlan(sh->durationUs, sh->persistentIntervalUs);
        for (auto &target : plan) target += sh->originUs;
        planBuilt = true;
    }

    auto retireHTTPContext = [&] {
        if (!sh->http) return;
        doviPackets.reset();
        if (ctx) avformat_close_input(&ctx);
        httpInput.reset();
        if (dec) { [dec shutdown]; dec = nil; }
        vs = -1; opened = false;
    };

    auto publishDisk = [&](const spthumb::PersistentPreview &sample) {
        __weak SPTimelineThumbnailer *target = weakSelf;
        NSData *data = sample.data;
        const int64_t key = sample.keyUs, resolved = sample.resolvedTargetUs;
        const int64_t bucket = sample.bucketUs;
        spThumbQueuePublication(sh, ^{
            if (SPTimelineThumbnailer *owner = target) {
                [owner _mainStoreJPEG:data forKeyUs:key resolvedTargetUs:resolved
                        previewImage:nil dustValid:NO dustHue:0 dustSat:0 dustLuma:0];
                [owner _mainNotePersistentBucketUs:bucket forKeyUs:key];
            }
        });
    };

    spthumb::SPThumbKeyMap tsKeys;

    auto ensureOpen = [&](const SPThumbClaim &claim) -> SPThumbOpenResult {
        if (opened) return SPThumbOpenResult::Ready;
        if (openFailed) return SPThumbOpenResult::Failed;
        sh->cbYieldBase.store(claim.yieldBase);
        sh->cbHoverBase.store(kImmuneBase);
        sh->cbCancelBase.store(claim.cancelBase);

        auto interrupted = [&] {
            return spthumb::taskInterrupted(sh->stop.load(),
                sh->http ? claim.yieldBase : sh->yieldSeq.load(), claim.yieldBase,
                sh->hoverSeq.load(), kImmuneBase,
                sh->cancelSeq.load(), claim.cancelBase);
        };
        AVFormatContext *c = avformat_alloc_context();
        if (!c) { openFailed = true; return SPThumbOpenResult::Failed; }
        c->interrupt_callback = { spThumbInterruptCb, sh.get() };
        AVDictionary *opts = nullptr;
        av_dict_set(&opts, "scan_all_pmts", "0", 0);
        int64_t t0 = spNowUs();
        int ret = 0;
        if (sh->http) {
            ret = httpInput.attach(c, sh->path, [sh] { return spThumbInterruptCb(sh.get()); },
                [probe] { return !probe || probe(); });
        }
        if (ret >= 0) ret = avformat_open_input(&c, sh->path.c_str(), nullptr, &opts);
        else avformat_free_context(c);
        av_dict_free(&opts);
        if (ret < 0) {
            if (sh->http) httpInput.reset();
            if (interrupted() || (sh->http && probe && !probe())) return SPThumbOpenResult::Preempted;
            if (sh->http && (ret == AVERROR(EIO) || ret == AVERROR(ETIMEDOUT))) {
                httpRetryAfterUs = spNowUs() + 3000000;
                return SPThumbOpenResult::Preempted;
            }
            openFailed = true;
            if (sh->persistentIntervalUs > 0) sh->persistentSweepFinished.store(true);
            if (spDebug()) NSLog(@"[c%u][Thumb] open 失败 ret=%d，本会话停用", sh->logId, ret);
            return SPThumbOpenResult::Failed;
        }

        if (c->nb_streams == 0) {
            AVPacket *warm = av_packet_alloc();
            for (int k = 0; warm && k < 32 && c->nb_streams == 0; ++k) {
                if (av_read_frame(c, warm) < 0) break;
                av_packet_unref(warm);
            }
            av_packet_free(&warm);
            if (interrupted()) {
                avformat_close_input(&c);
                if (sh->http) httpInput.reset();
                return SPThumbOpenResult::Preempted;
            }
        }

        bool matched = false;
        auto isVideoStream = [&](unsigned i) {
            return c->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO;
        };
        if (sh->videoStreamIndex >= 0) {
            const int want = sh->videoStreamIndex;
            if ((unsigned)want < c->nb_streams && isVideoStream((unsigned)want) &&
                (sh->videoStreamId == 0 || c->streams[want]->id == sh->videoStreamId)) {
                vs = want;
                matched = true;
            } else if (sh->videoStreamId != 0) {
                for (unsigned i = 0; i < c->nb_streams; ++i) {
                    if (isVideoStream(i) && c->streams[i]->id == sh->videoStreamId) {
                        vs = (int)i;
                        matched = true;
                        break;
                    }
                }
            }
            if (!matched) {
                avformat_close_input(&c);
                if (sh->http) httpInput.reset();
                openFailed = true;
                if (sh->persistentIntervalUs > 0) sh->persistentSweepFinished.store(true);
                if (spDebug()) NSLog(@"[c%u][Thumb] 影子上下文无主视频流（索引 %d id %d），本会话停用",
                                     sh->logId, want, sh->videoStreamId);
                return SPThumbOpenResult::Failed;
            }
        }
        for (unsigned i = 0; vs < 0 && i < c->nb_streams; ++i) {
            AVStream *s = c->streams[i];
            if (s->codecpar->codec_type == AVMEDIA_TYPE_VIDEO &&
                !(s->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
                vs = (int)i;
                break;
            }
        }
        if (vs < 0) {
            avformat_close_input(&c);
            if (sh->http) httpInput.reset();
            openFailed = true;
            if (sh->persistentIntervalUs > 0) sh->persistentSweepFinished.store(true);
            if (spDebug()) NSLog(@"[c%u][Thumb] 无可用视频流，本会话停用", sh->logId);
            return SPThumbOpenResult::Failed;
        }
        ctx = c;

        {
            AVCodecParameters *par = c->streams[vs]->codecpar;

            if (matched && sh->videoPar && (par->extradata_size == 0 || par->width <= 0)) {
                avcodec_parameters_copy(par, sh->videoPar);
            }

            if (par->color_primaries == AVCOL_PRI_UNSPECIFIED &&
                sh->colorPrimaries != 0 && sh->colorPrimaries != 2)
                par->color_primaries = (AVColorPrimaries)sh->colorPrimaries;
            if (par->color_trc == AVCOL_TRC_UNSPECIFIED &&
                sh->colorTrc != 0 && sh->colorTrc != 2)
                par->color_trc = (AVColorTransferCharacteristic)sh->colorTrc;
            if (par->color_space == AVCOL_SPC_UNSPECIFIED && sh->colorSpace != 2)
                par->color_space = (AVColorSpace)sh->colorSpace;
            if (par->color_range == AVCOL_RANGE_UNSPECIFIED && sh->colorRange > 0)
                par->color_range = (AVColorRange)sh->colorRange;
            hdrTrc = par->color_trc;
            {
                const AVPacketSideData *dm = av_packet_side_data_get(
                    par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
                orient = sp::videoOrientationFromDisplayMatrixData(dm ? dm->data : nullptr,
                                                                   dm ? dm->size : 0);
            }
            // The main context may have published a combined DV configuration
            // after associating separate tracks. Preserve shadow color fields.
            if (matched && !sp::doviConfig(par) && sp::doviConfig(sh->videoPar) &&
                par->codec_id == sh->videoPar->codec_id) {
                auto *side = av_packet_side_data_new(&par->coded_side_data,&par->nb_coded_side_data,
                    AV_PKT_DATA_DOVI_CONF,sizeof(AVDOVIDecoderConfigurationRecord),0);
                if (side) memcpy(side->data,sp::doviConfig(sh->videoPar),sizeof(AVDOVIDecoderConfigurationRecord));
            }
        }
        AVStream *st = ctx->streams[vs];
        indexTrusted = spthumb::spThumbIndexTrustworthy(c->iformat ? c->iformat->name : nullptr);

        if (indexTrusted && keyAbsUs.empty()) {
            if (avformat_index_get_entries_count(st) < 16 && sh->durationUs > 0) {
                int64_t midTs = av_rescale_q(sh->originUs + sh->durationUs / 2,
                                             AV_TIME_BASE_Q, st->time_base);
                (void)avformat_seek_file(ctx, vs, INT64_MIN, midTs, midTs, 0);
            }
            const int nb = avformat_index_get_entries_count(st);
            for (int i = 0; i < nb; ++i) {
                const AVIndexEntry *e = avformat_index_get_entry(st, i);
                if (!e || !(e->flags & AVINDEX_KEYFRAME)) continue;
                keyAbsUs.push_back(av_rescale_q(e->timestamp, st->time_base,
                                                AV_TIME_BASE_Q));
            }
            std::sort(keyAbsUs.begin(), keyAbsUs.end());
            keyAbsUs.erase(std::unique(keyAbsUs.begin(), keyAbsUs.end()),
                           keyAbsUs.end());

            if (interrupted()) {
                avformat_close_input(&ctx);
                if (sh->http) httpInput.reset();
                ctx = nullptr;
                vs = -1;
                keyAbsUs.clear();
                return SPThumbOpenResult::Preempted;
            }
        }
        if (sp::doviHEVCDualLayerSupported(st->codecpar))
            doviPackets = std::make_unique<SPThumbDoviPackets>(ctx,vs);
        if (sh->http) {
            for (unsigned i = 0; i < ctx->nb_streams; ++i) {
                const bool needed = (int)i == vs || (doviPackets && (int)i == doviPackets->enhancement);
                ctx->streams[i]->discard = needed ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
            }
        }

        int64_t dur = sh->durationUs;
        if (dur <= 0 && ctx->duration > 0) dur = ctx->duration;
        if (!indexTrusted) {
            const int64_t size = ctx->pb ? avio_size(ctx->pb) : 0;
            tsLim = sp::spThumbTsRapLimits(size > 0 && dur > 0 ? size * 1000000 / dur : 0);
        }
        int maxSweep = sh->remote ? 60 : 120;
#if !SP_APP_STORE
        if (const char *e = getenv("SP_THUMBS_MAX")) {
            int v = atoi(e);
            if (v >= 0 && v <= 1000) maxSweep = v;
        }
#endif
        if (!planBuilt && dur > 2 * 1000000LL && maxSweep > 0) {
            int n = (int)std::min((int64_t)maxSweep, dur / 5000000LL);
            n = std::min(n, keyAbsUs.size() >= 8 ? (int)keyAbsUs.size() : 16);
            std::vector<int64_t> targets;
            for (int i = 0; i < n; ++i) {
                targets.push_back(sh->originUs +
                                  dur * (2 * (int64_t)i + 1) / (2 * n));
            }

            int bits = 0;
            while ((1 << bits) < (int)targets.size()) bits++;
            std::vector<std::pair<uint32_t, int64_t>> order;
            order.reserve(targets.size());
            for (size_t i = 0; i < targets.size(); ++i) {
                uint32_t r = 0;
                for (int b = 0; b < bits; ++b)
                    if (i & (1u << b)) r |= 1u << (bits - 1 - b);
                order.push_back({r, targets[i]});
            }
            std::stable_sort(order.begin(), order.end(),
                             [](const auto &a, const auto &b) {
                                 return a.first < b.first;
                             });
            for (auto &p : order) plan.push_back(p.second);
        }
        planBuilt = true;
        opened = true;

        {
            NSMutableData *keys = [NSMutableData data];
            const int nbk = (indexTrusted && st) ? avformat_index_get_entries_count(st) : 0;
            for (int i = 0; i < nbk; ++i) {
                const AVIndexEntry *e = avformat_index_get_entry(st, i);
                if (!e || !(e->flags & AVINDEX_KEYFRAME) || e->pos < 0) continue;
                SPDustKey k;
                k.tsUs = av_rescale_q(e->timestamp, st->time_base, AV_TIME_BASE_Q) - sh->originUs;
                k.pos = e->pos;
                [keys appendBytes:&k length:sizeof k];
            }
            const int64_t spacing = plan.empty() ? 0 : dur / (int64_t)plan.size();
            __weak SPTimelineThumbnailer *dustTarget = weakSelf;
            spThumbQueuePublication(sh, ^{
                [dustTarget _mainStoreDustKeys:keys sweepSpacingUs:spacing];
            });
        }
        if (spDebug()) {
            NSLog(@"[c%u][Thumb] open %.0fms 索引关键帧=%zu%@ 扫描计划=%zu%s",
                  sh->logId, (spNowUs() - t0) / 1000.0, keyAbsUs.size(),
                  indexTrusted ? @"" : [NSString stringWithFormat:@"（索引不可信，向后 RAP 扫描，单点预算 %lldMiB）",
                                        (long long)(tsLim.maxBytes >> 20)],
                  plan.size(), sh->remote ? "（远程卷）" : "");
        }
        return SPThumbOpenResult::Ready;
    };

    auto genThumb = [&](const SPThumbClaim &claim) -> int {
      // The detached worker has no outer autorelease pool. Drain each thumbnail
      // independently so CIImage, CVPixelBuffer, CGImage and NSData intermediates
      // cannot accumulate for the lifetime of the thread. Full-size software
      // fallback surfaces can otherwise retain roughly 154 MB across 48 images.
      @autoreleasepool {
        const int64_t absTargetUs = claim.targetAbsUs;
        sh->cbYieldBase.store(claim.yieldBase);
        sh->cbHoverBase.store(claim.hoverBase);
        sh->cbCancelBase.store(claim.cancelBase);
        auto interrupted = [&] {
            return spthumb::taskInterrupted(sh->stop.load(),
                sh->http ? claim.yieldBase : sh->yieldSeq.load(), claim.yieldBase,
                sh->hoverSeq.load(), claim.hoverBase,
                sh->cancelSeq.load(), claim.cancelBase);
        };
        AVStream *st = ctx->streams[vs];

        auto noteResolved = [&](int64_t keyUs) {
            const int64_t noteKeyUs = keyUs;
            const int64_t noteTargetUs =
                std::max<int64_t>(absTargetUs - sh->originUs, 0);
            if (persistent) (void)persistent->alias(noteTargetUs, keyUs, noteTargetUs);

            __weak SPTimelineThumbnailer *noteObj = weakSelf;
            spThumbQueuePublication(sh, ^{
                SPTimelineThumbnailer *s = noteObj;
                if (s) [s _mainNoteResolvedTargetUs:noteTargetUs
                                           forKeyUs:noteKeyUs];
            });
        };
        int64_t mappedKey = -1;
        {

            const int64_t k = spthumb::spThumbMapTargetToIndexKeyAbsUs(
                keyAbsUs, absTargetUs, keyPtsOffsetUs);
            if (k != INT64_MIN) {
                mappedKey = std::max<int64_t>(k - sh->originUs, 0);
                if (done.count(mappedKey)) {
                    noteResolved(mappedKey);
                    return 1;
                }
            }
        }

        spthumb::SPThumbKeyHit tsHit;
        if (!indexTrusted) {
            tsHit = tsKeys.resolve(absTargetUs);
            if (tsHit.known) {
                mappedKey = std::max<int64_t>(tsHit.ptsAbsUs - sh->originUs, 0);
                if (done.count(mappedKey)) {
                    noteResolved(mappedKey);
                    return 1;
                }
            }
        }

        if (spthumb::spThumbFailSuppressed(failNotes, absTargetUs, spNowUs())) return 0;

        if (interrupted()) return -1;
        int64_t t0 = spNowUs();
        bool tsFromTable = false;

        bool scanComplete = true;
        auto noteFail = [&] {
            spthumb::spThumbFailNoteAdd(failNotes, absTargetUs, tsGopUs, spNowUs());
        };
        SPDecodedVideoOutput out = SPDecodedVideoOutputEmpty();
        int fed = 0;
        struct ReleasePreviewPackets {
            SPThumbDoviPackets *packets;
            ~ReleasePreviewPackets() { if (packets) packets->flush(); }
        } releasePreviewPackets{doviPackets.get()};
        // Open copied the main stream's DV configuration only onto a matched
        // stream; never apply it to another stream's pictures.
        SPThumbDoviState doviState(st->codecpar, st->time_base);

        auto feedPacket = [&](AVPacket *pkt) -> bool {
            if (!dec) {
                if (decoderFailed) return false;
                SPVideoDecoder *vt = [SPVideoDecoder new];
                vt.spLogId = sh->logId;
                // Non-HEVC codecs never consume a first-packet hint.
                vt.firstPacketHint = spThumbFirstPacketHint(st->codecpar, pkt);
                int ow = 0, oh = 0;
                spThumbFitSize(st->codecpar->width, st->codecpar->height,
                               st->codecpar->sample_aspect_ratio, &ow, &oh, orient, sh->http ? 320.0 : 384.0);
                // DV reshape/residuals are nonlinear. Decode at native size;
                // compute integrates reconstructed linear light into the small
                // thumbnail directly. This work is on-demand, outside playback.
                const bool nativeDovi = sp::doviMappingSupported(st->codecpar);
                if (nativeDovi) { ow=st->codecpar->width; oh=st->codecpar->height; }
                vt.outputWidthHint = ow;
                vt.outputHeightHint = oh;
                int r = [vt setupWithCodecParameters:st->codecpar
                                   timeBaseNumerator:st->time_base.num
                                 timeBaseDenominator:st->time_base.den];
                vt.firstPacketHint = nil;
                if (r == 0) {
                    dec = vt;
                } else {
                    [vt shutdown];
                    // Fall back to FFmpeg when VideoToolbox cannot decode the
                    // codec, including unsupported AV1, VC-1 and RV variants.
                    // Single-frame slice mode avoids frame-pipeline startup cost
                    // for an isolated keyframe.
                    SPFFmpegDecoder *sw = [SPFFmpegDecoder new];
                    sw.spLogId = sh->logId;
                    sw.singleFrameMode = YES;

                    sw.outputWidthHint = ow;
                    sw.outputHeightHint = oh;
                    int r2 = [sw setupWithCodecParameters:st->codecpar
                                        timeBaseNumerator:st->time_base.num
                                      timeBaseDenominator:st->time_base.den];
                    if (r2 != 0) {
                        [sw shutdown];
                        if (++decoderSetupFails >= 2) decoderFailed = true;
                        if (spDebug()) NSLog(@"[c%u][Thumb] 解码器创建失败 VT r=%d 软解 r=%d（第 %d 次）%s", sh->logId, r, r2, decoderSetupFails, decoderFailed ? "，缩略图停用" : "");
                        return false;
                    }
                    dec = sw;
                    if (spDebug()) NSLog(@"[c%u][Thumb] VT 不支持(r=%d)，FFmpeg 软解兜底", sh->logId, r);
                }
                decoderSetupFails = 0;
                dec = SPWrapDoviThumbnailDecoder(dec,st->codecpar,st->time_base.num,
                                                 st->time_base.den,nativeDovi ? 0 : ow,nativeDovi ? 0 : oh);
                if (!dec) { decoderFailed = true; return false; }
            }
            doviState.feed(pkt,dec);
            out = [dec decodePacketOutput:pkt];
            fed++;
            return true;
        };
        // A join can read ahead while waiting for EL. Count the physical
        // packets here, including discarded/unmatched EL, and stop on cancel.
        auto readPacket = [&](AVPacket *pkt, int64_t budget, int64_t& bytes) {
            if (doviPackets) return doviPackets->read(pkt,budget,bytes,interrupted);
            const int r = av_read_frame(ctx,pkt);
            bytes = r >= 0 ? std::max(pkt->size,0) : 0;
            return r;
        };
        auto flushPackets = [&] { if (doviPackets) doviPackets->flush(); };

        auto readAndFeed = [&]() -> bool {
            AVPacket *pkt = av_packet_alloc();
            if (!pkt) return true;
            bool keyFed = fed > 0;
            int64_t videoPkts = 0, bytes = 0;
            while (!spthumb::spThumbReadBudgetExhausted(videoPkts, bytes)) {
                if (interrupted()) { av_packet_free(&pkt); return false; }
                int64_t readBytes = 0;
                const int r = readPacket(pkt,16LL*1024*1024-bytes,readBytes);
                bytes += readBytes;
                if (r < 0) break;
                if (pkt->stream_index != vs) { av_packet_unref(pkt); continue; }
                videoPkts++;
                if (!keyFed && !(pkt->flags & AV_PKT_FLAG_KEY)) {
                    av_packet_unref(pkt);
                    continue;
                }
                const bool ok = feedPacket(pkt);
                av_packet_unref(pkt);
                if (!ok) break;
                keyFed = true;
                if (out.pixelBuffer) break;

                if (dec.lastError != 0 || fed >= 8) break;
            }
            av_packet_free(&pkt);
            return true;
        };

        auto feedKnownKey = [&](const spthumb::SPThumbKeyHit &hit) -> int {
            flushPackets();
            if (av_seek_frame(ctx, vs, hit.pos, AVSEEK_FLAG_BYTE) < 0) return 0;
            AVPacket *pkt = av_packet_alloc();
            if (!pkt) return 0;
            int r = 0;
            int64_t bytes = 0;
            for (int n = 0; n < 256; ++n) {
                if (interrupted()) { r = -1; break; }
                int64_t readBytes = 0;
                const int rd = readPacket(pkt,16LL*1024*1024-bytes,readBytes);
                bytes += readBytes;
                if (rd < 0) break;
                if (pkt->stream_index != vs) { av_packet_unref(pkt); continue; }
                const int64_t pts = pkt->pts != AV_NOPTS_VALUE
                    ? av_rescale_q(pkt->pts, st->time_base, AV_TIME_BASE_Q) : INT64_MIN;
                const bool match = (pkt->flags & AV_PKT_FLAG_KEY) && pts != INT64_MIN &&
                                   llabs(pts - hit.ptsAbsUs) <= 1000;
                if (match && feedPacket(pkt)) r = 1;
                av_packet_unref(pkt);
                break;
            }
            av_packet_free(&pkt);
            return r;
        };
        if (indexTrusted) {

            int64_t ts = av_rescale_q(absTargetUs, AV_TIME_BASE_Q, st->time_base);
            flushPackets();
            if (avformat_seek_file(ctx, vs, INT64_MIN, ts, ts, 0) < 0) {
                if (interrupted()) return -1;
                noteFail();
                return 0;
            }
            if (!readAndFeed()) { if (dec) [dec flush]; return -1; }
        } else {

            int64_t replayPos = -1;
            bool tsFed = false;
            tsFromTable = false;
            if (tsHit.known) {
                const int r = feedKnownKey(tsHit);
                if (r < 0) return -1;
                tsFed = r == 1;
                tsFromTable = tsFed;
                replayPos = tsHit.pos;
                if (spDebug()) NSLog(@"[c%u][Thumb] 关键帧表命中 %.1fs → %.1fs%@", sh->logId,
                                     (absTargetUs - sh->originUs) / 1e6,
                                     (tsHit.ptsAbsUs - sh->originUs) / 1e6,
                                     tsFed ? @"（按字节回放）" : @"（回放落不到，改扫描）");
            }
            if (!tsFed) {
                const std::function<bool()> abortFn = [&] { return interrupted(); };
                sp::SPTsRapPacketReader associatedReader;
                if (doviPackets) {
                    associatedReader.read = readPacket;
                    associatedReader.flush = flushPackets;
                }
                sp::SPTsRapScanResult rap = sp::spTsRapScanBackward(
                    ctx, vs, absTargetUs, sh->originUs, tsLim, &tsGopUs, &abortFn,
                    doviPackets ? &associatedReader : nullptr);

                tsKeys.noteReorder(rap.reorderMaxUs);
                for (const auto &k : rap.keys) tsKeys.noteKey(k.first, k.second);
                for (const auto &o : rap.observed)
                    tsKeys.noteSpan(o.fromDtsUs, o.untilDtsUs, o.fromHead, o.untilEof);
                if (rap.aborted || interrupted()) return -1;
                if (rap.pos < 0 || !rap.keyPkt) {
                    if (spDebug()) NSLog(@"[c%u][Thumb] RAP 扫描未找到关键帧 %.1fs（capped=%d 读 %lldKB）",
                                         sh->logId, (absTargetUs - sh->originUs) / 1e6,
                                         (int)rap.capped, (long long)(rap.bytes / 1024));
                    noteFail();
                    return 0;
                }

                if (rap.fromHead && !rap.reachedFloor && !rap.spanExhausted) {
                    if (spDebug()) NSLog(@"[c%u][Thumb] RAP 扫描触上界（读 %lldKB）退到片头，不作 %.1fs 的答案",
                                         sh->logId, (long long)(rap.bytes / 1024),
                                         (absTargetUs - sh->originUs) / 1e6);
                    noteFail();
                    return 0;
                }
                mappedKey = std::max<int64_t>(rap.ptsUs - sh->originUs, 0);
                scanComplete = !rap.capped;
                if (!scanComplete && spDebug())
                    NSLog(@"[c%u][Thumb] RAP 扫描不完整（读 %lldKB）：%.1fs 取邻近图 %.1fs，不登记精确覆盖",
                          sh->logId, (long long)(rap.bytes / 1024),
                          (absTargetUs - sh->originUs) / 1e6, (rap.ptsUs - sh->originUs) / 1e6);
                if (!feedPacket(rap.keyPkt)) { noteFail(); return 0; }
                replayPos = rap.pos;
            }
            if (!out.pixelBuffer && dec.lastError == 0) {

                [dec flush];
                fed = 0;
                flushPackets();
                if (av_seek_frame(ctx, vs, replayPos, AVSEEK_FLAG_BYTE) >= 0) {
                    if (!readAndFeed()) { [dec flush]; return -1; }
                }
            }
        }
        if (!out.pixelBuffer) {
            // Isolated preview: drain both reorder queues within the existing
            // packet budget before falling back to BL or declaring no image.
            if (doviState.dualLayer && dec && !interrupted())
                out = [dec decodePacketOutput:nullptr];
        }
        if (!out.pixelBuffer) {
            if (dec) [dec flush];
            if (interrupted()) return -1;
            noteFail();
            return 0;
        }
        int64_t keyUs = out.ptsUs - sh->originUs;
        if (keyUs < 0) keyUs = 0;
        const int64_t resolvedTargetUs = spthumb::spThumbCoverageTargetUs(
            scanComplete, keyUs, std::max<int64_t>(absTargetUs - sh->originUs, 0));

        if (spthumb::discardDecodedFrame(sh->stop.load(), sh->http ? claim.yieldBase : sh->yieldSeq.load(),
                                         claim.yieldBase, sh->cancelSeq.load(),
                                         claim.cancelBase)) {
            if (doviState.dualLayer) CVBufferRemoveAttachment(out.pixelBuffer,kSPDoviEnhancementFrame);
            CVPixelBufferRelease(out.pixelBuffer);
            [dec flush];
            return -1;
        }
        const bool supersededByHover =
            claim.hoverBase != kImmuneBase && sh->hoverSeq.load() != claim.hoverBase;
        if (!ciCtx) {
            ciCtx = [CIContext contextWithOptions:@{
                kCIContextCacheIntermediates : @NO }];
        }
        bool isHEIC = false;

        CGImageRef cg = NULL;
        const auto *frameDovi = doviState.dualLayer ? spDoviFrameUniforms(out.pixelBuffer) : nullptr;
        const float *doviFloats = doviState.find(out);
        if (!doviFloats && doviState.requiresMetadata) {
            CVPixelBufferRelease(out.pixelBuffer);
            [dec flush];
            noteFail();
            return 0;
        }
        std::array<float, sp::dovi_gpu::FloatCount> fallback;
        if (!doviFloats && sh->doviIPT) {
            sp::doviToGpuFloats(sp::DoviReshape{}, fallback.data());
            doviFloats = fallback.data();
        }
        const bool mappedDovi = doviFloats != nullptr;
        if (mappedDovi) {
            // Preserve mapped BT.2020 PQ, including compatible P8/P10 and MEL.
            if (spThumbDoviGpuSetup(doviGpu, sh->logId)) {
                cg = spThumbRenderDoviCG(doviGpu, out.pixelBuffer, doviFloats, sh->logId,
                    frameDovi ? spDoviEnhancementFrame(out.pixelBuffer) : nullptr,
                    sp::doviMappingSupported(st->codecpar) ? st->codecpar->sample_aspect_ratio : AVRational{1,1},
                    orient, sh->http ? 320.0 : 384.0);
            }
            isHEIC = cg != NULL;
        } else {
            cg = spThumbRenderCG(ciCtx, srgb, out.pixelBuffer, hdrTrc, &isHEIC, sh->logId,
                sp::doviMappingSupported(st->codecpar) ? st->codecpar->sample_aspect_ratio : AVRational{1,1},
                orient, sh->http ? 320.0 : 384.0);
        }

        int64_t tPublishUs = 0;
        if (cg && isHEIC) {
            spThumbPublishImage(weakSelf, cg, keyUs, resolvedTargetUs, sh);
            tPublishUs = spNowUs();
        }
        NSData *jpeg = cg ? spThumbEncodeCG(cg, isHEIC) : nil;
        if (!jpeg && isHEIC && !mappedDovi) {

            if (spDebug()) NSLog(@"[c%u][Thumb] HEIC 编码失败，跌落 SDR", sh->logId);
            CGImageRelease(cg);
            isHEIC = false;
            cg = spThumbRenderCG(ciCtx, srgb, out.pixelBuffer, /*hdrTrc=*/0,
                                 &isHEIC, sh->logId,
                sp::doviMappingSupported(st->codecpar) ? st->codecpar->sample_aspect_ratio : AVRational{1,1},
                orient, sh->http ? 320.0 : 384.0);
            jpeg = cg ? spThumbEncodeCG(cg, false) : nil;
            if (jpeg) spThumbPublishImage(weakSelf, cg, keyUs, resolvedTargetUs, sh);
        }
        if (doviState.dualLayer) CVBufferRemoveAttachment(out.pixelBuffer,kSPDoviEnhancementFrame);
        CVPixelBufferRelease(out.pixelBuffer);
        [dec flush];
        if (!jpeg) {
            if (cg) CGImageRelease(cg);
            noteFail();
            return 0;
        }
        failNotes.clear();
        if (persistent) {
            (void)persistent->save(std::max<int64_t>(absTargetUs - sh->originUs, 0),
                                   keyUs, resolvedTargetUs, isHEIC, jpeg);
        }

        if (indexTrusted && !keyAbsUs.empty() && !keyPtsCalibrated) {
            keyPtsCalibrated = true;
            keyPtsOffsetUs = spthumb::spThumbIndexPtsOffsetUs(keyAbsUs, out.ptsUs);
            if (keyPtsOffsetUs > 0) {

                const int64_t k = spthumb::spThumbMapTargetToIndexKeyAbsUs(
                    keyAbsUs, absTargetUs, keyPtsOffsetUs);
                mappedKey = k == INT64_MIN ? -1 : std::max<int64_t>(k - sh->originUs, 0);
                if (spDebug()) NSLog(@"[c%u][Thumb] 索引 dts→pts 偏移校准 %.1fms", sh->logId, keyPtsOffsetUs / 1000.0);
            }
        }
        done.insert(keyUs);

        if (mappedKey >= 0 && spthumb::spThumbIndexKeyAliasesDecoded(mappedKey, keyUs))
            done.insert(mappedKey);
        generated++;
#if !SP_APP_STORE

        if (const char *dumpDir = getenv("SP_THUMBS_DUMP")) {
            NSString *p = [NSString stringWithFormat:@"%s/thumb_%07.1fs.%s",
                                                     dumpDir, keyUs / 1e6,
                                                     isHEIC ? "heic" : "jpg"];
            [jpeg writeToFile:p atomically:NO];

            if (isHEIC && cg) {
                NSData *png = spThumbEncodeImage(cg, CFSTR("public.png"), 1.0);
                if (png) {
                    [png writeToFile:[NSString stringWithFormat:
                                         @"%s/thumb_%07.1fs.pre.png",
                                         dumpDir, keyUs / 1e6]
                          atomically:NO];
                }
            }
        }
#endif
        lastCostMs = (spNowUs() - t0) / 1000.0;
        if (spDebug() && (generated <= 3 || generated % 20 == 0 || supersededByHover)) {

            NSLog(@"[c%u][Thumb] #%d key=%.1fs %.0fms%@ %luKB%@%@", sh->logId, generated,
                  keyUs / 1e6, lastCostMs,
                  tPublishUs ? [NSString stringWithFormat:@" 图=%.0fms",
                                   (tPublishUs - t0) / 1000.0] : @"",
                  (unsigned long)(jpeg.length / 1024),
                  tsFromTable ? @"（关键帧表命中）" : @"",
                  supersededByHover ? @"（已被新 hover 顶替，作邻近图发布）" : @"");
        }

        float dustH = 0, dustS = 0, dustL = 0;
        const bool dustOK = spThumbDustColor(cg, &dustH, &dustS, &dustL);
        id previewImage = nil;
        if (claim.kind == SPThumbTaskKind::Hover && !isHEIC) {
            previewImage = CFBridgingRelease(cg);
        } else {
            CGImageRelease(cg);
        }
        // Materialize a local weak reference before creating the Objective-C
        // block. Capturing the worker's weakSelf parameter through a [&] lambda
        // would retain a reference to stack storage after the worker exits;
        // value capture registers the weak reference correctly.
        __weak SPTimelineThumbnailer *publishTarget = weakSelf;
        const int64_t persistentBucket = sh->persistentIntervalUs > 0
            ? spthumb::persistentPreviewBucket(std::max<int64_t>(absTargetUs - sh->originUs, 0),
                                               sh->persistentIntervalUs) : -1;
        spThumbQueuePublication(sh, ^{
            SPTimelineThumbnailer *s = publishTarget;
            if (s) {
                [s _mainStoreJPEG:jpeg
                            forKeyUs:keyUs
                    resolvedTargetUs:resolvedTargetUs
                         previewImage:previewImage
                            dustValid:dustOK dustHue:dustH dustSat:dustS dustLuma:dustL];
                if (persistentBucket >= 0) [s _mainNotePersistentBucketUs:persistentBucket forKeyUs:keyUs];
            }
        });
        return 1;
      } // @autoreleasepool
    };

    int probeBlockedStreak = 0;

    int64_t gateSettleUs = -1;
    uint64_t gateSettleYield = 0;
    for (;;) {
      @autoreleasepool {
        if (sh->stop.load()) break;

        spThumbApplyIOTier(spthumb::SPThumbIOTier::Throttle, /*hoverTask=*/false);
        SPThumbClaim claim;
        {
            std::unique_lock<std::mutex> lk(sh->mtx);

            if (!sh->evictedKeys.empty()) {
                for (int64_t k : sh->evictedKeys) {

                    done.erase(k - 1);
                    done.erase(k);
                    done.erase(k + 1);
                }
                sh->evictedKeys.clear();
                failNotes.clear();
            }
            auto workLeft = [&] {
                if (persistent && !openFailed && !decoderFailed && planIdx >= plan.size() &&
                    persistentHasMisses && spNowUs() >= persistentRetryAfterUs) {
                    planIdx = 0;
                    planFail = 0;
                    sweepLogged = false;
                    persistentHasMisses = false;
                    sh->persistentSweepFinished.store(false);
                }

                return sh->sweepArmed && !openFailed && !decoderFailed &&
                       (!planBuilt || planIdx < plan.size());
            };
            if (sh->hoverTargetUs < 0 && !workLeft()) {
                if (openFailed || decoderFailed) {

                    sh->cv.wait(lk, [&] {
                        return sh->stop.load() || sh->hoverTargetUs >= 0;
                    });
                } else {

                    const bool signaled =
                        sh->cv.wait_for(lk, std::chrono::seconds(30), [&] {
                            return sh->stop.load() || sh->hoverTargetUs >= 0 ||
                                   workLeft();
                        });

                    if (!signaled && (dec || ciCtx || doviGpu.ready())) {
                        lk.unlock();
                        if (dec) { [dec shutdown]; dec = nil; }
                        ciCtx = nil;
                        doviGpu.teardown();
                        if (spDebug()) NSLog(@"[c%u][Thumb] 空闲拆除解码器/CIContext（上下文保留）", sh->logId);
                        lk.lock();
                    }
                }
            }
            if (sh->stop.load()) break;
            if (sh->hoverTargetUs >= 0) {
                // A persistent HTTP hit needs disk I/O only. Claim it before
                // every seek/admission gate, including Core's synthetic busy
                // state while another producer owns the network grant.
                if (!(sh->http && persistent)) {
                    const uint64_t curYield = sh->yieldSeq.load();
                    if (curYield != gateSettleYield) {
                        gateSettleYield = curYield;
                        gateSettleUs = -1;
                    }
                    const int64_t sinceYieldUs = spNowUs() - sh->lastYieldWallUs.load();
                    const bool seekBusyNow = seekBusy && seekBusy();
                    if (!seekBusyNow && gateSettleUs < 0) gateSettleUs = sinceYieldUs;
                    const int64_t waitUs = spthumb::hoverGateWaitUs(
                        sh->everInteracted.load(), sh->remote, sinceYieldUs,
                        seekBusyNow, gateSettleUs);
                    if (waitUs > 0) {
                        sh->cv.wait_for(lk, std::chrono::microseconds(waitUs + 1000));
                        continue;
                    }
                }

                claim.kind = SPThumbTaskKind::Hover;
                claim.targetAbsUs = sh->hoverTargetUs + sh->originUs;
                sh->activeHoverTargetUs = sh->hoverTargetUs;
                sh->hoverTargetUs = -1;
                claim.hoverBase = sh->hoverSeq.load();
                sh->activeHoverBase = claim.hoverBase;
                claim.yieldBase = sh->yieldSeq.load();
                claim.cancelBase = sh->cancelSeq.load();
            } else if (workLeft()) {

                claim.kind = SPThumbTaskKind::Sweep;
                claim.hoverBase = sh->hoverSeq.load();
                claim.yieldBase = sh->yieldSeq.load();

            }
        }

        spThumbApplyIOTier(spthumb::ioTierForClaim(claim.kind, sh->remote),
                           claim.kind == SPThumbTaskKind::Hover);

        if (claim.kind == SPThumbTaskKind::Hover) {

            // Disk samples remain available while playback, seeking, a subtitle
            // job or a manual buffering stop disallows all background network I/O.
            if (persistent) {
                const auto sample = persistent->load(std::max<int64_t>(claim.targetAbsUs - sh->originUs, 0));
                if (sample) {
                    publishDisk(*sample);
                    std::lock_guard<std::mutex> lock(sh->mtx);
                    sh->activeHoverTargetUs = INT64_MIN;
                    sh->persistentHoverPending.store(sh->hoverTargetUs >= 0);
                    continue;
                }
            }
            const int64_t httpHoverWaitUs = sh->http ? spthumb::hoverGateWaitUs(
                sh->everInteracted.load(), sh->remote,
                spNowUs() - sh->lastYieldWallUs.load(), seekBusy && seekBusy(), -1) : 0;
            if (sh->http && (httpHoverWaitUs > 0 || (probe && !probe()) || spNowUs() < httpRetryAfterUs)) {
                std::unique_lock<std::mutex> lock(sh->mtx);
                if (!sh->stop.load() && sh->hoverTargetUs < 0 &&
                    sh->hoverSeq.load() == claim.hoverBase && sh->cancelSeq.load() == claim.cancelBase)
                    sh->hoverTargetUs = std::max<int64_t>(claim.targetAbsUs - sh->originUs, 0);
                sh->activeHoverTargetUs = INT64_MIN;
                sh->cv.wait_for(lock, std::chrono::milliseconds(250));
                continue;
            }

            const SPThumbOpenResult o = ensureOpen(claim);
            int r = 0;
            if (o == SPThumbOpenResult::Preempted) {

                r = -1;
            } else if (o == SPThumbOpenResult::Ready && !decoderFailed) {
                r = genThumb(claim);
            }
            if (r == -1) {
                retireHTTPContext();

                std::unique_lock<std::mutex> lk(sh->mtx);
                for (;;) {
                    const auto d = spthumb::holdDecision(
                        sh->stop.load(), sh->hoverTargetUs >= 0,
                        sh->hoverSeq.load() != claim.hoverBase ||
                            sh->cancelSeq.load() != claim.cancelBase,
                        sh->remote,
                        spNowUs() - sh->lastYieldWallUs.load());
                    if (d.verdict == SPThumbHoldVerdict::Requeue) {
                        sh->hoverTargetUs = claim.targetAbsUs - sh->originUs;
                        break;
                    }
                    if (d.verdict == SPThumbHoldVerdict::Drop) break;
                    sh->cv.wait_for(lk,
                        std::chrono::microseconds(d.waitUs + 1000));
                }
                sh->activeHoverTargetUs = INT64_MIN;
                sh->persistentHoverPending.store(sh->hoverTargetUs >= 0);
            } else {
                if (sh->http && r == 0) retireHTTPContext();
                std::lock_guard<std::mutex> g(sh->mtx);
                sh->activeHoverTargetUs = INT64_MIN;
                sh->persistentHoverPending.store(sh->hoverTargetUs >= 0);
            }
            if (decoderFailed && sh->persistentIntervalUs > 0) sh->persistentSweepFinished.store(true);
            continue;
        }
        if (claim.kind != SPThumbTaskKind::Sweep) continue;

        // The persistent plan exists before a network context. Entirely cached
        // files can therefore be reused even when the source is unavailable.
        if (persistent && planIdx < plan.size()) {
            const auto sample = persistent->load(std::max<int64_t>(plan[planIdx] - sh->originUs, 0));
            if (sample) {
                ++planIdx;
                if (planIdx >= plan.size()) {
                    sh->persistentSweepFinished.store(true);
                    if (persistentHasMisses) persistentRetryAfterUs = spNowUs() + 30000000;
                }
                // Populate a few resident neighbours without retaining every
                // encoded image from a long file. Hover reloads exact disk hits.
                if (planIdx <= 8) publishDisk(*sample);
                continue;
            }
        }

        const bool quiet = spthumb::sweepQuietSatisfied(
            sh->remote, spNowUs() - sh->lastYieldWallUs.load());
        if (!quiet || (probe && !probe()) || (sh->http && spNowUs() < httpRetryAfterUs)) {
            // Report sustained admission blocking so a permanently false idle
            // predicate, such as a low packet watermark on TrueHD, is observable.
            if (++probeBlockedStreak % 120 == 0 && spDebug()) {
                NSLog(@"[c%u][Thumb] 闲判据连续拦截 ~%ds（quiet=%d probe=%d）",
                      sh->logId, probeBlockedStreak / 4, (int)quiet,
                      probe ? (int)probe() : -1);
            }
            std::unique_lock<std::mutex> lk(sh->mtx);
            sh->cv.wait_for(lk, std::chrono::milliseconds(250), [&] {
                return sh->stop.load() || sh->hoverTargetUs >= 0;
            });
            continue;
        }
        probeBlockedStreak = 0;

        if (ensureOpen(claim) != SPThumbOpenResult::Ready) continue;
        if (planIdx >= plan.size()) continue;
        if (sweepT0 == 0) sweepT0 = spNowUs();
        claim.targetAbsUs = plan[planIdx];
        const int r = genThumb(claim);
        if (sh->http && r <= 0) retireHTTPContext();
        if (decoderFailed && sh->persistentIntervalUs > 0) sh->persistentSweepFinished.store(true);
        if (r == 1) {
            planIdx++;
            planFail = 0;
        } else if (r == 0) {

            if (++planFail >= 2) {
                planIdx++; planFail = 0;
                if (persistent) persistentHasMisses = true;
            }
        }
        if (planIdx >= plan.size() && !sweepLogged) {
            if (sh->persistentIntervalUs > 0) sh->persistentSweepFinished.store(true);
            if (persistentHasMisses) persistentRetryAfterUs = spNowUs() + 30000000;
            sweepLogged = true;
            if (spDebug()) {
                NSLog(@"[c%u][Thumb] 扫描完成：%d 张 / %.1fs", sh->logId, generated,
                      (spNowUs() - sweepT0) / 1e6);
            }
        }

        std::unique_lock<std::mutex> lk(sh->mtx);
        sh->cv.wait_for(lk, std::chrono::milliseconds(
                                spthumb::sweepWaitMs(r == 1 ? lastCostMs : 0.0, sh->remote)),
                        [&] {
                            return sh->stop.load() || sh->hoverTargetUs >= 0;
                        });
      } // Disk hits and directory/image metadata also drain on every iteration.
    }

    if (dec) [dec shutdown];
    doviGpu.teardown();
    if (ctx) avformat_close_input(&ctx);
    CGColorSpaceRelease(srgb);
}

static bool spThumbDustColor(CGImageRef cg, float *hue, float *sat, float *luma) {
    if (!cg) return false;
    const size_t bpc = CGImageGetBitsPerComponent(cg);
    const size_t bpp = CGImageGetBitsPerPixel(cg);
    if (!((bpc == 8 && bpp == 32) || (bpc == 16 && bpp == 64))) return false;
    CGDataProviderRef prov = CGImageGetDataProvider(cg);
    CFDataRef data = prov ? CGDataProviderCopyData(prov) : NULL;
    if (!data) return false;
    const size_t W = CGImageGetWidth(cg), H = CGImageGetHeight(cg);
    const size_t stride = CGImageGetBytesPerRow(cg);
    const uint8_t *base = CFDataGetBytePtr(data);
    const size_t len = (size_t)CFDataGetLength(data);
    float hist[24] = {0};
    float binSat[24] = {0}, binLum[24] = {0};
    double lumaSum = 0; size_t n = 0;
    for (size_t y = 0; y < H; y += 2) {
        const uint8_t *row = base + y * stride;
        if ((size_t)(row - base) + W * (bpp / 8) > len) break;
        for (size_t x = 0; x < W; x += 2) {
            float r, g, b;
            if (bpc == 8) {
                const uint8_t *p = row + x * 4;
                r = p[0] / 255.f; g = p[1] / 255.f; b = p[2] / 255.f;
            } else {
                const uint16_t *p = (const uint16_t *)(row + x * 8);
                r = p[0] / 65535.f; g = p[1] / 65535.f; b = p[2] / 65535.f;
            }
            const float mx = fmaxf(r, fmaxf(g, b)), mn = fminf(r, fminf(g, b));
            const float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
            const float sa = mx > 0 ? (mx - mn) / mx : 0;
            lumaSum += l; n++;
            if (mx - mn > 0.03f) {
                float hh;
                if (mx == r) hh = (g - b) / (mx - mn);
                else if (mx == g) hh = 2 + (b - r) / (mx - mn);
                else hh = 4 + (r - g) / (mx - mn);
                if (hh < 0) hh += 6;
                int bin = (int)(hh * 4); if (bin > 23) bin = 23; if (bin < 0) bin = 0;
                hist[bin] += sa * l;
                binSat[bin] += sa * l;
                binLum[bin] += l;
            }
        }
    }
    CFRelease(data);
    if (n == 0) return false;

    float sm[24];
    for (int k = 0; k < 24; ++k)
        sm[k] = 0.5f * hist[k] + 0.25f * (hist[(k + 23) % 24] + hist[(k + 1) % 24]);
    int best = 0;
    for (int k = 1; k < 24; ++k) if (sm[k] > sm[best]) best = k;

    float satW = 0, lumW = 0;
    for (int d = -1; d <= 1; ++d) { int k = (best + d + 24) % 24; satW += binSat[k]; lumW += binLum[k]; }

    float hAcc = 0, wAcc = 0;
    for (int d = -1; d <= 1; ++d) { int k = (best + d + 24) % 24; hAcc += (best + d + 0.5f) * hist[k]; wAcc += hist[k]; }
    float hh = wAcc > 0 ? hAcc / wAcc : best + 0.5f;
    if (hh < 0) hh += 24; if (hh >= 24) hh -= 24;
    *hue = hh / 24.f;
    *sat = lumW > 0 ? satW / lumW : 0;
    *luma = (float)(lumaSum / n);
    return true;
}

@implementation SPThumbDustSnapshot
- (instancetype)initWithGeneration:(uint64_t)gen keys:(NSData *)keys covers:(NSData *)covers
                     sweepSpacingUs:(int64_t)spacing {
    if ((self = [super init])) {
        _generation = gen; _keys = keys; _covers = covers; _sweepSpacingUs = spacing;
    }
    return self;
}
@end

@implementation SPTimelineThumbnailer {
    std::shared_ptr<SPThumbShared> _shared;
    SPThumbIdleProbe _idleProbe;
    SPThumbSeekBusyProbe _seekBusyProbe;
    void (^_onUpdate)(void);
    BOOL _workerStarted;

    std::map<int64_t, NSData *> _encodedByKeyUs;
    size_t _encodedBytes;
    int64_t _lastQueryKeyUs;

    std::map<int64_t, std::pair<int64_t, int64_t>> _coveredByKeyUs;
    std::map<int64_t, int64_t> _persistentBucketKeys;

    BOOL _sawHDR;
    std::list<std::pair<int64_t, id>> _lru;
    std::map<int64_t, std::list<std::pair<int64_t, id>>::iterator> _lruIdx;

    NSData *_dustKeys;
    int64_t _dustSweepSpacingUs;
    std::map<int64_t, std::array<float, 3>> _dustColorByKeyUs;
    uint64_t _dustGen;
    SPThumbDustSnapshot *_dustSnapCache;
    uint64_t _dustSnapCacheGen;
}

- (void)setSpLogId:(unsigned)spLogId {
    _spLogId = spLogId;
    if (_shared) _shared->logId = spLogId;
}

- (instancetype)initWithPath:(NSString *)path
                  durationUs:(int64_t)durationUs
            timelineOriginUs:(int64_t)originUs
                remoteVolume:(BOOL)remoteVolume
              colorPrimaries:(int)colorPrimaries
                    colorTrc:(int)colorTrc
                  colorSpace:(int)colorSpace
                  colorRange:(int)colorRange
                 videoParams:(nullable const AVCodecParameters *)videoParams
            videoStreamIndex:(int)videoStreamIndex
               videoStreamId:(int)videoStreamId
                     doviIPT:(BOOL)doviIPT
                   idleProbe:(SPThumbIdleProbe)idleProbe
               seekBusyProbe:(nullable SPThumbSeekBusyProbe)seekBusyProbe
                    onUpdate:(void (^)(void))onUpdate {
    if ((self = [super init])) {
        _shared = std::make_shared<SPThumbShared>();
        _shared->http = sp::HTTPRangeIO::supportsURL(path.UTF8String ?: "");
        _shared->path = _shared->http ? (path.UTF8String ?: "") : path.fileSystemRepresentation;
        _shared->durationUs = durationUs;
        _shared->originUs = originUs;
        _shared->remote = remoteVolume;
        _shared->colorPrimaries = colorPrimaries;
        _shared->colorTrc = colorTrc;
        _shared->colorSpace = colorSpace;
        _shared->colorRange = colorRange;
        _shared->videoStreamIndex = videoStreamIndex;
        _shared->videoStreamId = videoStreamId;
        _shared->doviIPT = doviIPT;
        if (videoParams) {
            _shared->videoPar = avcodec_parameters_alloc();
            if (_shared->videoPar && avcodec_parameters_copy(_shared->videoPar, videoParams) < 0) {
                avcodec_parameters_free(&_shared->videoPar);
            }
        }
        _shared->lastYieldWallUs.store(spNowUs());
        _idleProbe = [idleProbe copy];
        _seekBusyProbe = [seekBusyProbe copy];
        _onUpdate = [onUpdate copy];
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (void)_ensureWorker {
    if (_workerStarted || !_shared) return;
    _workerStarted = YES;
    auto sh = _shared;
    SPThumbIdleProbe probe = _idleProbe;
    SPThumbSeekBusyProbe seekBusy = _seekBusyProbe;
    __weak SPTimelineThumbnailer *weakSelf = self;
    std::thread([sh, probe, seekBusy, weakSelf] {
        spThumbWorkerMain(sh, probe, seekBusy, weakSelf);
    }).detach();
}

- (void)startSweep {
    auto sh = _shared;
    if (!sh || sh->stop.load()) return;
    [self _ensureWorker];
    {
        std::lock_guard<std::mutex> g(sh->mtx);
        sh->sweepArmed = true;
    }
    sh->cv.notify_one();
}

- (BOOL)configurePersistentCacheDirectory:(NSURL *)directory intervalSeconds:(double)seconds {
    auto sh = _shared;
    if (!sh || _workerStarted || sh->stop.load() || !directory.isFileURL ||
        !directory.path.isAbsolutePath || !std::isfinite(seconds) || seconds < 1 || seconds > 60)
        return NO;
    sh->persistentDirectory = directory.path.fileSystemRepresentation;
    sh->persistentIntervalUs = (int64_t)llround(seconds * 1000000.0);
    return YES;
}

- (BOOL)persistentPreparationPending {
    auto sh = _shared;
    return sh && !sh->stop.load() && sh->persistentIntervalUs > 0 &&
        (!sh->persistentSweepFinished.load() || sh->persistentHoverPending.load());
}

- (void)requestPreviewAt:(double)seconds {
    auto sh = _shared;
    if (!sh || sh->stop.load() || !std::isfinite(seconds) || seconds < 0 ||
        seconds * 1e6 >= (double)INT64_MAX) return;
    int64_t tUs = (int64_t)(seconds * 1e6);
    if (sh->persistentIntervalUs > 0) {
        tUs = spthumb::persistentPreviewBucket(tUs, sh->persistentIntervalUs);
        const auto found = _persistentBucketKeys.find(tUs);
        if (found != _persistentBucketKeys.end() &&
            (_lruIdx.count(found->second) ||
             (_encodedByKeyUs.count(found->second) && _encodedByKeyUs[found->second].length > 0))) return;
    }
    [self _ensureWorker];
    {
        std::lock_guard<std::mutex> g(sh->mtx);

        const bool samePending = (sh->hoverTargetUs == tUs);
        const bool sameActiveFresh =
            sh->hoverTargetUs < 0 && sh->activeHoverTargetUs == tUs &&
            sh->hoverSeq.load() == sh->activeHoverBase;
        if (samePending || sameActiveFresh) return;
        sh->hoverTargetUs = tUs;
        if (sh->persistentIntervalUs > 0) sh->persistentHoverPending.store(true);

        sh->hoverSeq.fetch_add(1);
    }
    sh->cv.notify_one();
}

- (nullable id)previewImageAt:(double)seconds isExact:(nullable BOOL *)outExact {
    if (outExact) *outExact = NO;
    if (_encodedByKeyUs.empty() || seconds < 0) return nil;
    const int64_t tUs = (int64_t)(seconds * 1e6);
    auto it = _encodedByKeyUs.upper_bound(tUs);
    if (it != _encodedByKeyUs.begin()) --it;
    _lastQueryKeyUs = it->first;

    bool covered = false;
    {
        auto c = _coveredByKeyUs.find(it->first);
        covered = c != _coveredByKeyUs.end() &&
                  spthumb::spThumbCoverageContains(c->second.first, c->second.second, tUs);
    }

    if (!spthumb::spThumbPreviewWithinReach(tUs, it->first,
                                            _shared ? _shared->durationUs : 0, covered)) {
        return nil;
    }
    id img = [self _decodedImageForKeyUs:it->first jpeg:it->second];
    if (img && outExact && covered) *outExact = YES;
    return img;
}

- (BOOL)_mergeCoverageForKeyUs:(int64_t)keyUs targetUs:(int64_t)targetUs {
    const int64_t from = std::min(keyUs, targetUs);
    const int64_t until = std::max(keyUs, targetUs);
    auto c = _coveredByKeyUs.find(keyUs);
    if (c == _coveredByKeyUs.end()) {
        _coveredByKeyUs.emplace(keyUs, std::make_pair(from, until));
        return YES;
    }
    BOOL widened = NO;
    if (from < c->second.first) { c->second.first = from; widened = YES; }
    if (until > c->second.second) { c->second.second = until; widened = YES; }
    return widened;
}

- (void)_mainNoteResolvedTargetUs:(int64_t)targetUs forKeyUs:(int64_t)keyUs {
    if (!_shared || _shared->stop.load()) return;
    int64_t k = keyUs;
    if (!_encodedByKeyUs.count(k)) {

        auto near = _encodedByKeyUs.lower_bound(k - 1);
        if (near == _encodedByKeyUs.end() || llabs(near->first - k) > 1) return;
        k = near->first;
    }
    if ([self _mergeCoverageForKeyUs:k targetUs:targetUs]) {
        _dustGen++;
        if (_onUpdate) _onUpdate();
    }
    if (_shared->persistentIntervalUs > 0)
        [self _mainNotePersistentBucketUs:spthumb::persistentPreviewBucket(targetUs, _shared->persistentIntervalUs)
                               forKeyUs:k];
}

- (void)_mainNotePersistentBucketUs:(int64_t)bucketUs forKeyUs:(int64_t)keyUs {
    if (!_shared || _shared->stop.load() || bucketUs < 0 || keyUs < 0 || bucketUs > _shared->durationUs)
        return;
    if (_persistentBucketKeys.size() >= spthumb::kPersistentPreviewMaxSamples && !_persistentBucketKeys.count(bucketUs))
        _persistentBucketKeys.erase(_persistentBucketKeys.begin());
    _persistentBucketKeys[bucketUs] = keyUs;
}

- (void)_mainStoreDustKeys:(NSData *)keys sweepSpacingUs:(int64_t)spacing {
    if (!_shared || _shared->stop.load()) return;
    _dustKeys = keys;
    _dustSweepSpacingUs = spacing;
    _dustGen++;
    if (spDebug()) NSLog(@"[c%u][Dust] 关键帧表 %lu 项，扫描桶 %.1fs", _spLogId,
                         (unsigned long)(keys.length / sizeof(SPDustKey)), spacing / 1e6);
    if (_onUpdate) _onUpdate();
}

- (nullable SPThumbDustSnapshot *)dustSnapshot {
    if (!_shared) return nil;
    if (_dustSnapCache && _dustSnapCacheGen == _dustGen) return _dustSnapCache;
    NSMutableData *covers = [NSMutableData dataWithCapacity:_coveredByKeyUs.size() * sizeof(SPDustCover)];
    for (const auto &kv : _coveredByKeyUs) {
        SPDustCover c;
        c.keyUs = kv.first; c.fromUs = kv.second.first; c.untilUs = kv.second.second;
        auto col = _dustColorByKeyUs.find(kv.first);
        if (col != _dustColorByKeyUs.end()) {
            c.hue = col->second[0]; c.sat = col->second[1]; c.luma = col->second[2]; c.valid = 1;
        } else {
            c.hue = 0; c.sat = 0; c.luma = 0; c.valid = 0;
        }
        [covers appendBytes:&c length:sizeof c];
    }
    _dustSnapCache = [[SPThumbDustSnapshot alloc] initWithGeneration:_dustGen
                                                                keys:_dustKeys ?: [NSData data]
                                                              covers:covers
                                                      sweepSpacingUs:_dustSweepSpacingUs];
    _dustSnapCacheGen = _dustGen;
    return _dustSnapCache;
}

- (id)_decodedImageForKeyUs:(int64_t)keyUs jpeg:(NSData *)jpeg {
    auto f = _lruIdx.find(keyUs);
    if (f != _lruIdx.end()) {
        _lru.splice(_lru.begin(), _lru, f->second);
        return f->second->second;
    }

    if (jpeg.length == 0) return nil;

    CGImageSourceRef src =
        CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    CGImageRef cg = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src) CFRelease(src);
    if (!cg) {

        auto bad = _encodedByKeyUs.find(keyUs);
        if (bad != _encodedByKeyUs.end()) {
            _encodedBytes -= std::min(_encodedBytes, (size_t)bad->second.length);
            _encodedByKeyUs.erase(bad);
        }
        _coveredByKeyUs.erase(keyUs);

        if (auto sh = _shared) {
            std::lock_guard<std::mutex> g(sh->mtx);
            sh->evictedKeys.push_back(keyUs);
        }
        return nil;
    }
    id boxed = CFBridgingRelease(cg);
    [self _lruInsert:boxed forKeyUs:keyUs];
    return boxed;
}

- (void)_lruInsert:(id)image forKeyUs:(int64_t)keyUs {
    auto f = _lruIdx.find(keyUs);
    if (f != _lruIdx.end()) {
        f->second->second = image;
        _lru.splice(_lru.begin(), _lru, f->second);
        return;
    }
    _lru.emplace_front(keyUs, image);
    _lruIdx[keyUs] = _lru.begin();
    while (_lru.size() > spthumb::decodedLruCap(_sawHDR)) {
        _lruIdx.erase(_lru.back().first);
        _lru.pop_back();
    }
}

- (void)_mainStorePreviewImage:(id)image
                      forKeyUs:(int64_t)keyUs
              resolvedTargetUs:(int64_t)resolvedTargetUs {
    if (!_shared || _shared->stop.load() || !image) return;
    _sawHDR = YES;
    if (!_encodedByKeyUs.count(keyUs)) _encodedByKeyUs[keyUs] = nil;
    [self _lruInsert:image forKeyUs:keyUs];
    [self _mergeCoverageForKeyUs:keyUs targetUs:resolvedTargetUs];
    _dustGen++;
    if (_onUpdate) _onUpdate();
}

- (void)_mainStoreJPEG:(NSData *)jpeg
              forKeyUs:(int64_t)keyUs
      resolvedTargetUs:(int64_t)resolvedTargetUs
           previewImage:(nullable id)previewImage
              dustValid:(BOOL)dustValid dustHue:(float)dustHue dustSat:(float)dustSat dustLuma:(float)dustLuma {
    if (!_shared || _shared->stop.load()) return;
    if (dustValid) {
        _dustColorByKeyUs[keyUs] = {dustHue, dustSat, dustLuma};
        if (spDebug() && _dustColorByKeyUs.size() <= 12)
            NSLog(@"[c%u][Dust] 色 key=%.1fs hue=%.0f° sat=%.2f luma=%.2f", _spLogId, keyUs / 1e6,
                  dustHue * 360, dustSat, dustLuma);
    }
    _dustGen++;
    auto old = _encodedByKeyUs.find(keyUs);
    if (old != _encodedByKeyUs.end())
        _encodedBytes -= std::min(_encodedBytes, (size_t)old->second.length);
    _encodedByKeyUs[keyUs] = jpeg;
    _encodedBytes += jpeg.length;
    [self _mergeCoverageForKeyUs:keyUs targetUs:resolvedTargetUs];

    constexpr size_t kEncodedBytesCap = 16 * 1024 * 1024;
    const int64_t ref = _lastQueryKeyUs > 0 ? _lastQueryKeyUs : keyUs;
    while (_encodedBytes > kEncodedBytesCap && _encodedByKeyUs.size() > 1) {
        auto first = _encodedByKeyUs.begin();
        auto last = std::prev(_encodedByKeyUs.end());
        auto victim = llabs(first->first - ref) >= llabs(last->first - ref)
                          ? first : last;
        if (victim->first == keyUs) break;
        _encodedBytes -= std::min(_encodedBytes, (size_t)victim->second.length);
        auto lru = _lruIdx.find(victim->first);
        if (lru != _lruIdx.end()) { _lru.erase(lru->second); _lruIdx.erase(lru); }

        if (auto sh = _shared) {
            std::lock_guard<std::mutex> g(sh->mtx);
            sh->evictedKeys.push_back(victim->first);
        }
        _coveredByKeyUs.erase(victim->first);
        _dustColorByKeyUs.erase(victim->first);
        _encodedByKeyUs.erase(victim);
    }

    if (previewImage) [self _lruInsert:previewImage forKeyUs:keyUs];
    if (_onUpdate) _onUpdate();
}

- (void)noteInteraction {
    auto sh = _shared;
    if (!sh) return;

    std::lock_guard<std::mutex> g(sh->mtx);
    sh->lastYieldWallUs.store(spNowUs());
    sh->everInteracted.store(true);
    sh->yieldSeq.fetch_add(1);
    sh->hoverTargetUs = -1;
    if (sh->persistentIntervalUs > 0)
        sh->persistentHoverPending.store(sh->activeHoverTargetUs != INT64_MIN);
}

- (void)cancelPreviewRequest {
    auto sh = _shared;
    if (!sh) return;
    {
        std::lock_guard<std::mutex> g(sh->mtx);
        sh->hoverTargetUs = -1;

        sh->activeHoverTargetUs = INT64_MIN;
        sh->persistentHoverPending.store(false);

        sh->cancelSeq.fetch_add(1);
    }
    sh->cv.notify_one();
}

- (void)shutdown {
    auto sh = _shared;
    if (!sh) return;
    sh->stop.store(true);
    {
        std::lock_guard<std::mutex> g(sh->mtx);
        sh->yieldSeq.fetch_add(1);
    }
    sh->cv.notify_all();
    _shared.reset();
    _encodedByKeyUs.clear();
    _encodedBytes = 0;
    _coveredByKeyUs.clear();
    _persistentBucketKeys.clear();
    _lru.clear();
    _lruIdx.clear();
    _idleProbe = nil;
    _seekBusyProbe = nil;
    _onUpdate = nil;
}

@end
