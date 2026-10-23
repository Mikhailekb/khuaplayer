#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float uvals[40];
};
static_assert(sizeof(Uniforms) == 160, "CPU Uniforms size mismatch");
static_assert(alignof(Uniforms) == 4, "CPU Uniforms alignment mismatch");
static_assert(__builtin_offsetof(Uniforms, uvals) == 0,
              "CPU Uniforms field offset mismatch");

namespace dovi_gpu {
enum Offset : int {
    YccToRgb = 0, YccOffset = 9, RgbToLms = 12,
    MinPq = 21, MaxPq = 22, FullRange = 23, HasCurves = 24,
    ActiveLeft = 25, ActiveRight = 26, ActiveTop = 27,
    Components = 28, Mmr = 160,
    ElLumaOffsetX = 38, ElLumaOffsetY = 39,
    ElChromaOffsetX = 82, ElChromaOffsetY = 83,
    Reconstructed = 126, PublicCurveEnabled = 127,
    PublicCurveC1 = 183, PublicCurveC2 = 207, PublicCurveC3 = 231,
    PublicCurveSourcePeak = 255, PublicCurveBlack = 279,
    NlqMaxY = 303, NlqMaxCb = 327, NlqMaxCr = 351,
    Valid = 736, NeedsEnhancement = 737, HasLevel1 = 738, EnhancementTenBit = 739,
    Nlq = 740, ActiveBottom = 749,
    SceneMinPq = 750, SceneMaxPq = 751, SceneAvgPq = 752,
    SdrInHdrLayer = 753, TrimCount = 754, TrimEnabled = 755, TrimValues = 756,
    TrimSlope = 756, TrimOffset = 757, TrimPower = 758, TrimChroma = 759, TrimSaturation = 760,
    Cm4Status = 761, Cm4MinPq = 762, Cm4MaxPq = 763, Cm4AvgPq = 764,
    Cm4Selected = 765, HasLevel8 = 766, Cm4ExactOnly = 767, TrimTable = 768,
};
constant int FloatCount = 992;
constant int MaxPieces = 8;
constant int ComponentStride = 44;
constant int PieceOffset = 12;
constant int PieceStride = 4;
constant int MmrStride = 24;
constant int NlqStride = 3;
} // namespace dovi_gpu
struct DoviUniforms {
    float v[992];
};
static_assert(sizeof(DoviUniforms) == 3968, "CPU DoviUniforms size mismatch");
static_assert(sizeof(DoviUniforms) == dovi_gpu::FloatCount * sizeof(float), "DoviUniforms bound");
static_assert(alignof(DoviUniforms) == 4,
              "CPU DoviUniforms alignment mismatch");
static_assert(__builtin_offsetof(DoviUniforms, v) == 0,
              "CPU DoviUniforms field offset mismatch");
struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

constant int fcPrimaries  [[function_constant(0)]];
constant int fcTransfer   [[function_constant(1)]]; // 0=709/2020 SDR 1=PQ 2=HLG 3=linear 4=sRGB 5=γ2.2 6=γ2.8 7=ST428(γ2.6)
constant int fcBits       [[function_constant(2)]];
constant int fcRange      [[function_constant(3)]]; // 1=full
constant int fcHdr        [[function_constant(4)]];
constant int fcDovi       [[function_constant(5)]];
constant int fcOutputMode [[function_constant(6)]];
constant int fcSourceGamut [[function_constant(7)]];
constant int fcPlanar     [[function_constant(8)]];
constant int fcSdrBoost   [[function_constant(9)]];
constant int fcSdrInHdrLayer [[function_constant(10)]];
constant bool kSpec = is_function_constant_defined(fcPrimaries);

#pragma mark - Full-screen triangle

vertex VertexOut videoVertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2)); // 0..2
    pos = pos * 2.0 - 1.0;

    float sar = (u.uvals[10] > 0.01) ? u.uvals[10] : 1.0;
    float aspectV = (u.uvals[0] > 0 && u.uvals[1] > 0) ? (u.uvals[0] * sar) / u.uvals[1] : 16.0 / 9.0;

    float forced = u.uvals[27];
    if (forced > 0.01) aspectV = forced;
    float aspectP = (u.uvals[2] > 0 && u.uvals[3] > 0) ? u.uvals[2] / u.uvals[3] : aspectV;

    int mode = int(u.uvals[17]);
    int rot = int(u.uvals[18]);
    int mirror = int(u.uvals[19]);

    float aEff = (rot == 1 || rot == 3) ? 1.0 / aspectV : aspectV;

    float sx = 1.0, sy = 1.0;
    if (mode == 4) {

        if (aEff > aspectP) { sx = aEff / aspectP; }
        else { sy = aspectP / aEff; }
    } else {

        if (aEff > aspectP) { sy = aspectP / aEff; }
        else { sx = aEff / aspectP; }
    }

    float2 q = pos;
    if (mirror == 1) q.x = -q.x;
    else if (mirror == 2) q.y = -q.y;
    q.x /= sx;
    q.y /= sy;
    if (rot == 1) { q = float2(q.y, -q.x); }
    else if (rot == 2) { q = -q; }
    else if (rot == 3) { q = float2(-q.y, q.x); }

    VertexOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
    return out;
}

#pragma mark - Color math

float eotfSRGB(float c);
float eotfCoreMediaGamma(float c, float gamma) {
    return max(pow(c, gamma), c / 16.0);
}

float spSdrTierGamma(int transfer) {
    return (transfer == 5) ? 2.2 : (transfer == 6) ? 2.8 : (transfer == 7) ? 2.6 : 1.9609375;
}
float3 eotfSdrTier(int transfer, float3 c) {
    if (transfer == 4) return float3(eotfSRGB(c.r), eotfSRGB(c.g), eotfSRGB(c.b));
    if (transfer == 3) return c;
    const float g = spSdrTierGamma(transfer);
    return float3(eotfCoreMediaGamma(c.r, g), eotfCoreMediaGamma(c.g, g), eotfCoreMediaGamma(c.b, g));
}
float oetfSRGB(float c);

float3 oetfSdrTier(int transfer, float3 l) {
    if (transfer == 4) return float3(oetfSRGB(l.r), oetfSRGB(l.g), oetfSRGB(l.b));
    if (transfer == 3) return l;
    const float g = spSdrTierGamma(transfer);
    return min(pow(max(l, float3(0.0)), float3(1.0 / g)), 16.0 * l);
}

float eotfPQ(float c) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    float cp = pow(c, 1.0 / m2);
    float num = max(cp - c1, 0.0);
    float den = c2 - c3 * cp;
    return pow(num / den, 1.0 / m1);
}

float eotfHLG(float c) {
    const float a = 0.17883277;
    const float b = 1.0 - 4.0 * a;
    const float c0 = 0.5 - a * log(4.0 * a);
    return (c <= 0.5) ? c * c / 3.0 : (exp((c - c0) / a) + b) / 12.0;
}

// Convert the post-PQ, post-RPU-crosstalk LMS signal to linear BT.2020.
// Dolby metadata's rgb_to_lms_matrix already carries the stream-specific
// crosstalk transform, so this final Hunt-Pointer-Estevez inverse must not
// apply the 4% ICtCp crosstalk a second time.
static float3 spDoviHpeLmsToBt2020(float3 lms) {
    return float3(
         3.0644187900 * lms.x - 2.1659767600 * lms.y + 0.1015581800 * lms.z,
        -0.6561210800 * lms.x + 1.7855411800 * lms.y - 0.1294374900 * lms.z,
         0.0173632100 * lms.x - 0.0472515400 * lms.y + 1.0300425300 * lms.z);
}

float eotfSRGB(float c) {
    return (c <= 0.04045) ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

float oetfSRGB(float c) {
    return (c <= 0.0031308) ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

float3 oetfSRGBExt(float3 c) {
    return select(1.055 * pow(max(c, float3(0.0)), float3(1.0 / 2.4)) - 0.055,
                  12.92 * c,
                  c <= 0.0031308);
}

// A viewing preference for bright rooms, separate from HDR display mapping.
// A shared linear-light gain preserves RGB ratios; the soft ceiling retains
// detail in saturated colors as they approach the available display headroom.
float3 spHdrShadowLift(float3 encoded, bool edrOut, float peakNits) {
    const float3 linear = float3(eotfSRGB(encoded.r), eotfSRGB(encoded.g), eotfSRGB(encoded.b));
    const float3 weights = edrOut ? float3(0.22897, 0.69174, 0.07929)
                                  : float3(0.2126, 0.7152, 0.0722);
    const float y = dot(linear, weights);
    if (y <= 0.0 || y >= 1.0) return encoded;
    const float maximum = max(linear.r, max(linear.g, linear.b));
    const float target = max(1.0, edrOut ? peakNits / 100.0 : 1.0);
    if (maximum <= 0.0 || maximum >= target) return encoded;
    const float a = 1.0 + 4.0 * (1.0 - y) * (1.0 - y) / (1.0 + 8.0 * y);
    const float gain = a / (1.0 + (a - 1.0) * maximum / target);
    if (gain == 1.0) return encoded;
    return oetfSRGBExt(linear * gain);
}

constant float3x3 m2020ToP3 = float3x3(
    float3(1.343578, -0.065297,  0.002822),
    float3(-0.282180, 1.075788, -0.019598),
    float3(-0.061399, -0.010490, 1.016777));

constant float3x3 m2020To709 = float3x3(
    float3(1.660491, -0.124550, -0.018151),
    float3(-0.587641, 1.132900, -0.100579),
    float3(-0.072850, -0.008349, 1.118730));

constant float3x3 m709ToP3 = float3x3(
    float3(0.822462, 0.033194, 0.017083),
    float3(0.177538, 0.966806, 0.072397),
    float3(0.000000, 0.000000, 0.910520));

constant float3x3 mSMPTECTo709 = float3x3(
    float3(0.939542, 0.017772, -0.001622),
    float3(0.050181, 0.965793, -0.004370),
    float3(0.010277, 0.016435,  1.005991));
constant float3x3 mEBUTo709 = float3x3(
    float3(1.044043, 0.000000, 0.000000),
    float3(-0.044043, 1.000000, 0.011793),
    float3(0.000000, 0.000000, 0.988207));

constant float3x3 mP3To709 = float3x3(
    float3(1.224940, -0.042057, -0.019638),
    float3(-0.224940, 1.042057, -0.078636),
    float3(0.000000, 0.000000, 1.098274));

constant float3x3 mDCIP3To709 = float3x3(
    float3(1.157516, -0.041500, -0.018050),
    float3(-0.154962, 1.045568, -0.078578),
    float3(-0.002554, -0.004068, 1.096628));

constant float3x3 m709To2020 = float3x3(
    float3(0.627404, 0.069097, 0.016391),
    float3(0.329283, 0.919540, 0.088013),
    float3(0.043313, 0.011362, 0.895595));
constant float3x3 m709ToSMPTEC = float3x3(
    float3(1.065379, -0.019633, 0.001632),
    float3(-0.055401, 1.036363, 0.004412),
    float3(-0.009978, -0.016731, 0.993956));
constant float3x3 m709ToEBU = float3x3(
    float3(0.957815, 0.000000, 0.000000),
    float3(0.042185, 1.000000, -0.011934),
    float3(0.000000, 0.000000, 1.011934));
constant float3x3 m709ToDCIP3 = float3x3(
    float3(0.868580, 0.034540, 0.016771),
    float3(0.128919, 0.961811, 0.071040),
    float3(0.002501, 0.003648, 0.912189));

float3 spSourceTo709(int gamut, float3 lin) {
    if (gamut == 1) return m2020To709 * lin;
    if (gamut == 2) return mSMPTECTo709 * lin;
    if (gamut == 3) return mEBUTo709 * lin;
    if (gamut == 4) return mP3To709 * lin;
    if (gamut == 5) return mDCIP3To709 * lin;
    return lin;
}

float3 spSourceToP3(int gamut, float3 lin) {
    if (gamut == 1) return m2020ToP3 * lin;
    if (gamut == 4) return lin;
    return m709ToP3 * spSourceTo709(gamut, lin);
}

float3 sp709ToSource(int gamut, float3 lin) {
    if (gamut == 1) return m709To2020 * lin;
    if (gamut == 2) return m709ToSMPTEC * lin;
    if (gamut == 3) return m709ToEBU * lin;
    if (gamut == 4) return m709ToP3 * lin;
    if (gamut == 5) return m709ToDCIP3 * lin;
    return lin;
}

float spXdrGain(float yEnc, float ratio) {
    float y = clamp(yEnc, 0.0, 1.0);
    float c = y * 255.0;
    float e = (c <= 70.0)
        ? (1.8712e-5 * c * c - 2.7334e-3 * c + 1.3141)
        : (2.8305e-6 * c * c - 7.4622e-4 * c + 1.2528);
    float r = max(ratio, 1.0);
    float k = log(r) / log(10.0);
    float lnG = (log(10.0) + 2.4 * (e - 1.0) * log(max(y, 1e-4))) * k;
    float g = mix(1.0, exp(lnG), smoothstep(0.35, 0.85, y));
    return clamp(g, 1.0, r);
}

float spXdrGain2(float yEnc, float headroom, bool is10bit) {
    float rMid = clamp(headroom, 1.0, 6.0);
    float rHigh = clamp(headroom, rMid, is10bit ? 16.0 : 8.0);
    float g = spXdrGain(yEnc, rMid);
    float t = smoothstep(0.85, 1.0, clamp(yEnc, 0.0, 1.0));
    g *= pow(rHigh / rMid, t);
    return clamp(g, 1.0, rHigh);
}

float3 yuvToRgb(int primaries, float Y, float Cb, float Cr) {
    float3 rgb;
    if (primaries == 1) {            // BT.2020
        rgb = float3(
            Y + 1.4746 * Cr,
            Y - 0.164553 * Cb - 0.571353 * Cr,
            Y + 1.8814 * Cb);
    } else if (primaries == 2) {     // BT.601
        rgb = float3(
            Y + 1.402 * Cr,
            Y - 0.344136 * Cb - 0.714136 * Cr,
            Y + 1.772 * Cb);
    } else if (primaries == 3) {

        rgb = float3(
            Y + 1.576 * Cr,
            Y - 0.226622 * Cb - 0.476622 * Cr,
            Y + 1.826 * Cb);
    } else {
        rgb = float3(
            Y + 1.5748 * Cr,
            Y - 0.187324 * Cb - 0.468124 * Cr,
            Y + 1.8556 * Cb);
    }
    return rgb;
}

float3 toneMap(float3 lin10k, float contentPeak, float targetPeak) {
    float3 x = lin10k * (10000.0 / targetPeak);
    float w = max(contentPeak / targetPeak, 1.0001);
    float3 num = x * (1.0 + x / (w * w));
    return num / (1.0 + x);
}

// SMPTE ST 2094-10 Annex B equations 8/9, following the player's base tone
// mapping. CPU selects authored L2 targets; neutral or unavailable trims skip
// this work. RGB is linear in the actual output gamut, normalized to its peak.
float3 doviDisplayTrim(float3 rgb, float3 luma, constant DoviUniforms& dv) {
    if (dv.v[dovi_gpu::TrimEnabled] < 0.5) return rgb;
    float3 f = pow(clamp(rgb * dv.v[dovi_gpu::TrimSlope] + dv.v[dovi_gpu::TrimOffset], 0.0, 1.0),
                   float3(dv.v[dovi_gpu::TrimPower]));
    const float y = max(dot(f, luma), 1e-8);
    // ST 2094-10 Annex B eq. 9: G = F * ((1 + chroma) * F / Y)^saturation.
    return f * pow(max((1.0 + dv.v[dovi_gpu::TrimChroma]) * f / y, 1e-8),
                   float3(dv.v[dovi_gpu::TrimSaturation]));
}

static float3 doviPublicToneMap(float3 nits, constant DoviUniforms& dv) {
    float3 x = max(nits, 0.0) / dv.v[dovi_gpu::PublicCurveSourcePeak];
    return clamp((dv.v[dovi_gpu::PublicCurveC1] + dv.v[dovi_gpu::PublicCurveC2] * x) /
                 (1.0 + dv.v[dovi_gpu::PublicCurveC3] * x),
                 dv.v[dovi_gpu::PublicCurveBlack], 1.0);
}

static float doviInterpolateCodes(float4 samples, float2 f, float offset, bool tenBit) {
    float4 codes = floor(samples * (tenBit ? 65535.0 : 255.0) + 0.5);
    if (tenBit) codes = floor(codes / 64.0); // P010 high-aligned code words
    float maximum = tenBit ? 1023.0 : 255.0;
    codes -= offset * maximum;
    // Metal gather order: (lo.x,hi.y), (hi.x,hi.y), (hi.x,lo.y), (lo.x,lo.y).
    return mix(mix(codes.w,codes.z,f.x), mix(codes.x,codes.y,f.x), f.y) / maximum;
}

// Hardware UNorm bilinear filtering may round a fractional EL code to the
// neutral code, crossing LINEAR_DZ's discontinuity. Interpolate decoded integer
// codes explicitly; subtract the neutral code first to retain near-zero detail.
// This is FEL-only and needs no intermediate image or additional render pass.
static float2 doviCenteredSample(texture2d<float> tex, float2 uv, float2 offset, bool tenBit) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 p = uv * size - 0.5, lo = floor(p), f = p - lo;
    // Anchor the gather in the middle of its four texels, away from footprint
    // boundaries; retain the original full-precision weights for interpolation.
    float2 gatherUV = (lo + 1.0) / size;
    constexpr sampler gatherSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    return float2(doviInterpolateCodes(tex.gather(gatherSampler,gatherUV,int2(0),component::x), f, offset.x, tenBit),
                  doviInterpolateCodes(tex.gather(gatherSampler,gatherUV,int2(0),component::y), f, offset.y, tenBit));
}

static float3 doviResidual(texture2d<float> yTex, texture2d<float> uvTex,
                          float2 uv, constant DoviUniforms& dv) {
    constant float *nlq = dv.v + dovi_gpu::Nlq; // per component: offset, slope, threshold
    const bool tenBit = dv.v[dovi_gpu::EnhancementTenBit] > 0.5;
    float3 centered = float3(
        doviCenteredSample(yTex, uv + float2(dv.v[dovi_gpu::ElLumaOffsetX], dv.v[dovi_gpu::ElLumaOffsetY]),
                           float2(nlq[0], 0), tenBit).r,
        doviCenteredSample(uvTex, uv + float2(dv.v[dovi_gpu::ElChromaOffsetX], dv.v[dovi_gpu::ElChromaOffsetY]),
                           float2(nlq[dovi_gpu::NlqStride], nlq[2 * dovi_gpu::NlqStride]), tenBit));
    // Interpolated texture coordinates can leave two float ULPs at an exact
    // neutral crossing. This bound is <0.00025 of one 10-bit code step.
    centered = select(centered, float3(0.0), abs(centered) <= 2.384185791015625e-7);
    constexpr int S = dovi_gpu::NlqStride;
    float3 slope = float3(nlq[1], nlq[S + 1], nlq[2 * S + 1]);
    float3 threshold = float3(nlq[2], nlq[S + 2], nlq[2 * S + 2]);
    // LINEAR_DZ output is bounded by vdr_in_max (final words of MMR records 5-7).
    float3 bound = float3(dv.v[dovi_gpu::NlqMaxY], dv.v[dovi_gpu::NlqMaxCb], dv.v[dovi_gpu::NlqMaxCr]);
    return sign(centered) * min(abs(centered) * slope + threshold, bound);
}

// L5 describes the active picture. Preserve encoded bars outside it when a
// positive trim offset would otherwise lift them. This never crops the image.
bool doviActiveArea(float2 uv, constant DoviUniforms& dv) {
    return uv.x >= dv.v[dovi_gpu::ActiveLeft] && uv.x < dv.v[dovi_gpu::ActiveRight] &&
           uv.y >= dv.v[dovi_gpu::ActiveTop] && uv.y < dv.v[dovi_gpu::ActiveBottom];
}

float doviReshapeComp(int c, float3 s, constant float *v) {
    int C = dovi_gpu::Components + c * dovi_gpu::ComponentStride;
    int np = int(v[C]);
    float x = s[c];
    if (np <= 0) return x;
    int p = 0;
    for (int i = 1; i < np; i++) {
        if (x >= v[C + 1 + i]) p = i;
    }
    int P = C + dovi_gpu::PieceOffset + p * dovi_gpu::PieceStride;
    if (v[P] < 0.5) {
        return clamp(v[P + 1] + v[P + 2] * x + v[P + 3] * x * x, v[C+1], v[C+1+np]);
    }

    int M = dovi_gpu::Mmr + (c * dovi_gpu::MaxPieces + p) * dovi_gpu::MmrStride;
    int order = int(v[M]);
    float t[7] = {s.x, s.y, s.z, s.x * s.y, s.x * s.z, s.y * s.z, s.x * s.y * s.z};
    float r = v[M + 1];
    for (int o = 0; o < order; o++) {
        for (int j = 0; j < 7; j++) {
            float tp = t[j];
            for (int k = 0; k < o; k++) tp *= t[j];
            r += v[M + 2 + o * 7 + j] * tp;
        }
    }
    return clamp(r, v[C+1], v[C+1+np]);
}

#pragma mark - Fragments

// Shared reconstruction, before display management. Real playback remains a
// single render pass; only requested DV interpolation/preview work uses compute.
static float3 doviReconstruct(float3 sig, float2 uv,
                              texture2d<float> elYTex, texture2d<float> elUVTex,
                              constant DoviUniforms& dv) {
    if (dv.v[dovi_gpu::HasCurves] > 0.5) {
        sig = float3(doviReshapeComp(0, sig, dv.v),
                     doviReshapeComp(1, sig, dv.v),
                     doviReshapeComp(2, sig, dv.v));
        sig = clamp(sig, 0.0, 1.0);
    }
    // FEL: reshape BL first, then add inverse-quantized EL residuals.
    // Decoder has paired this EL with this exact BL PTS. No intermediate
    // 4K RGB texture: composition shares the existing render pass.
    if (dv.v[dovi_gpu::NeedsEnhancement] > 0.5) {
        sig += doviResidual(elYTex, elUVTex, uv, dv);
    }
    constant float *ycc = dv.v + dovi_gpu::YccToRgb, *offset = dv.v + dovi_gpu::YccOffset;
    float3 ipt = sig - float3(offset[0], offset[1], offset[2]);
    float3 lmsPq = float3(
        ycc[0] * ipt.x + ycc[1] * ipt.y + ycc[2] * ipt.z,
        ycc[3] * ipt.x + ycc[4] * ipt.y + ycc[5] * ipt.z,
        ycc[6] * ipt.x + ycc[7] * ipt.y + ycc[8] * ipt.z);
    lmsPq = clamp(lmsPq, 0.0, 1.0);
    float3 lms = float3(eotfPQ(lmsPq.x), eotfPQ(lmsPq.y), eotfPQ(lmsPq.z));
    constant float *crosstalk = dv.v + dovi_gpu::RgbToLms;
    lms = float3(
        crosstalk[0] * lms.x + crosstalk[1] * lms.y + crosstalk[2] * lms.z,
        crosstalk[3] * lms.x + crosstalk[4] * lms.y + crosstalk[5] * lms.z,
        crosstalk[6] * lms.x + crosstalk[7] * lms.y + crosstalk[8] * lms.z);

    float3 lin = spDoviHpeLmsToBt2020(lms);
    return max(lin, 0.0); // 1.0 = 10000 nits
}

fragment float4 videoFragment(VertexOut in [[stage_in]],
                              texture2d<float> yTex [[texture(0)]],
                              texture2d<float> uvTex [[texture(1)]],
                              texture2d<float> subTex [[texture(2)]],
                              texture2d<float> vTex [[texture(3)]],
                              texture2d<float> elYTex [[texture(4)]],
                              texture2d<float> elUVTex [[texture(5)]],
                              constant Uniforms &u [[buffer(0)]],
                              constant DoviUniforms &dv [[buffer(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    const int  primaries = kSpec ? fcPrimaries : int(u.uvals[4]);
    const int  transfer  = kSpec ? fcTransfer : int(u.uvals[5]);
    const bool is10bit   = (kSpec ? fcBits : int(u.uvals[7])) == 10;
    const bool fullRange = (kSpec ? fcRange : int(u.uvals[6])) == 1;
    const bool hasHdr    = (kSpec ? fcHdr : (u.uvals[8] > 0.5 ? 1 : 0)) == 1;
    const bool doviIPT   = fcDovi == 1; // every videoFragment PSO defines it (generic: DV or not)
    const bool edrOut    = (kSpec ? fcOutputMode : int(u.uvals[25])) == 1;
    const int  gamut     = kSpec ? fcSourceGamut : int(u.uvals[26]);
    const bool gamut2020 = gamut == 1;
    const bool planar    = (kSpec ? fcPlanar : int(u.uvals[30])) == 1;
    const bool sdrBoost  = kSpec ? (fcSdrBoost == 1) : (u.uvals[31] >= 1.0);
    const bool sdrInHdrLayer = is_function_constant_defined(fcSdrInHdrLayer)
        ? fcSdrInHdrLayer == 1 : dv.v[dovi_gpu::SdrInHdrLayer] > 0.5;

    bool inVideo = (in.uv.x >= 0.0 && in.uv.x <= 1.0 && in.uv.y >= 0.0 && in.uv.y <= 1.0);
    float3 out = float3(0.0);
    if (inVideo) {

    float2 suv = in.uv;
    {
        float cw = u.uvals[28], ch = u.uvals[29];
        if (cw > 0.01 && ch > 0.01) {
            suv = float2(0.5 + (in.uv.x - 0.5) * cw,
                         0.5 + (in.uv.y - 0.5) * ch);
        }
    }

    float Y, Cb, Cr;
    if (planar && is10bit) {

        Y  = float(uint(yTex.sample(s, suv).r * 65535.0 + 0.0078125)) / 1023.0;
        Cb = float(uint(uvTex.sample(s, suv).r * 65535.0 + 0.0078125)) / 1023.0;
        Cr = float(uint(vTex.sample(s, suv).r * 65535.0 + 0.0078125)) / 1023.0;
    } else if (is10bit) {

        uint y16 = uint(yTex.sample(s, suv).r * 65535.0 + 0.5);
        float2 uv = uvTex.sample(s, suv).rg;
        uint u16 = uint(uv.x * 65535.0 + 0.5);
        uint v16 = uint(uv.y * 65535.0 + 0.5);
        Y  = float(y16 >> 6) / 1023.0;
        Cb = float(u16 >> 6) / 1023.0;
        Cr = float(v16 >> 6) / 1023.0;
    } else if (planar) {

        Y  = yTex.sample(s, suv).r;
        Cb = uvTex.sample(s, suv).r;
        Cr = vTex.sample(s, suv).r;
    } else {
        // NV12
        Y  = yTex.sample(s, suv).r;
        Cb = uvTex.sample(s, suv).r;
        Cr = uvTex.sample(s, suv).g;
    }

    bool limitedRange = !doviIPT && !fullRange;
    if (limitedRange) {
        if (is10bit) {
            Y  = (Y  - 64.0 / 1023.0) / (876.0 / 1023.0);
            Cb = (Cb - 64.0 / 1023.0) / (896.0 / 1023.0);
            Cr = (Cr - 64.0 / 1023.0) / (896.0 / 1023.0);
        } else {
            Y  = (Y  - 16.0 / 255.0) / (219.0 / 255.0);
            Cb = (Cb - 16.0 / 255.0) / (224.0 / 255.0);
            Cr = (Cr - 16.0 / 255.0) / (224.0 / 255.0);
        }
    }
    Y  = clamp(Y, 0.0, 1.0);
    Cb = clamp(Cb, 0.0, 1.0);
    Cr = clamp(Cr, 0.0, 1.0);

    const float chromaCenter = limitedRange ? 0.5 : (is10bit ? 512.0 / 1023.0 : 128.0 / 255.0);

    float3 lin = float3(0.0);
    float3 rgbEnc = float3(0.0);

    const bool sdrPassthrough = !doviIPT && !hasHdr && !edrOut && !sdrInHdrLayer;
    if (doviIPT) {

        if (dv.v[dovi_gpu::Reconstructed] > .5) {
            // FRC already reconstructed these P010 pixels. Keep the RPU for
            // display trims, but do not reshape or apply the FEL residual twice.
            float3 pq = clamp(yuvToRgb(1, (Y*1023.0-64.0)/876.0,
                (Cb*1023.0-512.0)/896.0, (Cr*1023.0-512.0)/896.0), 0.0, 1.0);
            lin = float3(eotfPQ(pq.r), eotfPQ(pq.g), eotfPQ(pq.b));
        } else {
            lin = doviReconstruct(float3(Y,Cb,Cr), suv, elYTex, elUVTex, dv);
        }
    } else {

        rgbEnc = clamp(yuvToRgb(primaries, Y, Cb - chromaCenter, Cr - chromaCenter), 0.0, 1.0);
        if (sdrPassthrough) {

        } else if (transfer == 1) {           // PQ
            lin = float3(eotfPQ(rgbEnc.r), eotfPQ(rgbEnc.g), eotfPQ(rgbEnc.b));
        } else if (transfer == 2) {

            lin = float3(eotfHLG(rgbEnc.r), eotfHLG(rgbEnc.g), eotfHLG(rgbEnc.b));
            float Ys = dot(lin, float3(0.2627, 0.6780, 0.0593));
            lin *= pow(max(Ys, 1e-6), 0.2); // γ-1 = 0.2
            lin *= 0.1;
        } else {
            lin = eotfSdrTier(transfer, rgbEnc);
        }
    }

    float contentPeak = u.uvals[9];
    if (doviIPT && (dv.v[dovi_gpu::HasLevel1] > 0.5 || dv.v[dovi_gpu::MaxPq] > 0.0)) {
        float peakPq = dv.v[dovi_gpu::HasLevel1] > 0.5 ? dv.v[dovi_gpu::SceneMaxPq] : dv.v[dovi_gpu::MaxPq];
        contentPeak = max(eotfPQ(peakPq) * 10000.0, 203.0);
    }
    if (hasHdr) {

        if (edrOut) {

            float3 nits;
            if (doviIPT && dv.v[dovi_gpu::PublicCurveEnabled] > .5 && doviActiveArea(suv,dv)) {
                nits = doviPublicToneMap(spSourceToP3(gamut,lin*10000.0),dv) * u.uvals[24];
            } else {
                if (contentPeak > u.uvals[24])
                    nits = toneMap(lin, contentPeak, max(u.uvals[24], 1.0)) * u.uvals[24];
                else nits = lin * 10000.0;
                nits = max(spSourceToP3(gamut, nits), float3(0.0));
            }
            if (doviIPT && dv.v[dovi_gpu::TrimEnabled] > 0.5) {
                if (doviActiveArea(suv, dv)) {
                    const float peak = max(u.uvals[24], 1.0);
                    nits = doviDisplayTrim(nits/peak, float3(0.22897,0.69174,0.07929), dv) * peak;
                }
            }
            out = oetfSRGBExt(nits / 100.0);
        } else {

            float3 tm;
            if (doviIPT && dv.v[dovi_gpu::PublicCurveEnabled] > .5 && doviActiveArea(suv,dv)) {
                tm = doviPublicToneMap(spSourceTo709(gamut,lin*10000.0),dv);
            } else {
                tm = toneMap(lin, max(contentPeak, 203.0), 203.0);
                tm = clamp(spSourceTo709(gamut, tm), 0.0, 1.0);
            }
            if (doviIPT && dv.v[dovi_gpu::TrimEnabled] > 0.5) {
                if (doviActiveArea(suv, dv))
                    tm = doviDisplayTrim(tm, float3(0.2126,0.7152,0.0722), dv);
            }
            out = float3(oetfSRGB(tm.r), oetfSRGB(tm.g), oetfSRGB(tm.b));
        }
    } else if (sdrBoost && edrOut) {

        float3 rgbP3 = spSourceToP3(gamut, lin);
        float yEnc = dot(rgbEnc, gamut2020 ? float3(0.2627, 0.6780, 0.0593)
                                           : float3(0.2126, 0.7152, 0.0722));
        out = oetfSRGBExt(max(rgbP3 * spXdrGain2(yEnc, u.uvals[31], is10bit), float3(0.0)));
    } else if (edrOut) {
        // SDR fallback in an EDR DV session (e.g. damaged P8.2 RPU).
        // Preserve SDR luminance while encoding for the actual P3 layer.
        out = oetfSRGBExt(max(spSourceToP3(gamut, lin), float3(0.0)));
    } else if (sdrInHdrLayer) {
        out = oetfSRGBExt(clamp(spSourceTo709(gamut, lin), 0.0, 1.0));
    } else {

        out = rgbEnc;
    }

    if (hasHdr && u.uvals[33] > 0.5) {
        out = spHdrShadowLift(out, edrOut, u.uvals[24]);
    }

    if (u.uvals[20] != 0.0 || u.uvals[21] != 1.0 || u.uvals[22] != 1.0
        || u.uvals[23] != 1.0 || u.uvals[32] != 0.0) {
        out += float3(u.uvals[20]);
        out = (out - 0.5) * u.uvals[21] + 0.5;
        // Hue rotates chroma around the luma axis (Rodrigues rotation about
        // the normalized weights). Neutral pixels, luma, and chroma magnitude
        // are preserved exactly, matching how the other controls behave.
        const float3 lumaAxis = normalize(float3(0.2126, 0.7152, 0.0722));
        const float luma = dot(out, float3(0.2126, 0.7152, 0.0722));
        const float3 chroma = out - float3(luma);
        const float hueA = u.uvals[32] * 0.017453292519943295f;
        out = float3(luma) + chroma * cos(hueA)
            + cross(lumaAxis, chroma) * sin(hueA);
        out = mix(float3(luma), out, u.uvals[22]);
        out = pow(max(out, 0.0), float3(1.0 / max(u.uvals[23], 0.1)));
    }

    if ((hasHdr || sdrBoost) && edrOut) {
        out = max(out, float3(0.0));
    } else {
        out = clamp(out, 0.0, 1.0);
    }

    }

    if (u.uvals[16] > 0 && u.uvals[14] > 0 && u.uvals[15] > 0) {

        float2 vp = in.position.xy;
        float2 subUv = (vp - float2(u.uvals[12], u.uvals[13])) / float2(u.uvals[14], u.uvals[15]);
        if (subUv.x >= 0.0 && subUv.x <= 1.0 && subUv.y >= 0.0 && subUv.y <= 1.0) {
            float4 sub = subTex.sample(s, subUv);

            if (sub.a > 0.0) {
                float3 col = clamp(sub.rgb / sub.a, 0.0, 1.0);
                float3 linSub = float3(eotfSRGB(col.r), eotfSRGB(col.g), eotfSRGB(col.b));
                float3 enc;
                if (edrOut) {
                    enc = oetfSRGBExt(max(m709ToP3 * linSub, float3(0.0)));
                } else if (!hasHdr && !doviIPT && !sdrInHdrLayer) {
                    enc = oetfSdrTier(transfer, clamp(sp709ToSource(gamut, linSub), 0.0, 1.0));
                } else {
                    enc = col;
                }
                out = out * (1.0 - sub.a) + enc * sub.a;
            }
        }
    }
    return float4(out, 1.0);
}

#pragma mark - Window depth effect

struct DragFxUniforms {
    float v[16];
};
static_assert(sizeof(DragFxUniforms) == 64, "CPU DragFxUniforms size mismatch");
static_assert(alignof(DragFxUniforms) == 4, "CPU DragFxUniforms alignment mismatch");

struct DragFxVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex DragFxVertexOut dragFxVertex(uint vid [[vertex_id]]) {
    float2 pos = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    DragFxVertexOut o;
    o.position = float4(pos, 0.0, 1.0);
    o.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);
    return o;
}

fragment float4 dragFxDownsample(DragFxVertexOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant float2 &texel [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float3 a = src.sample(s, uv + float2(-2.0, -2.0) * texel).rgb;
    float3 b = src.sample(s, uv + float2( 0.0, -2.0) * texel).rgb;
    float3 c = src.sample(s, uv + float2( 2.0, -2.0) * texel).rgb;
    float3 d = src.sample(s, uv + float2(-2.0,  0.0) * texel).rgb;
    float3 e = src.sample(s, uv).rgb;
    float3 f = src.sample(s, uv + float2( 2.0,  0.0) * texel).rgb;
    float3 g = src.sample(s, uv + float2(-2.0,  2.0) * texel).rgb;
    float3 h = src.sample(s, uv + float2( 0.0,  2.0) * texel).rgb;
    float3 i = src.sample(s, uv + float2( 2.0,  2.0) * texel).rgb;
    float3 j = src.sample(s, uv + float2(-1.0, -1.0) * texel).rgb;
    float3 k = src.sample(s, uv + float2( 1.0, -1.0) * texel).rgb;
    float3 l = src.sample(s, uv + float2(-1.0,  1.0) * texel).rgb;
    float3 m = src.sample(s, uv + float2( 1.0,  1.0) * texel).rgb;
    float3 o = e * 0.125
             + (a + c + g + i) * 0.03125
             + (b + d + f + h) * 0.0625
             + (j + k + l + m) * 0.125;
    return float4(o, 1.0);
}

static inline float3 spDragFxTent(texture2d<float> t, sampler s, float2 uv) {
    float2 texel = 1.0 / float2(t.get_width(), t.get_height());
    float3 c = t.sample(s, uv + float2(-0.5, -0.5) * texel).rgb
             + t.sample(s, uv + float2( 0.5, -0.5) * texel).rgb
             + t.sample(s, uv + float2(-0.5,  0.5) * texel).rgb
             + t.sample(s, uv + float2( 0.5,  0.5) * texel).rgb;
    return c * 0.25;
}

static inline float3 spDragFxLevel(int lvl, array<texture2d<float>, 7> lv,
                                   sampler s, float2 uv) {
    switch (lvl) {
        case 0:  return lv[0].sample(s, uv).rgb;
        case 1:  return spDragFxTent(lv[1], s, uv);
        case 2:  return spDragFxTent(lv[2], s, uv);
        case 3:  return spDragFxTent(lv[3], s, uv);
        case 4:  return spDragFxTent(lv[4], s, uv);
        case 5:  return spDragFxTent(lv[5], s, uv);
        default: return spDragFxTent(lv[6], s, uv);
    }
}

static inline float3 spDragFxSample(int l0, float f, int maxLevel,
                                    array<texture2d<float>, 7> levels,
                                    sampler s, float2 uv) {
    float3 c = spDragFxLevel(l0, levels, s, uv);
    if (f > 0.001 && l0 < maxLevel) {
        c = mix(c, spDragFxLevel(l0 + 1, levels, s, uv), f);
    }
    return c;
}

fragment float4 dragFxComposite(DragFxVertexOut in [[stage_in]],
                                array<texture2d<float>, 7> levels [[texture(0)]],
                                constant DragFxUniforms &u [[buffer(0)]],
                                constant float &outputCeiling [[buffer(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 vp = float2(u.v[0], u.v[1]);
    const float2 anchor = clamp(float2(u.v[2], u.v[3]), float2(0.0), vp);
    const float strength = clamp(u.v[4], 0.0, 1.0);
    const float colorStrength = clamp(u.v[9], 0.0, 1.0);
    const float maxLevel = clamp(u.v[7], 0.0, 6.0);
    const float2 p = in.position.xy;

    float R = max(length(max(anchor, vp - anchor)), 1.0);
    float d = length(p - anchor) / R;
    float radial = smoothstep(u.v[8], 1.0, d);

    float t = mix(clamp(u.v[13], 0.0, 1.0), 1.0, radial);
    float k = colorStrength * t;
    float2 uv = p / vp;

    const float shortSide = min(vp.x, vp.y);
    const float refractionPx = shortSide * max(u.v[14], 0.0);
    const float2 geometryAnchor = clamp(anchor, float2(0.5), vp - 0.5);
    const float coreRadius = shortSide * clamp(u.v[12], 0.0, 0.45);
    const float geometryRadius = length(p - geometryAnchor);
    const float core = smoothstep(coreRadius, coreRadius + shortSide * 0.20, geometryRadius);
    const float2 q = uv * 2.0 - 1.0;
    const float2 q2 = q * q;
    const float2 surfaceSlope = -q * q2 * (0.8 + 0.2 * q2.yx);
    const float2 inward = surfaceSlope * core * strength;
    uv += inward * refractionPx / vp;

    float nearLevel = clamp(u.v[5], 0.0, maxLevel);
    float farLevel = clamp(u.v[6], nearLevel, maxLevel);
    float L = strength * mix(nearLevel, farLevel, radial);
    int l0 = int(floor(L));
    float f = L - float(l0);
    float3 c = spDragFxSample(l0, f, int(maxLevel), levels, s, uv);

    const float dispersionPx = min(4.0 + 0.5 * exp2(L), 20.0) * max(u.v[15], 0.0);
    const float2 dispersionDirection = inward;
    const float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
    float3 chromaDelta = float3(0.0);
    if (dispersionPx > 0.0 && any(dispersionDirection != float2(0.0))) {
        float2 rgbPx = dispersionDirection * dispersionPx;

        float2 available = max(min(uv * vp - 0.5, (1.0 - uv) * vp - 0.5), float2(0.0));
        float2 ratio = abs(rgbPx) / max(available, float2(0.0001));
        rgbPx /= 1.0 + length(ratio);
        rgbPx = clamp(rgbPx, -available, available);
        float2 rgbOffset = rgbPx / vp;
        float chromaLevel = max(L - 1.5, 0.0);
        int chromaL0 = int(floor(chromaLevel));
        float chromaF = chromaLevel - float(chromaL0);
        float3 detail = spDragFxSample(chromaL0, chromaF, int(maxLevel), levels, s, uv);
        float red = spDragFxSample(chromaL0, chromaF, int(maxLevel), levels, s, uv + rgbOffset).r;
        float blue = spDragFxSample(chromaL0, chromaF, int(maxLevel), levels, s, uv - rgbOffset).b;
        chromaDelta = float3(red - detail.r, 0.0, blue - detail.b);
        chromaDelta -= dot(chromaDelta, lumaWeights);
    }

    float luma = dot(c, lumaWeights);
    c = mix(c, float3(luma), clamp(u.v[11] * k, 0.0, 1.0));

    float dim = 1.0 - clamp(u.v[10] * k, 0.0, 1.0);
    float3 lower = select(float3(0.9), max(c, float3(0.0)) / max(-chromaDelta, float3(0.00001)),
                          chromaDelta < float3(0.0));
    float3 upper = select(float3(0.9), max(outputCeiling / max(dim, 0.00001) - c, float3(0.0))
                          / max(chromaDelta, float3(0.00001)), chromaDelta > float3(0.0));
    float3 allowance = min(lower, upper);
    float chromaGain = min(allowance.r, min(allowance.g, allowance.b));
    c += chromaDelta * max(chromaGain, 0.0);
    c *= dim;
    return float4(c, 1.0);
}

#pragma mark - Dolby Vision thumbnail conversion

static float oetfPQ(float lin) {
    const float m1 = 0.1593017578125, m2 = 78.84375;
    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float ym = pow(max(lin, 0.0), m1);
    return pow((c1 + c2 * ym) / (1.0 + c3 * ym), m2);
}

// Read native code words and interpolate chroma at the fragment's sample
// positions, but exactly: the fragment's hardware-filtered 10-bit sample
// truncates the interpolated code (up to one code), these compute paths do not.
// meta.w distinguishes dav1d's low-aligned, three-plane 10-bit surfaces.
static float3 doviSourceSignal(texture2d<float> yTex, texture2d<float> uvTex,
                                texture2d<float> vTex, uint2 pixel, int4 meta) {
    float2 uv = (float2(pixel)+.5) / float2(yTex.get_width(),yTex.get_height());
    float y=yTex.read(pixel).r;
    if (meta.x == 10) y=floor(y*65535.0+.5)/(meta.w ? 1023.0 : 65472.0);
    const float2 chromaSize=float2(uvTex.get_width(),uvTex.get_height());
    const float2 p=uv*chromaSize-.5, lo=floor(p), f=p-lo;
    constexpr sampler gatherSampler(coord::normalized,address::clamp_to_edge,filter::nearest);
    const float2 gatherUV=(lo+1.0)/chromaSize;
    float4 cb=uvTex.gather(gatherSampler,gatherUV,int2(0),component::x);
    float4 cr=meta.w ? vTex.gather(gatherSampler,gatherUV,int2(0),component::x)
                    : uvTex.gather(gatherSampler,gatherUV,int2(0),component::y);
    const float maximum=meta.x==10 ? 1023.0 : 255.0;
    const float align=meta.x==10 && !meta.w ? 64.0 : 1.0;
    const float unorm=meta.x==10 ? 65535.0 : 255.0;
    cb=floor(floor(cb*unorm+.5)/align); cr=floor(floor(cr*unorm+.5)/align);
    return clamp(float3(y,mix(mix(cb.w,cb.z,f.x),mix(cb.x,cb.y,f.x),f.y)/maximum,
                         mix(mix(cr.w,cr.z,f.x),mix(cr.x,cr.y,f.x),f.y)/maximum),0.0,1.0);
}

// BT.2020 PQ RGBA16F is the common FRC working signal for all DV profiles.
// Reconstruct each endpoint independently, including its own FEL enhancement.
kernel void doviFrameToRGBA(texture2d<float> yTex [[texture(0)]],
                             texture2d<float> uvTex [[texture(1)]],
                             texture2d<float> elYTex [[texture(2)]],
                             texture2d<float> elUVTex [[texture(3)]],
                             texture2d<float> vTex [[texture(4)]],
                             texture2d<half, access::write> out [[texture(5)]],
                             constant DoviUniforms &dv [[buffer(0)]],
                             constant int4 &meta [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(meta.y) || gid.y >= uint(meta.z)) return;
    float2 uv = (float2(gid)+.5) / float2(meta.y,meta.z);
    float3 lin = doviReconstruct(doviSourceSignal(yTex,uvTex,vTex,gid,meta),uv,elYTex,elUVTex,dv);
    float3 pq = clamp(float3(oetfPQ(lin.r),oetfPQ(lin.g),oetfPQ(lin.b)),0.0,1.0);
    out.write(half4(half3(pq),half(1.0)),gid);
}

// Reconstruct BEFORE shrinking. Area-weighted linear-light integration avoids
// averaging IPT/reshape inputs or FEL residuals before their nonlinear mapping.
// Output is small; no full-resolution RGB intermediate or additional GPU pass.
// meta.y/z are output dimensions, native dimensions come from the BL textures.
kernel void doviThumbConvert(texture2d<float> yTex [[texture(0)]],
                             texture2d<float> uvTex [[texture(1)]],
                             texture2d<float> elYTex [[texture(2)]],
                             texture2d<float> elUVTex [[texture(3)]],
                             constant DoviUniforms &dv [[buffer(0)]],
                             constant int4 &meta [[buffer(1)]],
                             device ushort4 *outPix [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    const uint W=uint(meta.y), H=uint(meta.z);
    if (gid.x >= W || gid.y >= H) return;
    float2 nativeSize=float2(yTex.get_width(),yTex.get_height());
    float2 scale=nativeSize/float2(W,H);
    float2 lo=float2(gid)*scale, hi=min(float2(gid+1)*scale,nativeSize);
    float3 sum=0.0;
    for (uint y=uint(floor(lo.y)); y<uint(ceil(hi.y)); ++y) {
        float wy=max(0.0,min(float(y+1),hi.y)-max(float(y),lo.y));
        for (uint x=uint(floor(lo.x)); x<uint(ceil(hi.x)); ++x) {
            float wx=max(0.0,min(float(x+1),hi.x)-max(float(x),lo.x));
            uint2 p=min(uint2(x,y),uint2(nativeSize)-1);
            float2 uv=(float2(p)+.5)/nativeSize;
            sum+=wx*wy*doviReconstruct(doviSourceSignal(yTex,uvTex,uvTex,p,meta),uv,elYTex,elUVTex,dv);
        }
    }
    float3 lin=sum/max((hi.x-lo.x)*(hi.y-lo.y),1e-6);
    float3 pq=clamp(float3(oetfPQ(lin.r),oetfPQ(lin.g),oetfPQ(lin.b)),0.0,1.0);
    outPix[gid.y*W+gid.x]=ushort4(ushort3(pq*65535.0+.5),65535);
}
