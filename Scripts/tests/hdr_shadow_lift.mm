#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <vector>

namespace {
using Pixel = std::array<float, 4>;
using RGB = std::array<double, 3>;
struct Input { Pixel encoded; Pixel parameters; };
struct Ray { size_t start, count; int component; };
static_assert(sizeof(Pixel) == 16 && sizeof(Input) == 32);
size_t assertions = 0;

void expect(bool condition, const char *description) {
    ++assertions;
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", description);
        std::exit(1);
    }
}

double decode(double x) {
    return x <= .04045 ? x / 12.92 : std::pow((x + .055) / 1.055, 2.4);
}

double encode(double x) {
    return x <= .0031308 ? 12.92 * x : 1.055 * std::pow(x, 1.0 / 2.4) - .055;
}

RGB decoded(const Pixel& pixel) {
    return {decode(pixel[0]), decode(pixel[1]), decode(pixel[2])};
}

// Independent double-precision reference, including the smooth headroom cap.
RGB reference(const Pixel& pixel, bool edr, double peakNits) {
    RGB rgb = decoded(pixel);
    const RGB weights = edr ? RGB{.22897, .69174, .07929} : RGB{.2126, .7152, .0722};
    const double y = rgb[0] * weights[0] + rgb[1] * weights[1] + rgb[2] * weights[2];
    const double maximum = std::max({rgb[0], rgb[1], rgb[2]});
    const double target = std::max(1.0, edr ? peakNits / 100 : 1.0);
    if (y <= 0 || y >= 1 || maximum <= 0 || maximum >= target) {
        return {pixel[0], pixel[1], pixel[2]};
    }
    const double desired = 1 + 4 * (1 - y) * (1 - y) / (1 + 8 * y);
    const double gain = desired / (1 + (desired - 1) * maximum / target);
    return {encode(rgb[0] * gain), encode(rgb[1] * gain), encode(rgb[2] * gain)};
}

id<MTLLibrary> compile(id<MTLDevice> device, NSString *source) {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) std::fprintf(stderr, "%s\n", error.description.UTF8String);
    expect(library != nil, "production shader compiles with Command Line Tools");
    return library;
}

void helperChecks(id<MTLDevice> device, id<MTLLibrary> library) {
    std::vector<Input> input;
    std::vector<Ray> rays;
    auto append = [&](RGB rgb, bool edr, float peak) {
        input.push_back({{float(encode(rgb[0])), float(encode(rgb[1])),
                          float(encode(rgb[2])), 1}, {edr ? 1.f : 0.f, peak, 0, 0}});
    };
    constexpr size_t steps = 20001;
    for (bool edr : {false, true}) {
        for (float peak : {100.f, 656.477f, 1600.f}) {
            const double target = edr ? std::max(1.0, peak / 100.0) : 1.0;
            for (RGB color : {RGB{1, 1, 1}, RGB{0, 0, 1}, RGB{1, 0, 0},
                              RGB{0, 1, 0}, RGB{.4, 1, .02}}) {
                int component = int(std::max_element(color.begin(), color.end()) - color.begin());
                rays.push_back({input.size(), steps, component});
                for (size_t i = 0; i < steps; ++i) {
                    const double scale = target * 1.1 * i / (steps - 1);
                    append({color[0] * scale, color[1] * scale, color[2] * scale}, edr, peak);
                }
            }
        }
    }
    std::mt19937 random(7605);
    std::uniform_real_distribution<double> value(0, 6.56477);
    for (size_t i = 0; i < 25000; ++i) {
        append({value(random), value(random), value(random)}, true, 656.477f);
    }
    const size_t identityStart = input.size();
    for (RGB rgb : {RGB{0, 0, 0}, RGB{1.1, 1.1, 1.1}, RGB{2, 2, 2},
                    RGB{6.8, .01, .01}, RGB{0, 0, 6.8}}) append(rgb, true, 656.477f);

    NSError *error = nil;
    id<MTLFunction> function = [library newFunctionWithName:@"auditHdrShadowLift"];
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    expect(pipeline != nil, "production helper audit pipeline");
    id<MTLBuffer> in = [device newBufferWithBytes:input.data()
                                        length:input.size() * sizeof(Input)
                                       options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [device newBufferWithLength:input.size() * sizeof(Pixel)
                                         options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:in offset:0 atIndex:0];
    [encoder setBuffer:out offset:0 atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(input.size(), 1, 1)
       threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    expect(command.status == MTLCommandBufferStatusCompleted, "helper executes on Metal");
    const auto *result = static_cast<const Pixel *>(out.contents);
    double maxReferenceError = 0, maxRatioError = 0;
    for (size_t i = 0; i < input.size(); ++i) {
        const auto& sample = input[i];
        RGB expected = reference(sample.encoded, sample.parameters[0] > .5, sample.parameters[1]);
        RGB original = decoded(sample.encoded), actual = decoded(result[i]);
        const double target = std::max(1.0, sample.parameters[0] > .5 ? sample.parameters[1] / 100.0 : 1.0);
        const double originalMaximum = std::max({original[0], original[1], original[2]});
        double minimumGain = 1e100, maximumGain = 0;
        for (int c = 0; c < 3; ++c) {
            expect(std::isfinite(result[i][c]), "finite encoded output");
            maxReferenceError = std::max(maxReferenceError, std::abs(result[i][c] - expected[c]));
            expect(actual[c] + 2e-4 >= original[c], "preset never darkens a channel");
            if (originalMaximum <= target - 1e-4) {
                expect(actual[c] <= target + 2e-4, "soft cap preserves headroom");
            }
            if (original[c] > 1e-6) {
                const double gain = actual[c] / original[c];
                minimumGain = std::min(minimumGain, gain);
                maximumGain = std::max(maximumGain, gain);
                expect(gain <= 5.0001, "maximum lift is five times");
            }
        }
        if (maximumGain > 0) maxRatioError = std::max(maxRatioError, maximumGain - minimumGain);
        if (sample.encoded[0] == sample.encoded[1] && sample.encoded[1] == sample.encoded[2]) {
            expect(result[i][0] == result[i][1] && result[i][1] == result[i][2], "neutral remains neutral");
        }
    }
    for (const auto& ray : rays) {
        for (size_t i = 1; i < ray.count; ++i) {
            expect(result[ray.start + i][ray.component] > result[ray.start + i - 1][ray.component],
                   "gray and saturated color rays are strictly monotonic without a hard-cap plateau");
        }
    }
    for (size_t i = identityStart; i < input.size(); ++i) {
        expect(std::memcmp(input[i].encoded.data(), result[i].data(), sizeof(Pixel)) == 0,
               "black, highlights, and channels already above headroom return exact input bytes");
    }
    expect(maxReferenceError < 3e-5, "GPU helper matches independent double-precision reference");
    expect(maxRatioError < 2e-4, "all linear RGB channels receive one color-preserving gain");
    std::printf("Helper: %zu fixtures, max reference error %.9g, max gain-ratio spread %.9g.\n",
                input.size(), maxReferenceError, maxRatioError);
}

struct FragmentRenderer {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLTexture> planes[3], subtitle;
    static constexpr int width = 96, height = 8;

    explicit FragmentRenderer(id<MTLDevice> d) : device(d), queue([d newCommandQueue]) {
        for (int p = 0; p < 3; ++p) {
            auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Unorm
                                                                               width:width height:height mipmapped:NO];
            descriptor.storageMode = MTLStorageModeShared;
            descriptor.usage = MTLTextureUsageShaderRead;
            planes[p] = [device newTextureWithDescriptor:descriptor];
            std::vector<uint16_t> pixels(width * height);
            for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                pixels[y * width + x] = p == 0 ? uint16_t(64 + x * 876 / (width - 1))
                                             : uint16_t(512 + (y - height / 2) * (p == 1 ? 11 : -9));
            }
            [planes[p] replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
                           withBytes:pixels.data() bytesPerRow:width * 2];
        }
        auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                           width:1 height:1 mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        subtitle = [device newTextureWithDescriptor:descriptor];
        const Pixel red = {.5f, 0, 0, .5f};
        [subtitle replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:red.data() bytesPerRow:16];
    }

    std::vector<Pixel> render(id<MTLLibrary> library, bool dovi, int transfer, bool hdr,
                              bool edr, bool enabled, bool manual = false, bool captions = false,
                              MTLPixelFormat format = MTLPixelFormatRGBA32Float) {
        float uniforms[40] = {}, dv[992] = {};
        uniforms[0] = uniforms[2] = width; uniforms[1] = uniforms[3] = height;
        uniforms[4] = 1; uniforms[5] = transfer; uniforms[7] = 10; uniforms[8] = hdr;
        uniforms[9] = 1000; uniforms[10] = 1; uniforms[11] = dovi;
        uniforms[21] = manual ? 1.2f : 1; uniforms[20] = manual ? .03f : 0;
        uniforms[22] = uniforms[23] = 1; uniforms[24] = 656.477f;
        uniforms[25] = edr; uniforms[26] = 1; uniforms[30] = 1; uniforms[33] = enabled;
        dv[126] = dovi; // Motion-reconstructed P010: retain display management, skip RPU reshaping.
        if (captions) { uniforms[14] = width; uniforms[15] = height; uniforms[16] = 1; }
        MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
        int doviConstant = dovi;
        [constants setConstantValue:&doviConstant type:MTLDataTypeInt atIndex:5];
        NSError *error = nil;
        auto vertex = [library newFunctionWithName:@"videoVertex" constantValues:constants error:&error];
        auto fragment = [library newFunctionWithName:@"videoFragment" constantValues:constants error:&error];
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = format;
        auto pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) std::fprintf(stderr, "%s\n", error.description.UTF8String);
        expect(pipeline != nil, "full production fragment pipeline");
        auto textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                  width:width height:height mipmapped:NO];
        textureDescriptor.storageMode = MTLStorageModeShared;
        textureDescriptor.usage = MTLTextureUsageRenderTarget;
        auto output = [device newTextureWithDescriptor:textureDescriptor];
        auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = output;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        auto command = [queue commandBuffer];
        auto encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline];
        [encoder setVertexBytes:uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentBytes:uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentBytes:dv length:sizeof(dv) atIndex:1];
        [encoder setFragmentTexture:planes[0] atIndex:0];
        [encoder setFragmentTexture:planes[1] atIndex:1];
        [encoder setFragmentTexture:subtitle atIndex:2];
        [encoder setFragmentTexture:planes[2] atIndex:3];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        expect(command.status == MTLCommandBufferStatusCompleted, "full fragment executes on Metal");
        std::vector<Pixel> result(width * height);
        if (format == MTLPixelFormatRGBA32Float) {
            [output getBytes:result.data() bytesPerRow:width * sizeof(Pixel)
                  fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        } else {
            std::vector<_Float16> half(width * height * 4);
            [output getBytes:half.data() bytesPerRow:width * 8
                  fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            for (size_t i = 0; i < result.size(); ++i) for (int c = 0; c < 4; ++c) result[i][c] = half[i * 4 + c];
        }
        return result;
    }
};

void fragmentChecks(id<MTLDevice> device, NSString *source, id<MTLLibrary> library) {
    NSString *call = @"out = spHdrShadowLift(out, edrOut, u.uvals[24]);";
    expect([source componentsSeparatedByString:call].count == 2, "exactly one preset call in the production fragment");
    id<MTLLibrary> referenceLibrary = compile(device, [source stringByReplacingOccurrencesOfString:call withString:@"out = out;"]);
    FragmentRenderer renderer(device);
    for (auto format : {MTLPixelFormatRGBA16Float, MTLPixelFormatRGBA32Float}) {
        for (int mode = 0; mode < 5; ++mode) {
            const bool dovi = mode == 3, hdr = mode != 0, edr = mode != 4;
            const int transfer = mode == 2 ? 2 : (hdr ? 1 : 0);
            auto old = renderer.render(referenceLibrary, dovi, transfer, hdr, edr, false, true, true, format);
            auto off = renderer.render(library, dovi, transfer, hdr, edr, false, true, true, format);
            expect(std::memcmp(old.data(), off.data(), old.size() * sizeof(Pixel)) == 0,
                   "flag off preserves full-fragment output bytes for SDR/PQ/HLG/Motion-DV/HDR-to-SDR");
        }
    }
    for (bool edr : {false, true}) {
        auto sdrOff = renderer.render(library, false, 0, false, edr, false);
        auto sdrOn = renderer.render(library, false, 0, false, edr, true);
        expect(std::memcmp(sdrOff.data(), sdrOn.data(), sdrOn.size() * sizeof(Pixel)) == 0,
               "enabling the HDR preset has no effect on SDR content in either output mode");
    }
    auto base = renderer.render(library, false, 1, true, true, false);
    auto lifted = renderer.render(library, false, 1, true, true, true);
    auto adjusted = renderer.render(library, false, 1, true, true, true, true);
    auto captioned = renderer.render(library, false, 1, true, true, true, false, true);
    auto motionBase = renderer.render(library, true, 1, true, true, false);
    auto motion = renderer.render(library, true, 1, true, true, true);
    double maxLiftError = 0, maxManualError = 0, maxCaptionError = 0, maxMotionError = 0;
    double originalPathDifference = 0, liftedPathDifference = 0;
    double wrongOrderDifference = 0, doubleApplicationDifference = 0;
    const RGB subtitleP3 = {encode(.822462), encode(.033194), encode(.017083)};
    for (size_t i = 0; i < base.size(); ++i) {
        RGB once = reference(base[i], true, 656.477f);
        // The two existing decode branches normalize PQ in a different operation
        // order. Test the new effect against each branch's own unmodified output.
        RGB motionOnce = reference(motionBase[i], true, 656.477f);
        Pixel twiceInput = {float(once[0]), float(once[1]), float(once[2]), 1};
        RGB twice = reference(twiceInput, true, 656.477f);
        Pixel manualFirst = base[i];
        for (int c = 0; c < 3; ++c) manualFirst[c] = (manualFirst[c] + .03f - .5f) * 1.2f + .5f;
        RGB wrongOrder = reference(manualFirst, true, 656.477f);
        for (int c = 0; c < 3; ++c) {
            const double expectedManual = std::max(0.0, (once[c] + .03 - .5) * 1.2 + .5);
            maxLiftError = std::max(maxLiftError, std::abs(lifted[i][c] - once[c]));
            maxManualError = std::max(maxManualError, std::abs(adjusted[i][c] - expectedManual));
            maxCaptionError = std::max(maxCaptionError, std::abs(captioned[i][c] - (lifted[i][c] + subtitleP3[c]) * .5));
            maxMotionError = std::max(maxMotionError, std::abs(motionOnce[c] - motion[i][c]));
            originalPathDifference = std::max(originalPathDifference, std::abs(double(base[i][c]) - motionBase[i][c]));
            liftedPathDifference = std::max(liftedPathDifference, std::abs(double(lifted[i][c]) - motion[i][c]));
            wrongOrderDifference = std::max(wrongOrderDifference, std::abs(expectedManual - std::max(0.0, wrongOrder[c])));
            doubleApplicationDifference = std::max(doubleApplicationDifference, std::abs(once[c] - twice[c]));
        }
    }
    std::printf("Fragment: once %.9g, manual %.9g, subtitles %.9g, Motion %.9g.\n",
                maxLiftError, maxManualError, maxCaptionError, maxMotionError);
    std::printf("Existing HDR10/Motion path difference: off %.9g, on %.9g.\n",
                originalPathDifference, liftedPathDifference);
    expect(maxLiftError < 3e-5, "full fragment applies the preset exactly once");
    expect(doubleApplicationDifference > .02, "fixture distinguishes accidental double application");
    expect(maxManualError < 3e-5, "preset precedes manual picture controls");
    expect(wrongOrderDifference > .02, "fixture distinguishes incorrect manual-control ordering");
    expect(maxCaptionError < 3e-5, "subtitles are composited after the preset");
    expect(maxMotionError < 3e-5, "Motion-reconstructed DV receives the preset once after reconstruction");
    for (int transfer : {1, 2}) for (bool edr : {false, true}) {
        auto unmodified = renderer.render(library, false, transfer, true, edr, false);
        auto enabled = renderer.render(library, false, transfer, true, edr, true);
        double maximumError = 0;
        for (size_t i = 0; i < enabled.size(); ++i) {
            RGB expected = reference(unmodified[i], edr, 656.477f);
            for (int c = 0; c < 3; ++c) {
                maximumError = std::max(maximumError, std::abs(enabled[i][c] - expected[c]));
            }
        }
        expect(maximumError < 3e-5, "PQ and HLG use the correct output-gamut weights in EDR and SDR");
    }
}
} // namespace

int main(int argc, char **argv) {
    @autoreleasepool {
        expect(argc == 2, "usage: hdr-shadow-lift-checks Video.metal");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            std::fprintf(stderr, "SKIP: no native Metal device; GPU regression checks were not run.\n");
            return 77;
        }
        NSError *error = nil;
        NSString *source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
        expect(source != nil, "read exact production Video.metal");
        NSString *audit = @"\nstruct HdrAuditInput { float4 encoded; float4 parameters; };\n"
            "kernel void auditHdrShadowLift(device const HdrAuditInput* input [[buffer(0)]], "
            "device float4* output [[buffer(1)]], uint i [[thread_position_in_grid]]) { "
            "output[i] = float4(spHdrShadowLift(input[i].encoded.rgb, "
            "input[i].parameters.x > 0.5, input[i].parameters.y), input[i].encoded.a); }\n";
        id<MTLLibrary> library = compile(device, [source stringByAppendingString:audit]);
        helperChecks(device, library);
        fragmentChecks(device, source, library);
        std::printf("HDR shadow-lift checks passed (%zu assertions) on %s.\n", assertions, device.name.UTF8String);
        return 0;
    }
}
