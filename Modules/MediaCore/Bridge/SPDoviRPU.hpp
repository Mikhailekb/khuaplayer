// KhuaPlayer — Dolby Vision RPU state and native Metal serialization.
// Parsing is provided by the version-matched, small adapter in ffmpeg-min.
#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>
#include "SPDoviUniformLayout.hpp"
#include "../Core/SPDoviBitstream.hpp"

namespace sp {
enum class DoviDisplayGamut { BT709, P3D65, BT2020 };
// ITU-T T.35 prefix of a Dolby Vision AV1 RPU: country code 0xB5, provider
// code 0x003B, provider-oriented code 0x00000800. The EMDF payload follows.
inline constexpr uint8_t kDoviT35Prefix[] = {0xb5, 0, 0x3b, 0, 0, 8, 0};
enum class DoviDisplaySelection { L1, L2, CM4L3, CM4L8, InvalidCM4, UnavailableTarget };

struct DoviReshape {
    bool valid = false;
    struct Comp {
        int numPieces = 0;
        float pivots[dovi_gpu::MaxPieces + 1] = {};
        struct Piece {
            int type = 0;
            float c[3] = {0, 1, 0};
            int mmrOrder = 0;
            float mmrConst = 0;
            float mmrCoef[3][7] = {};
        } pieces[dovi_gpu::MaxPieces];
    } comps[3];
    float yccToRgb[9] = {1, 0.09753f, 0.20520f,
                        1, -0.11389f, 0.13318f,
                        1, 0.03259f, -0.67688f};
    float yccOffset[3] = {0, 0.5f, 0.5f};
    float rgbToLms[9] = {1.042542f, -0.021301f, -0.021301f,
                        -0.021301f, 1.042542f, -0.021301f,
                        -0.021301f, -0.021301f, 1.042542f};
    bool signalFullRange = true;
    float minPqNorm = 0;
    float maxPqNorm = 3696.0f / 4095;
    bool hasLevel1 = false;
    float sceneMinPq = 0, sceneMaxPq = 0, sceneAvgPq = 0;
    // CM4 is a fallback when no compatible L2 target covers the display.
    // Keep the restored measurements separate: L3 must never modify L2's L1.
    bool hasCm4 = false, cm4Usable = false, hasLevel8 = false;
    bool cm4ExactOnly = false; // unlocatable targets prohibit interpolation, not known exact targets
    float cm4MinPq = 0, cm4MaxPq = 0, cm4AvgPq = 0;
    uint16_t activeArea[4] = {}; // L5 left/right/top/bottom, coded BL pixels
    bool needsEnhancement = false; // nontrivial LINEAR_DZ; MEL is false
    struct NLQ { float offset = 0, slope = 0, threshold = 0, max = 0; } nlq[3];
    struct Trim {
        float targetPq = 0, gain = 1, offset = 0, gamma = 1, chroma = 0, saturation = 0;
        float detail = 0; // retained for equality; spatial detail processing is not applied
        // 0=L2, 1..3=L8 BT.709/P3-D65/BT.2020; +4 marks unsupported controls.
        // L8 detail retains the target's minimum PQ code instead of spatial detail.
        int kind = 0;
    } trims[32];
    int numTrims = 0;
};

class DoviParser {
public:
    explicit DoviParser(int profile = 0, int compatibility = 0, int compression = 0);
    ~DoviParser();
    DoviParser(const DoviParser&) = delete;
    DoviParser& operator=(const DoviParser&) = delete;
    void reset();
    enum class Result { Absent, Valid, Invalid, Unsupported, NeedsPictureDecoder };
    Result parse(const uint8_t *data, size_t size, int nalLengthSize, DoviReshape& out);
    // Same, for an access unit the caller already split (doviSplitNals with
    // avc = profile 9), so a dual-layer packet is scanned only once.
    Result parse(const std::vector<DoviNal>& nals, DoviReshape& out);
    // AV1 low-overhead temporal unit. Consume each picture's RPUs in order;
    // select the sole displayed base-spatial picture, including temporal IDs,
    // hidden OBU_FRAMEs and show_existing. Multiple displayed spatial pictures
    // cannot be associated with VT's single packet PTS. NeedsPictureDecoder
    // requests decoder-owned association; it is not a damaged-video verdict.
    Result parseAV1(const uint8_t *data, size_t size, DoviReshape& out);
    void setAV1Config(const uint8_t *extra, size_t size);
    // Decoder-associated Dolby T.35 payload after its six provider bytes.
    // The selected AV1 picture, rather than an ambiguous temporal unit, owns it.
    Result parseAV1EMDF(const uint8_t *data, size_t size, DoviReshape& out);
private:
    int profile_ = 0;
    bool av1SequenceKnown_ = false, av1ReducedStill_ = false;
    std::vector<uint8_t> av1Sequence_;
    bool rememberAV1Sequence(const uint8_t *data, size_t size);
    DoviReshape av1Pending_;
    Result av1PendingResult_ = Result::Absent;
    int av1PendingTemporal_ = -1;
    void *context_ = nullptr;
    std::vector<uint8_t> rbsp_;
    std::vector<DoviNal> nals_;
};

void doviToGpuFloats(const DoviReshape& r, float *out);
// Prefer compatible L2; otherwise select supported L8 targets in the actual
// output gamut, together with restored CM4 L1. Never mix the two families.
// Interpolation stays inside the authored interval; unknown targets fail closed.
DoviDisplaySelection doviSelectDisplayTrims(float *gpu, float targetNits,
                           DoviDisplayGamut gamut = DoviDisplayGamut::BT709);
// Call once on the draw's private snapshot: coded L5 offsets become normalized
// left/right/top/bottom boundaries; invalid rectangles become the full frame.
void doviPrepareActiveArea(float *gpu, size_t width, size_t height);
// Once per fresh frame snapshot: select display trims/peak, then normalize L5.
// Both the main image and comparison image must use this same preparation.
DoviDisplaySelection doviPrepareDisplay(float *gpu, float targetNits,
    DoviDisplayGamut gamut, size_t width, size_t height);
} // namespace sp
