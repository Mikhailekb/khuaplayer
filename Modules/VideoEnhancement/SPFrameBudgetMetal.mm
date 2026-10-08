#import "SPFrameBudgetMetal.h"
#import "SPFrameBudgetPlanner.hpp"
#import "SPMotionFrameCompatibility.hpp"
#import "SPPlanarPixelFormat.h"

#include <algorithm>
#include <mutex>
#include <simd/simd.h>
#include <vector>

struct SPBudgetColorCPU {
    float yScale, yOffset, cScale, cOffset;
    float kr, kb;
    uint32_t tenBit;
    uint32_t pad;
};
static_assert(sizeof(SPBudgetColorCPU) == 32, "SPBudgetColor layout");
static_assert(sizeof(SPBudgetBlockResult) == 32, "SPBudgetBlockResult layout");

static NSError *SPBudgetMetalError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"dev.khuaplayer.FrameBudgetMetal" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

@implementation SPFrameBudgetMetal {
    uint32_t _blocksX, _blocksY;
    id<MTLComputePipelineState> _downsample;
    id<MTLComputePipelineState> _blockMatch;
    id<MTLComputePipelineState> _toRGBA;
    id<MTLComputePipelineState> _toRGBAPlanar;
    id<MTLComputePipelineState> _fromRGBA;
    id<MTLComputePipelineState> _doviToRGBA;
    CVMetalTextureCacheRef _textureCache;
    std::mutex _cacheMtx;
    SPBudgetColorCPU _color;
    SPBudgetColorCPU _colorOut;
    float _lumaScale;
    BOOL _matrixAdopted;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                library:(nullable id<MTLLibrary>)library
                                  width:(uint32_t)width
                                 height:(uint32_t)height
                            pixelFormat:(OSType)pixelFormat
                                  error:(NSError **)error {
    if (!(self = [super init])) return nil;
    if (!device || width < 16 || height < 16) {
        if (error) *error = SPBudgetMetalError(1, @"invalid configuration");
        return nil;
    }
    if (!sp::spMotionPixelFormatIsSupported(pixelFormat)) {
        if (error) *error = SPBudgetMetalError(2, @"unsupported pixel format");
        return nil;
    }
    _device = device;
    _width = width;
    _height = height;
    _pixelFormat = pixelFormat;
    _outputPixelFormat = spPixelFormatBiPlanarEquivalent(pixelFormat);
    _tenBit = sp::spMotionPixelFormatIsTenBit(pixelFormat);
    _planarInput = spPixelFormatIsPlanar3(pixelFormat);
    if (!library) {
        NSURL *url = [[NSBundle bundleForClass:self.class] URLForResource:@"FrameBudget" withExtension:@"metallib"];
        NSError *libError = nil;
        if (url) library = [device newLibraryWithURL:url error:&libError];
        if (!library) {
            if (error) *error = SPBudgetMetalError(3, [NSString stringWithFormat:@"FrameBudget.metallib: %@",
                                                        libError.localizedDescription ?: @"not found"]);
            return nil;
        }
    }
    _commandQueue = [device newCommandQueue];
    _commandQueue.label = @"dev.khuaplayer.frame-budget";
    auto pso = [&](NSString *name, NSError **e) -> id<MTLComputePipelineState> {
        id<MTLFunction> fn = [library newFunctionWithName:name];
        return fn ? [device newComputePipelineStateWithFunction:fn error:e] : nil;
    };
    NSError *psoError = nil;
    _downsample = pso(@"spBudgetDownsampleLuma", &psoError);
    _blockMatch = _downsample ? pso(@"spBudgetBlockMatch", &psoError) : nil;
    _toRGBA = _blockMatch ? pso(@"spBudgetToRGBA", &psoError) : nil;
    _toRGBAPlanar = _toRGBA ? pso(@"spBudgetToRGBAPlanar", &psoError) : nil;
    _fromRGBA = _toRGBAPlanar ? pso(@"spBudgetFromRGBA", &psoError) : nil;
    if (!_fromRGBA) {
        if (error) *error = SPBudgetMetalError(4, psoError.localizedDescription ?: @"pipeline");
        return nil;
    }
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &_textureCache) != kCVReturnSuccess) {
        if (error) *error = SPBudgetMetalError(5, @"texture cache");
        return nil;
    }

    _probeFactor = std::max<uint32_t>(2, (uint32_t)llround((double)width / 240.0));
    _probeWidth = std::max<uint32_t>(8, (width + _probeFactor - 1) / _probeFactor);
    _probeHeight = std::max<uint32_t>(8, (height + _probeFactor - 1) / _probeFactor);
    _blocksX = _probeWidth / 4;
    _blocksY = _probeHeight / 4;

    const bool fullRange = spPixelFormatIsFullRange(pixelFormat);
    if (_tenBit) {

        const float codeScale = _planarInput ? 65535.0f : 65535.0f / 64.0f;
        if (fullRange) {
            _color.yScale = codeScale / 1023.0f; _color.yOffset = 0.0f;
            _color.cScale = codeScale / 1023.0f; _color.cOffset = -512.0f / 1023.0f;
        } else {
            _color.yScale = codeScale / 876.0f; _color.yOffset = -64.0f / 876.0f;
            _color.cScale = codeScale / 896.0f; _color.cOffset = -512.0f / 896.0f;
        }
    } else {
        if (fullRange) {
            _color.yScale = 1.0f; _color.yOffset = 0.0f;
            _color.cScale = 1.0f; _color.cOffset = -128.0f / 255.0f;
        } else {
            _color.yScale = 255.0f / 219.0f; _color.yOffset = -16.0f / 219.0f;
            _color.cScale = 255.0f / 224.0f; _color.cOffset = -128.0f / 224.0f;
        }
    }
    _color.tenBit = _tenBit ? 1 : 0;
    if (_tenBit) { _color.kr = 0.2627f; _color.kb = 0.0593f; }
    else if (height >= 600) { _color.kr = 0.2126f; _color.kb = 0.0722f; }  // 709
    else { _color.kr = 0.299f; _color.kb = 0.114f; }

    _colorOut = _color;
    if (_tenBit && _planarInput) {

        _colorOut.yScale = _color.yScale / 64.0f;
        _colorOut.cScale = _color.cScale / 64.0f;
    }

    _lumaScale = (_tenBit && _planarInput) ? 64.0f : 1.0f;
    return self;
}

- (void)dealloc {
    if (_textureCache) { CFRelease(_textureCache); _textureCache = nullptr; }
}

- (void)adoptColorMatrixFromFrame:(CVPixelBufferRef)frame {
    if (_matrixAdopted || !frame) return;
    _matrixAdopted = YES;
    CFTypeRef matrix = CVBufferCopyAttachment(frame, kCVImageBufferYCbCrMatrixKey, nullptr);
    if (!matrix) return;
    if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)) { _color.kr = 0.2627f; _color.kb = 0.0593f; }
    else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) { _color.kr = 0.2126f; _color.kb = 0.0722f; }
    else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) ||
             CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995)) { _color.kr = 0.299f; _color.kb = 0.114f; }
    CFRelease(matrix);
    if (!_doviReconstruction) {
        _colorOut.kr = _color.kr;
        _colorOut.kb = _color.kb;
    }
}

- (BOOL)enableDoviReconstructionWithError:(NSError **)error {
    if (_doviReconstruction) return YES;
    NSURL *url = [[NSBundle bundleForClass:self.class] URLForResource:@"default" withExtension:@"metallib"];
    id<MTLLibrary> library = url ? [_device newLibraryWithURL:url error:error] : nil;
    id<MTLFunction> fn = [library newFunctionWithName:@"doviFrameToRGBA"];
    _doviToRGBA = fn ? [_device newComputePipelineStateWithFunction:fn error:error] : nil;
    if (!_doviToRGBA) {
        if (error && !*error) *error = SPBudgetMetalError(6, @"DV reconstruction pipeline");
        return NO;
    }
    _doviReconstruction = YES;
    _outputPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    _colorOut = {65535.f/(64.f*876.f), -64.f/876.f,
                 65535.f/(64.f*896.f), -512.f/896.f, .2627f, .0593f, 1, 0};
    return YES;
}

#pragma mark - Textures

- (nullable id<MTLTexture>)textureForPlane:(size_t)plane
                                   ofFrame:(CVPixelBufferRef)frame
                                    format:(MTLPixelFormat)format
                                    owners:(NSMutableArray *)owners {
    CVMetalTextureRef tex = nullptr;
    const size_t w = CVPixelBufferGetPlaneCount(frame) > 0 ? CVPixelBufferGetWidthOfPlane(frame, plane) : CVPixelBufferGetWidth(frame);
    const size_t h = CVPixelBufferGetPlaneCount(frame) > 0 ? CVPixelBufferGetHeightOfPlane(frame, plane) : CVPixelBufferGetHeight(frame);
    CVReturn r;
    {
        std::lock_guard<std::mutex> lock(_cacheMtx);
        r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, frame, nil, format,
                                                      w, h, plane, &tex);
    }
    if (r != kCVReturnSuccess || !tex) return nil;
    id<MTLTexture> mtl = CVMetalTextureGetTexture(tex);
    [owners addObject:CFBridgingRelease(tex)];
    return mtl;
}

- (id<MTLTexture>)newProbeTexture {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                 width:_probeWidth
                                                                                height:_probeHeight
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    return [_device newTextureWithDescriptor:d];
}

- (id<MTLBuffer>)newBlockResultBuffer {
    return [_device newBufferWithLength:sizeof(SPBudgetBlockResult) * _blocksX * _blocksY
                                options:MTLResourceStorageModeShared];
}

- (BOOL)encodeDownsampleOfFrame:(CVPixelBufferRef)frame
                           into:(id<MTLTexture>)probeTex
                  commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                         owners:(NSMutableArray *)owners {
    id<MTLTexture> luma = [self textureForPlane:0 ofFrame:frame
                                         format:_tenBit ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm
                                         owners:owners];
    if (!luma) return NO;
    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:_downsample];
    [enc setTexture:luma atIndex:0];
    [enc setTexture:probeTex atIndex:1];
    uint32_t factor = _probeFactor;
    [enc setBytes:&factor length:sizeof(factor) atIndex:0];
    float lumaScale = _lumaScale;
    [enc setBytes:&lumaScale length:sizeof(lumaScale) atIndex:1];
    [enc dispatchThreads:MTLSizeMake(_probeWidth, _probeHeight, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [enc endEncoding];
    return YES;
}

- (void)encodeBlockMatchFrom:(id<MTLTexture>)probeA
                          to:(id<MTLTexture>)probeB
                     results:(id<MTLBuffer>)results
               commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:_blockMatch];
    [enc setTexture:probeA atIndex:0];
    [enc setTexture:probeB atIndex:1];
    [enc setBuffer:results offset:0 atIndex:0];
    simd_uint2 blocks = simd_make_uint2(_blocksX, _blocksY);
    [enc setBytes:&blocks length:sizeof(blocks) atIndex:1];
    [enc dispatchThreads:MTLSizeMake(_blocksX, _blocksY, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [enc endEncoding];
}

- (SPBudgetProbeSummary)summarizeBlockResults:(id<MTLBuffer>)results {
    SPBudgetProbeSummary s = {};
    if (!results) return s;
    const auto *r = (const SPBudgetBlockResult *)results.contents;
    const size_t n = (size_t)_blocksX * _blocksY;

    const float flatTau = 1.5f / 255.0f, unmatchedTau = 14.0f / 255.0f;
    std::vector<float> motions, ratios;
    motions.reserve(n); ratios.reserve(n);
    size_t textured = 0, moving = 0, unmatched = 0, matched = 0, coherent = 0;
    float diffSum = 0.0f;
    const float px1080 = (float)_probeFactor * 1920.0f / (float)_width;
    const int bx = (int)_blocksX, by = (int)_blocksY;
    auto texturedAt = [&](int x, int y) { return r[(size_t)y * bx + x].texture >= flatTau; };
    for (size_t i = 0; i < n; ++i) {
        diffSum += fabsf(r[i].meanA - r[i].meanB);
        if (r[i].texture < flatTau) continue;
        textured++;
        ratios.push_back(r[i].sadBest / std::max(r[i].texture, 1.0f / 255.0f));
        if (r[i].sadBest > unmatchedTau) { unmatched++; continue; }
        matched++;

        const int x = (int)(i % (size_t)bx), y = (int)(i / (size_t)bx);
        int agree = 0, neighbors = 0;
        const int nx[4] = {x - 1, x + 1, x, x}, ny[4] = {y, y, y - 1, y + 1};
        for (int k = 0; k < 4; ++k) {
            if (nx[k] < 0 || ny[k] < 0 || nx[k] >= bx || ny[k] >= by || !texturedAt(nx[k], ny[k])) continue;
            const SPBudgetBlockResult &q = r[(size_t)ny[k] * bx + nx[k]];
            if (q.sadBest > unmatchedTau) { neighbors++; continue; }
            neighbors++;
            if (fabsf(q.dx - r[i].dx) + fabsf(q.dy - r[i].dy) <= 1.5f) agree++;
        }
        if (neighbors == 0 || agree * 2 >= std::min(neighbors, 4) + (neighbors >= 2 ? 0 : 1)) coherent++;
        const float mag = sqrtf(r[i].dx * r[i].dx + r[i].dy * r[i].dy);
        if (mag >= 1.0f && r[i].sadBest < 0.6f * r[i].sadZero) {
            moving++;
            motions.push_back(mag * px1080);
        }
    }
    s.valid = YES;
    s.blocks = (uint32_t)textured;
    s.meanAbsDiff = n ? diffSum / (float)n : 0.0f;
    if (textured == 0) return s;
    s.unmatchedFraction = (float)unmatched / (float)textured;
    s.movingFraction = (float)moving / (float)textured;
    s.coherence = matched ? (float)coherent / (float)matched : 0.0f;
    std::nth_element(ratios.begin(), ratios.begin() + ratios.size() / 2, ratios.end());
    s.residualRatio = ratios[ratios.size() / 2];

    s.cut = s.unmatchedFraction > 0.5f || s.meanAbsDiff > 0.25f ||
            (s.coherence < 0.45f && s.residualRatio > 0.8f);
    if (s.cut) return s;
    if (moving == 0) return s;
    std::nth_element(motions.begin(), motions.begin() + motions.size() / 2, motions.end());
    s.motionPx1080 = motions[motions.size() / 2];

    s.benefit = s.movingFraction * sp::spBudgetMotionBenefit(s.motionPx1080) * (0.5f + 0.5f * s.coherence);
    return s;
}

#pragma mark - Color conversion

- (BOOL)encodeConvertFrame:(CVPixelBufferRef)frame
                    toRGBA:(CVPixelBufferRef)rgba
             commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    owners:(NSMutableArray *)owners {
    const MTLPixelFormat lumaFmt = _tenBit ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm;
    const bool planar = spPixelFormatIsPlanar3(CVPixelBufferGetPixelFormatType(frame)) &&
                        CVPixelBufferGetPlaneCount(frame) == 3;
    id<MTLTexture> luma = [self textureForPlane:0 ofFrame:frame format:lumaFmt owners:owners];
    id<MTLTexture> chroma = [self textureForPlane:1 ofFrame:frame
                                           format:planar ? lumaFmt
                                                         : (_tenBit ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm)
                                           owners:owners];
    id<MTLTexture> chromaV = planar ? [self textureForPlane:2 ofFrame:frame format:lumaFmt owners:owners] : nil;
    id<MTLTexture> out = [self textureForPlane:0 ofFrame:rgba format:MTLPixelFormatRGBA16Float owners:owners];
    if (!luma || !chroma || !out || (planar && !chromaV)) return NO;
    if (_doviReconstruction) {
        if (!sp::spMotionDoviFrameEligible(frame)) return NO;
        // Eligibility guarantees an EL exactly when the RPU needs one.
        CVPixelBufferRef el = spDoviEnhancementFrame(frame);
        SPDoviUniforms snapshot;
        spDoviPrepareDrawSnapshot(snapshot, *spDoviFrameUniforms(frame), frame, el, false);
        id<MTLTexture> elY = luma, elUV = chroma;
        if (el) {
            const bool el10 = spDoviEnhancementBits(el) == 10;
            elY = [self textureForPlane:0 ofFrame:el format:el10 ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm owners:owners];
            elUV = [self textureForPlane:1 ofFrame:el format:el10 ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm owners:owners];
            if (!elY || !elUV) return NO;
        }
        id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
        if (!enc) return NO;
        [enc setComputePipelineState:_doviToRGBA];
        [enc setTexture:luma atIndex:0]; [enc setTexture:chroma atIndex:1];
        [enc setTexture:elY atIndex:2]; [enc setTexture:elUV atIndex:3];
        [enc setTexture:chromaV ?: chroma atIndex:4]; [enc setTexture:out atIndex:5];
        const int32_t meta[4] = {_tenBit ? 10 : 8, (int32_t)out.width, (int32_t)out.height, planar};
        [enc setBytes:&snapshot length:sizeof(snapshot) atIndex:0];
        [enc setBytes:meta length:sizeof(meta) atIndex:1];
        [enc dispatchThreads:MTLSizeMake(out.width, out.height, 1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
        [enc endEncoding];
        return YES;
    }
    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:planar ? _toRGBAPlanar : _toRGBA];
    [enc setTexture:luma atIndex:0];
    [enc setTexture:chroma atIndex:1];
    [enc setTexture:out atIndex:2];
    if (planar) [enc setTexture:chromaV atIndex:3];
    [enc setBytes:&_color length:sizeof(_color) atIndex:0];
    [enc dispatchThreads:MTLSizeMake(out.width, out.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [enc endEncoding];
    return YES;
}

- (BOOL)encodeConvertRGBA:(CVPixelBufferRef)rgba
                  toFrame:(CVPixelBufferRef)frame
            commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                   owners:(NSMutableArray *)owners {
    id<MTLTexture> in = [self textureForPlane:0 ofFrame:rgba format:MTLPixelFormatRGBA16Float owners:owners];
    id<MTLTexture> luma = [self textureForPlane:0 ofFrame:frame
                                         format:(_tenBit || _doviReconstruction) ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm
                                         owners:owners];
    id<MTLTexture> chroma = [self textureForPlane:1 ofFrame:frame
                                           format:(_tenBit || _doviReconstruction) ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm
                                           owners:owners];
    if (!in || !luma || !chroma) return NO;
    id<MTLComputeCommandEncoder> enc = [commandBuffer computeCommandEncoder];
    [enc setComputePipelineState:_fromRGBA];
    [enc setTexture:in atIndex:0];
    [enc setTexture:luma atIndex:1];
    [enc setTexture:chroma atIndex:2];
    [enc setBytes:&_colorOut length:sizeof(_colorOut) atIndex:0];
    [enc dispatchThreads:MTLSizeMake(chroma.width, chroma.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [enc endEncoding];
    return YES;
}

@end
