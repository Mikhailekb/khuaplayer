// Immutable frame-local DV data. The base CVPixelBuffer owns both attachments;
// renderer submission retains that buffer, including across asynchronous retry.
#pragma once
#import <CoreVideo/CoreVideo.h>
#include "SPShaderUniforms.h"
#include <cstring>
#include <utility>

static CFStringRef const kSPDoviFrameMetadata = CFSTR("dev.khuaplayer.dovi.metadata.v2");
static CFStringRef const kSPDoviEnhancementFrame = CFSTR("dev.khuaplayer.dovi.enhancement.v1");
// Frame-owned diagnosis, replaced on every decorator output; a constant boolean
// avoids allocating per-frame strings or adding another PTS-indexed queue.
static CFStringRef const kSPDoviMissingEnhancement = CFSTR("dev.khuaplayer.dovi.missing-enhancement.v1");
// Backend inspected metadata on this exact AV1 picture, including absence or
// rejection. Packet-level metadata must not replace this decision.
static CFStringRef const kSPDoviPictureMetadata = CFSTR("dev.khuaplayer.dovi.picture-metadata.v1");
// Synthetic DV pictures have already consumed reshape and (for FEL) residuals.
// Their pixels are limited-range BT.2020 PQ P010; the original immutable RPU
// remains attached solely for display management. Never apply reconstruction twice.
static CFStringRef const kSPDoviReconstructedFrame = CFSTR("dev.khuaplayer.dovi.reconstructed.v1");
static inline bool spDoviFrameIsReconstructed(CVPixelBufferRef buffer) {
    return CVBufferGetAttachment(buffer, kSPDoviReconstructedFrame, nullptr) == kCFBooleanTrue;
}
static inline CFDataRef spDoviFrameMetadataData(CVPixelBufferRef buffer) {
    CFTypeRef value = CVBufferGetAttachment(buffer, kSPDoviFrameMetadata, nullptr);
    if (!value || CFGetTypeID(value) != CFDataGetTypeID() ||
        CFDataGetLength((CFDataRef)value) != sizeof(SPDoviUniforms)) return nullptr;
    return (CFDataRef)value; // borrowed from the retained frame
}
static inline const SPDoviUniforms *spDoviFrameUniforms(CVPixelBufferRef buffer) {
    const auto data = spDoviFrameMetadataData(buffer);
    return data ? reinterpret_cast<const SPDoviUniforms *>(CFDataGetBytePtr(data)) : nullptr;
}
static inline CVPixelBufferRef spDoviEnhancementFrame(CVPixelBufferRef buffer) {
    CFTypeRef value = CVBufferGetAttachment(buffer, kSPDoviEnhancementFrame, nullptr);
    return value && CFGetTypeID(value) == CVPixelBufferGetTypeID()
        ? (CVPixelBufferRef)value : nullptr;
}

// Immutable metadata ownership for decoder caches, PTS maps and temporary
// attachment replacement. Copies retain CFData directly, with no separately
// allocated shared_ptr control block. Only update() creates new bytes.
class SPDoviMetadataBytes {
    CFDataRef bytes_ = nullptr;
public:
    SPDoviMetadataBytes() = default;
    ~SPDoviMetadataBytes() { reset(); }
    SPDoviMetadataBytes(const SPDoviMetadataBytes& other) noexcept
        : bytes_(other.bytes_ ? (CFDataRef)CFRetain(other.bytes_) : nullptr) {}
    SPDoviMetadataBytes(SPDoviMetadataBytes&& other) noexcept
        : bytes_(std::exchange(other.bytes_, nullptr)) {}
    SPDoviMetadataBytes& operator=(SPDoviMetadataBytes other) noexcept {
        std::swap(bytes_, other.bytes_); return *this;
    }
    CFDataRef get() const { return bytes_; }
    explicit operator bool() const { return bytes_ != nullptr; }
    void reset() noexcept {
        if (bytes_) CFRelease(std::exchange(bytes_, nullptr));
    }
    static SPDoviMetadataBytes fromFrame(CVPixelBufferRef frame) {
        SPDoviMetadataBytes result;
        if (auto data = spDoviFrameMetadataData(frame)) result.bytes_ = (CFDataRef)CFRetain(data);
        return result;
    }
    void update(const SPDoviUniforms& gpu) {
        // Compare every field, including L1/NLQ, not just a scene identifier.
        if (bytes_ && !memcmp(CFDataGetBytePtr(bytes_), &gpu, sizeof(gpu))) return;
        reset();
        bytes_ = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(&gpu), sizeof(gpu));
        // Allocation failure leaves an empty verdict, never a stale mapping.
    }
};
static_assert(sizeof(SPDoviMetadataBytes) == sizeof(CFDataRef));

static inline void spDoviPrepareEnhancementSampling(float *gpu, CVPixelBufferRef base,
                                                    CVPixelBufferRef enhancement) {
    gpu[sp::dovi_gpu::ElLumaOffsetX] = gpu[sp::dovi_gpu::ElLumaOffsetY] = 0;
    gpu[sp::dovi_gpu::ElChromaOffsetX] = gpu[sp::dovi_gpu::ElChromaOffsetY] = 0;
    if (!base || !enhancement || CVPixelBufferGetPlaneCount(enhancement) != 2) return;
    const size_t bw = CVPixelBufferGetWidth(base), ew = CVPixelBufferGetWidth(enhancement);
    const size_t eh = CVPixelBufferGetHeight(enhancement);
    if (!bw || !ew || !eh) return;
    if (bw == 2 * ew) gpu[sp::dovi_gpu::ElLumaOffsetX] = 0.5f / float(bw);
    gpu[sp::dovi_gpu::ElChromaOffsetX] = gpu[sp::dovi_gpu::ElLumaOffsetX];
    CFTypeRef top = CVBufferGetAttachment(enhancement, kCVImageBufferChromaLocationTopFieldKey, nullptr);
    CFTypeRef bottom = CVBufferGetAttachment(enhancement, kCVImageBufferChromaLocationBottomFieldKey, nullptr);
    if (!top || CFGetTypeID(top) != CFStringGetTypeID() || (bottom && !CFEqual(top, bottom))) return;
    float x = 0, y = 0;
    if (CFEqual(top, kCVImageBufferChromaLocation_Left)) x = .5f;
    else if (CFEqual(top, kCVImageBufferChromaLocation_TopLeft)) { x = .5f; y = .5f; }
    else if (CFEqual(top, kCVImageBufferChromaLocation_Top)) y = .5f;
    else if (CFEqual(top, kCVImageBufferChromaLocation_BottomLeft)) { x = .5f; y = -.5f; }
    else if (CFEqual(top, kCVImageBufferChromaLocation_Bottom)) y = -.5f;
    // Offsets are in luma-pixel units, then normalized to the EL frame.
    gpu[sp::dovi_gpu::ElChromaOffsetX] += x / float(ew);
    gpu[sp::dovi_gpu::ElChromaOffsetY] = y / float(eh);
}

// Every DV reconstruction samples an EL picture in the two-plane 4:2:0 layout
// the EL decoder produces (NV12/P010). Returns its bit depth, or 0 otherwise.
static inline int spDoviEnhancementBits(CVPixelBufferRef enhancement) {
    if (!enhancement || CVPixelBufferGetPlaneCount(enhancement) != 2) return 0;
    switch (CVPixelBufferGetPixelFormatType(enhancement)) {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return 10;
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return 8;
        default: return 0;
    }
}

// Luma and chroma textures of an EL picture (+1 references). On failure none
// are returned: a FEL frame must then not render as BL-only DV.
static inline bool spDoviCreateEnhancementTextures(CVMetalTextureCacheRef cache,
                                                   CVPixelBufferRef enhancement,
                                                   CVMetalTextureRef textures[2]) {
    textures[0] = textures[1] = nullptr;
    const int bits = spDoviEnhancementBits(enhancement);
    if (!bits) return false;
    for (size_t plane = 0; plane < 2; ++plane) {
        const MTLPixelFormat format = plane == 0
            ? (bits == 10 ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm)
            : (bits == 10 ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm);
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, enhancement, nullptr, format,
            CVPixelBufferGetWidthOfPlane(enhancement, plane),
            CVPixelBufferGetHeightOfPlane(enhancement, plane), plane, &textures[plane]);
    }
    if (textures[0] && textures[1]) return true;
    for (int i = 0; i < 2; ++i) if (textures[i]) CFRelease(std::exchange(textures[i], nullptr));
    return false;
}

// A draw's private copy of a frame's RPU words plus the per-frame sampling
// facts the shader reads: reconstructed pixels, EL depth and EL plane offsets.
static inline void spDoviPrepareDrawSnapshot(SPDoviUniforms& snapshot, const SPDoviUniforms& rpu,
                                             CVPixelBufferRef base, CVPixelBufferRef enhancement,
                                             bool reconstructed) {
    snapshot = rpu;
    snapshot.values[sp::dovi_gpu::Reconstructed] = reconstructed;
    snapshot.values[sp::dovi_gpu::EnhancementTenBit] = spDoviEnhancementBits(enhancement) == 10;
    spDoviPrepareEnhancementSampling(snapshot.values, base, enhancement);
}
