#pragma once

#import <CoreVideo/CoreVideo.h>
#import "SPPlanarPixelFormat.h"
#import "SPDoviFrame.h"

#include <cstddef>
#include <cstdint>

namespace sp {

struct SPMotionPixelFormatTraits {
    bool supported;
    bool tenBit;
    uint8_t bytesPerSample;
};

// One source of truth for the bi-planar surfaces accepted by the Motion
// pipeline. Keep callers on these traits instead of duplicating fourcc lists:
// range is encoded by the fourcc, while sample width controls CPU diagnostics
// and scene analysis.
inline constexpr SPMotionPixelFormatTraits spMotionPixelFormatTraits(
    OSType format) {
    switch (format) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return {true, false, 1};
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return {true, true, 2};

        case kCVPixelFormatType_420YpCbCr8Planar:
        case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            return {true, false, 1};
        case kSPPixelFormat420Planar16VideoRange:
        case kSPPixelFormat420Planar16FullRange:
            return {true, true, 2};
        default:
            return {false, false, 0};
    }
}

inline constexpr bool spMotionPixelFormatIsSupported(OSType format) {
    return spMotionPixelFormatTraits(format).supported;
}

inline constexpr bool spMotionPixelFormatIsTenBit(OSType format) {
    return spMotionPixelFormatTraits(format).tenBit;
}

// Keep this list shared with midpoint attachment propagation. If a synthetic
// frame inherits an image-description value from A, A and B must first agree
// on that value. CVBufferGetAttachment returns borrowed references, so the
// steady-state comparison allocates nothing.
inline const CFStringRef kMotionStaticImageAttachmentKeys[] = {
    kCVImageBufferCGColorSpaceKey,
    kCVImageBufferCleanApertureKey,
    kCVImageBufferPreferredCleanApertureKey,
    kCVImageBufferFieldCountKey,
    kCVImageBufferFieldDetailKey,
    kCVImageBufferPixelAspectRatioKey,
    kCVImageBufferDisplayDimensionsKey,
    kCVImageBufferGammaLevelKey,
    kCVImageBufferICCProfileKey,
    kCVImageBufferYCbCrMatrixKey,
    kCVImageBufferColorPrimariesKey,
    kCVImageBufferTransferFunctionKey,
    kCVImageBufferChromaLocationTopFieldKey,
    kCVImageBufferChromaLocationBottomFieldKey,
    kCVImageBufferChromaSubsamplingKey,
    kCVImageBufferMasteringDisplayColorVolumeKey,
    kCVImageBufferContentLightLevelInfoKey,
    kCVImageBufferAmbientViewingEnvironmentKey,
};

inline constexpr size_t kMotionStaticImageAttachmentKeyCount =
    sizeof(kMotionStaticImageAttachmentKeys) /
    sizeof(kMotionStaticImageAttachmentKeys[0]);

enum class SPMotionPairCompatibility : uint8_t {
    Compatible = 0,
    InvalidInput,
    SurfaceMismatch,
    UnsupportedChromaSiting,
    StaticImageDescriptionMismatch,
    DynamicImageDescriptionMismatch,
};

inline bool spMotionDoviFrameEligible(CVPixelBufferRef frame) {
    const auto *gpu = spDoviFrameUniforms(frame);
    if (!gpu || gpu->values[sp::dovi_gpu::Valid] != 1.0f || spDoviFrameIsReconstructed(frame)) return false;
    const auto el = spDoviEnhancementFrame(frame);
    if (gpu->values[sp::dovi_gpu::NeedsEnhancement] == 0.0f) return !el;
    return gpu->values[sp::dovi_gpu::NeedsEnhancement] == 1.0f && spDoviEnhancementBits(el) != 0;
}

// Called only after the pair check. The immutable metadata is retained, not
// reserialized; pooled output surfaces must also lose any previous DV/EL data.
inline void spMotionCopyDoviMetadata(CVPixelBufferRef source, CVPixelBufferRef destination) {
    CVBufferRemoveAttachment(destination, kSPDoviFrameMetadata);
    CVBufferRemoveAttachment(destination, kSPDoviEnhancementFrame);
    CVBufferRemoveAttachment(destination, kSPDoviMissingEnhancement);
    CVBufferRemoveAttachment(destination, kSPDoviReconstructedFrame);
    if (!spMotionDoviFrameEligible(source)) return;
    CFTypeRef data = CVBufferCopyAttachment(source, kSPDoviFrameMetadata, nullptr);
    if (data) {
        CVBufferSetAttachment(destination, kSPDoviFrameMetadata, data,
                              kCVAttachmentMode_ShouldNotPropagate);
        CFRelease(data);
    }
}

struct SPMotionChromaSiting {
    // Physical centre of chroma texel (0, 0), expressed in luma-pixel
    // coordinates whose first luma centre is (0.5, 0.5).
    float x = 1.0f;
    float y = 1.0f;
};

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// The retained A/B frames are immutable for the duration of this synchronous
// comparison, so borrowed attachment reads are safe here. CopyAttachment would
// add 2 * key-count retain/release pairs to every active MEMC source pair.
inline bool spMotionAttachmentValuesEqual(CVPixelBufferRef frameA,
                                           CVPixelBufferRef frameB,
                                           CFStringRef key) {
    CFTypeRef valueA = CVBufferGetAttachment(frameA, key, nullptr);
    CFTypeRef valueB = CVBufferGetAttachment(frameB, key, nullptr);
    return valueA == valueB || (valueA && valueB && CFEqual(valueA, valueB));
}

inline bool spMotionFrameChromaSiting(CVPixelBufferRef frame,
                                      SPMotionChromaSiting *sitingOut) {
    if (!frame) return false;
    SPMotionChromaSiting siting{};
    CFTypeRef top = CVBufferGetAttachment(
        frame, kCVImageBufferChromaLocationTopFieldKey, nullptr);
    CFTypeRef bottom = CVBufferGetAttachment(
        frame, kCVImageBufferChromaLocationBottomFieldKey, nullptr);

    // For progressive frames CoreVideo defines the top-field value as the
    // chroma location. A bottom-only tag is ambiguous, while differing top and
    // bottom tags describe field-dependent siting that this progressive MEMC
    // shader must not combine.
    if (!top) {
        if (bottom) return false;
        if (sitingOut) *sitingOut = siting; // established untagged default: centre
        return true;
    }
    if (CFGetTypeID(top) != CFStringGetTypeID() ||
        (bottom && (CFGetTypeID(bottom) != CFStringGetTypeID() ||
                    !CFEqual(top, bottom)))) {
        return false;
    }

    if (CFEqual(top, kCVImageBufferChromaLocation_Center)) {
        siting = {1.0f, 1.0f};
    } else if (CFEqual(top, kCVImageBufferChromaLocation_Left)) {
        siting = {0.5f, 1.0f};
    } else if (CFEqual(top, kCVImageBufferChromaLocation_TopLeft)) {
        siting = {0.5f, 0.5f};
    } else if (CFEqual(top, kCVImageBufferChromaLocation_Top)) {
        siting = {1.0f, 0.5f};
    } else if (CFEqual(top, kCVImageBufferChromaLocation_BottomLeft)) {
        siting = {0.5f, 1.5f};
    } else if (CFEqual(top, kCVImageBufferChromaLocation_Bottom)) {
        siting = {1.0f, 1.5f};
    } else {
        // DV420 alternates Cb/Cr siting by field and cannot be represented by
        // one offset. Unknown future values also fail closed.
        return false;
    }
    if (sitingOut) *sitingOut = siting;
    return true;
}

inline bool spMotionFrameHasSupportedChromaSiting(CVPixelBufferRef frame) {
    return spMotionFrameChromaSiting(frame, nullptr);
}
#pragma clang diagnostic pop

inline SPMotionPairCompatibility spMotionPairCompatibility(
    CVPixelBufferRef frameA, CVPixelBufferRef frameB, bool checkDoviMetadata = true) {
    if (!frameA || !frameB) return SPMotionPairCompatibility::InvalidInput;

    // The generator knows its stream type. Other callers retain the safe
    // default of inspecting both frames, including ordinary/DV transitions.
    if (checkDoviMetadata) {
        const bool doviA = spDoviFrameUniforms(frameA) != nullptr;
        const bool doviB = spDoviFrameUniforms(frameB) != nullptr;
        if ((doviA || doviB) &&
            (!spMotionDoviFrameEligible(frameA) || !spMotionDoviFrameEligible(frameB) ||
             !spMotionAttachmentValuesEqual(frameA, frameB, kSPDoviFrameMetadata)))
            return SPMotionPairCompatibility::DynamicImageDescriptionMismatch;
    }

    // Pixel format is the range carrier for every currently supported NV12 /
    // P010 variant, so this comparison also prevents full/video-range pairs.
    if (CVPixelBufferGetWidth(frameA) != CVPixelBufferGetWidth(frameB) ||
        CVPixelBufferGetHeight(frameA) != CVPixelBufferGetHeight(frameB) ||
        CVPixelBufferGetPixelFormatType(frameA) !=
            CVPixelBufferGetPixelFormatType(frameB) ||
        CVPixelBufferGetPlaneCount(frameA) != CVPixelBufferGetPlaneCount(frameB) ||
        CVImageBufferIsFlipped(frameA) != CVImageBufferIsFlipped(frameB)) {
        return SPMotionPairCompatibility::SurfaceMismatch;
    }

    if (!spMotionFrameHasSupportedChromaSiting(frameA) ||
        !spMotionFrameHasSupportedChromaSiting(frameB)) {
        return SPMotionPairCompatibility::UnsupportedChromaSiting;
    }

    for (size_t i = 0; i < kMotionStaticImageAttachmentKeyCount; ++i) {
        if (!spMotionAttachmentValuesEqual(
                frameA, frameB, kMotionStaticImageAttachmentKeys[i])) {
            return SPMotionPairCompatibility::StaticImageDescriptionMismatch;
        }
    }
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 140200
    if (__builtin_available(macOS 14.2, *)) {
        if (!spMotionAttachmentValuesEqual(
                frameA, frameB, kCVImageBufferLogTransferFunctionKey)) {
            return SPMotionPairCompatibility::StaticImageDescriptionMismatch;
        }
    }
#endif
    return SPMotionPairCompatibility::Compatible;
}

} // namespace sp
