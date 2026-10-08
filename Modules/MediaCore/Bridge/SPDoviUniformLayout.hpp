// CPU names for the stable float-array ABI consumed by Video.metal.
// No runtime initialization. Video.metal declares the same enum and strides
// (it is compiled from embedded source and cannot include this header);
// Tests/test_shader_abi.py requires both declarations to match exactly. Test
// oracles keep literal offsets so a coordinated drift still fails.
#pragma once

namespace sp::dovi_gpu {
inline constexpr int FloatCount = 992;
inline constexpr int MaxPieces = 8;
inline constexpr int MaxTrims = 32;
inline constexpr int TrimStride = 7;

enum Offset : int {
    YccToRgb = 0, YccOffset = 9, RgbToLms = 12,
    MinPq = 21, MaxPq = 22, FullRange = 23, HasCurves = 24,
    ActiveLeft = 25, ActiveRight = 26, ActiveTop = 27,
    Components = 28, Mmr = 160,
    // Reserved component-header words; these must never overlap coefficients.
    ElLumaOffsetX = 38, ElLumaOffsetY = 39,
    ElChromaOffsetX = 82, ElChromaOffsetY = 83,
    Reconstructed = 126, PublicCurveEnabled = 127,
    // Reserved final word of successive MMR records.
    PublicCurveC1 = 183, PublicCurveC2 = 207, PublicCurveC3 = 231,
    PublicCurveSourcePeak = 255, PublicCurveBlack = 279,
    // Per-component NLQ output bound (vdr_in_max), in the same final words.
    NlqMaxY = 303, NlqMaxCb = 327, NlqMaxCr = 351,
    Valid = 736, NeedsEnhancement = 737, HasLevel1 = 738, EnhancementTenBit = 739,
    Nlq = 740, ActiveBottom = 749,
    SceneMinPq = 750, SceneMaxPq = 751, SceneAvgPq = 752,
    SdrInHdrLayer = 753, TrimCount = 754, TrimEnabled = 755, TrimValues = 756,
    // Selected L2/L8 trim: slope, offset, power, chroma weight, saturation gain.
    TrimSlope = 756, TrimOffset = 757, TrimPower = 758, TrimChroma = 759, TrimSaturation = 760,
    Cm4Status = 761, Cm4MinPq = 762, Cm4MaxPq = 763, Cm4AvgPq = 764,
    Cm4Selected = 765, HasLevel8 = 766, Cm4ExactOnly = 767, TrimTable = 768,
};
inline constexpr int ComponentStride = 44;
inline constexpr int PieceOffset = 12, PieceStride = 4, MmrStride = 24;
// Per-component NLQ record at Nlq + c * NlqStride: offset, slope, threshold.
inline constexpr int NlqStride = 3;
inline constexpr int TrimKindScale = 8192;

static_assert(Components + 3 * ComponentStride == Mmr);
static_assert(Mmr + 3 * MaxPieces * MmrStride == Valid);
static_assert(Nlq + 3 * NlqStride == ActiveBottom);
static_assert(NlqMaxY == Mmr + 5 * MmrStride + 23 && NlqMaxCb == NlqMaxY + MmrStride &&
              NlqMaxCr == NlqMaxCb + MmrStride);
static_assert(TrimValues + 5 == Cm4Status);
static_assert(TrimTable + MaxTrims * TrimStride == FloatCount);
static_assert(FloatCount * sizeof(float) == 3968);
static_assert(FloatCount * sizeof(float) < 4096);
} // namespace sp::dovi_gpu
