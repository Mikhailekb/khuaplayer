#include "SPDoviRPU.hpp"
#include "SPAv1CatchUpSkip.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
extern "C" {
#include <libavcodec/sp_dovi_rpu.h>
#include <libavcodec/defs.h>
#include <libavutil/error.h>
#include <libavutil/crc.h>
#include <libavutil/mem.h>
}

namespace sp {

DoviParser::DoviParser(int profile, int compatibility, int compression)
    : profile_(profile), context_(sp_dovi_parser_create(profile, compatibility, compression)) {}
DoviParser::~DoviParser() {
    auto *p = static_cast<SPDoviParserContext *>(context_);
    sp_dovi_parser_free(&p);
}
void DoviParser::reset() {
    sp_dovi_parser_flush(static_cast<SPDoviParserContext *>(context_));
    av1Pending_ = {}; av1PendingResult_ = Result::Absent; av1PendingTemporal_ = -1;
}

static float nitsToPq(float nits) {
    const double x = std::pow(std::min(nits/10000., 1.), 2610./16384.);
    return float(std::pow((3424./4096.+2413./128.*x)/(1+2392./128.*x), 2523./32.));
}

static double pqToNits(double pq) {
    const double x=std::pow(std::clamp(pq,0.,1.),32./2523.);
    return 10000*std::pow(std::max(x-3424./4096.,0.)/(2413./128.-2392./128.*x),16384./2610.);
}

// SMPTE ST 2094-10:2021 Annex B, equations 2–7 (public, informative).
// Use only a selected CM4 target with a known positive authored black level.
// This is the public three-anchor transform, not a claim of Dolby CM4 DM parity.
// Padding words in the MMR records keep the uniform ABI below 4 KiB.
static void preparePublicCurve(float *o, float minimumPq, float peakNits) {
    const double x[3] = {pqToNits(o[dovi_gpu::Cm4MinPq]),
                         pqToNits(o[dovi_gpu::Cm4AvgPq]), pqToNits(o[dovi_gpu::Cm4MaxPq])};
    const double black=pqToNits(minimumPq);
    if (!(black>0 && black<peakNits && x[0]<x[1] && x[1]<x[2])) return;
    const double y[3]={black,std::min(std::sqrt(x[1]*std::sqrt(peakNits*black)),.8*peakNits),peakNits};
    if (!(y[0]<y[1] && y[1]<y[2])) return;
    // Normalize both axes before solving: metadata ranges span eight decades.
    double a[3][4];
    for (int i=0;i<3;++i) {
        const double xx=x[i]/x[2], yy=y[i]/peakNits;
        a[i][0]=1; a[i][1]=xx; a[i][2]=-xx*yy; a[i][3]=yy;
    }
    for (int j=0;j<3;++j) {
        int pivot=j;
        for (int i=j+1;i<3;++i) if (std::abs(a[i][j])>std::abs(a[pivot][j])) pivot=i;
        if (std::abs(a[pivot][j])<1e-12) return;
        for (int k=0;k<4;++k) std::swap(a[j][k],a[pivot][k]);
        const double d=a[j][j];
        for (int k=j;k<4;++k) a[j][k]/=d;
        for (int i=0;i<3;++i) if (i!=j) {
            const double f=a[i][j];
            for (int k=j;k<4;++k) a[i][k]-=f*a[j][k];
        }
    }
    const double c1=a[0][3], c2=a[1][3], c3=a[2][3];
    if (!std::isfinite(c1) || !std::isfinite(c2) || !std::isfinite(c3) ||
        c3<0 || c2-c1*c3<=0 || std::max(std::abs(c1),std::max(std::abs(c2),c3))>1e8) return;
    o[dovi_gpu::PublicCurveEnabled] = 1;
    o[dovi_gpu::PublicCurveC1] = float(c1);
    o[dovi_gpu::PublicCurveC2] = float(c2);
    o[dovi_gpu::PublicCurveC3] = float(c3);
    o[dovi_gpu::PublicCurveSourcePeak] = float(x[2]);
    o[dovi_gpu::PublicCurveBlack] = float(black/peakNits);
}

struct DoviTarget { float pq = 0; int gamut = -1, minPq = 0; };
static DoviTarget presetTarget(int id) {
    // Dolby's public Mastering and Target Displays table (HOME targets).
    // Cinema whitepoints/EOTFs and unknown IDs must not become a 100-nit target.
    switch (id) {
        case 1: return {2081/4095.f, 0, 62}; // 100 nits
        case 24: return {2547/4095.f, 1};    // 300
        case 25: return {2547/4095.f, 2};
        case 27: return {2851/4095.f, 1};    // 600
        case 28: return {2851/4095.f, 2};
        case 37: return {3388/4095.f, 1};    // 2000
        case 38: return {3388/4095.f, 2};
        case 48: return {3079/4095.f, 1};    // 1000
        case 49: return {3079/4095.f, 2};
        default: return {};
    }
}

static int targetGamut(const AVDOVIDmLevel10& t) {
    // Dolby primary indices differ from AVColorPrimaries and renderer indices.
    if (t.target_primary_index == 0) return 1; // P3-D65
    if (t.target_primary_index == 1) return 0; // BT.709
    if (t.target_primary_index == 2) return 2; // BT.2020
    if (t.target_primary_index != 255) return -1;
    // Explicit primaries may spell a standard gamut. Match within one coded
    // xy step; a genuinely custom gamut needs a separate color transform.
    static const double primaries[3][8] = {
        {.64,.33,.30,.60,.15,.06,.3127,.329},
        {.68,.32,.265,.69,.15,.06,.3127,.329},
        {.708,.292,.170,.797,.131,.046,.3127,.329},
    };
    const auto& p = t.target_display_primaries;
    const AVRational xy[] = {p.prim.r.x,p.prim.r.y,p.prim.g.x,p.prim.g.y,
                            p.prim.b.x,p.prim.b.y,p.wp.x,p.wp.y};
    for (int gamut=0; gamut<3; ++gamut) {
        bool match = true;
        for (int i=0; i<8; ++i)
            match &= xy[i].den > 0 && std::isfinite(av_q2d(xy[i])) &&
                     std::abs(av_q2d(xy[i])-primaries[gamut][i]) <= 1./32767;
        if (match) return gamut;
    }
    return -1;
}

static void mapDisplayMetadata(const AVDOVIMetadata *m, DoviReshape& r) {
    const auto *l1 = av_dovi_find_level(m, 1);
    const auto *l3 = av_dovi_find_level(m, 3);
    const auto *cm = av_dovi_find_level(m, 254);
    r.hasCm4 = cm != nullptr;
    r.cm4Usable = cm && cm->l254.dm_mode == 0 && cm->l254.dm_version_index == 2 &&
                  l3 && l1 && r.hasLevel1;
    if (r.cm4Usable) {
        // L1 PQ uses /4095; L3 signed offsets use (code-2048)/2048.
        r.cm4MinPq = r.sceneMinPq + (int(l3->l3.min_pq_offset)-2048)/2048.f;
        r.cm4MaxPq = r.sceneMaxPq + (int(l3->l3.max_pq_offset)-2048)/2048.f;
        r.cm4AvgPq = r.sceneAvgPq + (int(l3->l3.avg_pq_offset)-2048)/2048.f;
        r.cm4Usable = r.cm4MinPq >= 0 && r.cm4MinPq <= r.cm4AvgPq &&
                      r.cm4AvgPq <= r.cm4MaxPq && r.cm4MaxPq <= 1;
    }
    int counts[3] = {}; // singular L3/L5/L254 blocks
    for (int i=0; i<m->num_ext_blocks; ++i) {
        const auto *ext = av_dovi_get_ext(m, i);
        if (ext->level == 3 && ++counts[0] > 1) r.cm4Usable = false;
        if (ext->level == 254 && ++counts[2] > 1) r.cm4Usable = false;
        if (ext->level == 5) {
            if (++counts[1] == 1) {
                r.activeArea[0]=ext->l5.left_offset; r.activeArea[1]=ext->l5.right_offset;
                r.activeArea[2]=ext->l5.top_offset; r.activeArea[3]=ext->l5.bottom_offset;
            } else std::fill_n(r.activeArea, 4, 0);
        }
        if (ext->level != 8) continue;
        r.hasLevel8 = true;
        const auto& src = ext->l8;
        const DoviTarget preset = presetTarget(src.target_display_index);
        int customCount = 0;
        for (int j=0; j<m->num_ext_blocks; ++j) {
            const auto *candidate = av_dovi_get_ext(m, j);
            customCount += candidate->level == 10 &&
                           candidate->l10.target_display_index == src.target_display_index;
        }
        bool supported = src.ms_weight == 2048 && src.target_mid_contrast == 2048 && src.clip_trim == 2048;
        for (int k=0; k<6; ++k)
            supported &= src.saturation_vector_field[k] == 128 && src.hue_vector_field[k] == 128;
        const auto append = [&](DoviTarget target, bool usable) {
            if (target.gamut < 0 || target.pq <= 0 || target.pq > 1) {
                // Without a location we cannot safely interpolate across this
                // target, but independent exact targets remain unambiguous.
                r.cm4ExactOnly = true;
                return;
            }
            if (r.numTrims >= 32) { r.cm4Usable = false; return; }
            auto& dst = r.trims[r.numTrims++];
            dst.targetPq=target.pq; dst.detail=target.minPq;
            dst.gain=.5f+src.trim_slope/4096.f; dst.offset=src.trim_offset/4096.f-.5f;
            dst.gamma=.5f+src.trim_power/4096.f; dst.chroma=src.trim_chroma_weight/4096.f-.5f;
            dst.saturation=src.trim_saturation_gain/4096.f-.5f;
            // A bad located target stays in the table as a rejected endpoint.
            // Dropping it would incorrectly bridge an unsupported interval.
            dst.kind=1+target.gamut+((usable && supported) ? 0 : 4);
        };
        if (!customCount || preset.gamut >= 0) append(preset, !customCount);
        for (int j=0; j<m->num_ext_blocks; ++j) {
            const auto *candidate = av_dovi_get_ext(m, j);
            if (candidate->level != 10 || candidate->l10.target_display_index != src.target_display_index) continue;
            const auto& t = candidate->l10;
            append({t.target_max_pq/4095.f, targetGamut(t), t.target_min_pq},
                   customCount == 1 && preset.gamut < 0 && t.target_min_pq < t.target_max_pq);
        }
    }
}

static bool mapMetadata(const AVDOVIMetadata *m, DoviReshape& r) {
    const auto& h = *av_dovi_get_header(m);
    const auto& map = *av_dovi_get_mapping(m);
    const auto& color = *av_dovi_get_color(m);
    if (h.bl_bit_depth < 8 || h.bl_bit_depth > 16 || h.el_bit_depth < 8 ||
        h.el_bit_depth > 16 || h.vdr_bit_depth < 8 || h.vdr_bit_depth > 16 ||
        h.coef_log2_denom > 32 ||
        map.mapping_color_space != 0 || map.mapping_chroma_format_idc != 0 ||
        map.num_x_partitions != 1 || map.num_y_partitions != 1) return false;
    r = DoviReshape{};
    const double scale = std::ldexp(1.0, -h.coef_log2_denom);
    for (int i = 0; i < 9; ++i) {
        r.yccToRgb[i] = float(av_q2d(color.ycc_to_rgb_matrix[i]));
        r.rgbToLms[i] = float(av_q2d(color.rgb_to_lms_matrix[i]));
        if (!std::isfinite(r.yccToRgb[i]) || !std::isfinite(r.rgbToLms[i])) return false;
    }
    for (int c = 0; c < 3; ++c) {
        r.yccOffset[c] = float(av_q2d(color.ycc_to_rgb_offset[c]));
        if (!std::isfinite(r.yccOffset[c])) return false;
        const auto& src = map.curves[c];
        auto& dst = r.comps[c];
        if (src.num_pivots < 2 || src.num_pivots > 9) return false;
        dst.numPieces = src.num_pivots - 1;
        for (int i = 0; i < src.num_pivots; ++i) {
            dst.pivots[i] = float(src.pivots[i]) / ((1u << h.bl_bit_depth) - 1);
            if (dst.pivots[i] > 1 || (i && dst.pivots[i] < dst.pivots[i-1])) return false;
        }
        for (int p = 0; p < dst.numPieces; ++p) {
            auto& piece = dst.pieces[p];
            piece.type = src.mapping_idc[p];
            if (piece.type == AV_DOVI_MAPPING_POLYNOMIAL) {
                if (src.poly_order[p] > 2) return false;
                for (int k = 0; k < 3; ++k)
                    piece.c[k] = k <= src.poly_order[p] ? float(src.poly_coef[p][k] * scale) : 0;
            } else if (piece.type == AV_DOVI_MAPPING_MMR) {
                piece.mmrOrder = src.mmr_order[p];
                if (piece.mmrOrder < 1 || piece.mmrOrder > 3) return false;
                piece.mmrConst = float(src.mmr_constant[p] * scale);
                for (int j = 0; j < piece.mmrOrder; ++j)
                    for (int k = 0; k < 7; ++k)
                        piece.mmrCoef[j][k] = float(src.mmr_coef[p][j][k] * scale);
            } else return false;
        }
        if (!h.disable_residual_flag) {
            if (map.nlq_method_idc != AV_DOVI_NLQ_LINEAR_DZ) return false;
            const auto& n = map.nlq[c];
            const bool trivial = n.nlq_offset == 0 && n.vdr_in_max == (1ULL << h.coef_log2_denom) &&
                                 n.linear_deadzone_slope == 0 && n.linear_deadzone_threshold == 0;
            r.needsEnhancement |= !trivial;
            const double elMax = (1u << h.el_bit_depth) - 1;
            r.nlq[c].offset = float(n.nlq_offset / elMax);
            r.nlq[c].slope = float(n.linear_deadzone_slope * scale * elMax);
            r.nlq[c].threshold = float((double(n.linear_deadzone_threshold) -
                                       0.5 * n.linear_deadzone_slope) * scale);
            // The dequantized residual is bounded by +/-vdr_in_max.
            r.nlq[c].max = float(n.vdr_in_max * scale);
        }
    }
    r.valid = true;
    r.signalFullRange = color.signal_full_range_flag == 1;
    r.minPqNorm = color.source_min_pq / 4095.0f;
    r.maxPqNorm = color.source_max_pq / 4095.0f;
    if (const auto *l1 = av_dovi_find_level(m, 1)) {
        r.hasLevel1 = l1->l1.min_pq <= l1->l1.avg_pq && l1->l1.avg_pq <= l1->l1.max_pq;
        r.sceneMinPq = l1->l1.min_pq / 4095.0f;
        r.sceneMaxPq = l1->l1.max_pq / 4095.0f;
        r.sceneAvgPq = l1->l1.avg_pq / 4095.0f;
    }
    for (int i=0; i<m->num_ext_blocks && r.numTrims<32; ++i) {
        const auto *ext = av_dovi_get_ext(m, i);
        if (ext->level != 2) continue;
        const auto& src = ext->l2;
        auto& dst = r.trims[r.numTrims++];

        dst.targetPq = src.target_max_pq / 4095.f;
        dst.gain = .5f + src.trim_slope / 4096.f;
        dst.offset = src.trim_offset / 4096.f - .5f;
        dst.gamma = .5f + src.trim_power / 4096.f;
        dst.chroma = src.trim_chroma_weight / 4096.f - .5f;
        dst.saturation = src.trim_saturation_gain / 4096.f - .5f;
        dst.detail = src.ms_weight;
    }
    mapDisplayMetadata(m, r);
    return true;
}

// The upstream parser can return PATCHWELCOME before reaching its CRC check.
// Only intact unsupported syntax is a capability failure; truncation or bit
// damage must remain recoverable invalid metadata. Called only on that error.
static bool intactUnsupportedRpu(const uint8_t *rpu, size_t size) {
    while (size && !rpu[size-1]) --size; // optional HEVC trailing_zero_8bits
    return size >= 6 && rpu[size-1] == 0x80 &&
           av_crc(av_crc_get_table(AV_CRC_32_IEEE), UINT32_MAX, rpu, size-1) == 0;
}

DoviParser::Result DoviParser::parse(const uint8_t *data, size_t size, int ls, DoviReshape& out) {
    if (!doviSplitNals(data, size, ls, nals_, profile_ == 9)) {
        reset(); out = DoviReshape{}; return Result::Invalid;
    }
    return parse(nals_, out);
}

DoviParser::Result DoviParser::parse(const std::vector<DoviNal>& nals, DoviReshape& out) {
    out = DoviReshape{};
    const bool avc = profile_ == 9;
    Result result = Result::Absent;
    for (auto nal : nals) {
        // AVC uses a one-byte header and unspecified NAL type 28 (GPAC's
        // GF_AVC_NALU_DV_RPU); HEVC uses a two-byte UNSPEC62 header.
        if (avc ? (nal.data[0] & 31) != 28 : ((nal.data[0] >> 1) & 63) != 62) continue;
        // P20's second view may carry its own RPU. A layer-0 decoder must
        // never consume that view's reference state or its display metadata.
        if (profile_ == 20 && ((nal.data[0] & 1) || (nal.data[1] >> 3))) continue;
        if (nal.size > 1024 * 1024) {
            reset(); out = DoviReshape{}; return Result::Invalid;
        }
        rbsp_.clear();
        const size_t header = avc ? 1 : 2;
        for (size_t i = header; i < nal.size; ++i) {
            if (i >= header + 2 && nal.data[i] == 3 && !nal.data[i-1] && !nal.data[i-2]) {
                if (i + 1 == nal.size || nal.data[i+1] > 3) {
                    reset(); out = DoviReshape{}; return Result::Invalid;
                }
                continue;
            }
            rbsp_.push_back(nal.data[i]);
        }
        // An RPU ends with its 0x80 stop byte. Length-prefixed muxers may keep
        // Annex B trailing_zero_8bits that the start-code splitter drops; the
        // FFmpeg parser would read them as further extension data.
        while (rbsp_.size() > 2 && !rbsp_.back()) rbsp_.pop_back();
        const size_t len = rbsp_.size();
        // ff_dovi_rpu_parse ignores unknown RPU types without clearing the
        // previous mapping. Do not turn that into valid stale frame metadata.
        if (len < 2 || rbsp_[0] != 0x19 || (rbsp_[1] >> 2) != 2) {
            reset(); out = DoviReshape{}; return Result::Invalid;
        }
        rbsp_.resize(len + AV_INPUT_BUFFER_PADDING_SIZE, 0);
        AVDOVIMetadata *metadata = nullptr;
        const int ret = sp_dovi_parser_parse(static_cast<SPDoviParserContext *>(context_),
                                             rbsp_.data(), len, &metadata);
        // Legacy HEVC can also carry a parameterized non-PQ EOTF. The existing
        // shader only reconstructs PQ, so never label that other signal valid.
        // The caller can use a compatible BL; P3 must report unsupported instead.
        if (ret > 0 && metadata && (profile_ == 2 || profile_ == 3 || profile_ == 4 || profile_ == 6)) {
            const auto& color = *av_dovi_get_color(metadata);
            const auto& header = *av_dovi_get_header(metadata);
            if (color.signal_eotf != 65535 || color.signal_eotf_param0 ||
                color.signal_eotf_param1 || color.signal_eotf_param2 ||
                header.spatial_resampling_filter_flag || header.ext_mapping_idc_0_4 ||
                header.ext_mapping_idc_5_7 || header.bl_bit_depth != (profile_ <= 3 ? 8 : 10) ||
                header.el_bit_depth != (profile_ <= 3 ? 8 : 10)) {
                av_free(metadata); reset(); out = DoviReshape{}; return Result::Unsupported;
            }
        }
        const bool valid = ret > 0 && metadata && mapMetadata(metadata, out) &&
                           (!(avc || profile_ == 20) || !out.needsEnhancement);
        av_free(metadata);
        if (!valid) {
            reset(); out = DoviReshape{};
            return ret == AVERROR_PATCHWELCOME && intactUnsupportedRpu(rbsp_.data()+1,len-1)
                ? Result::Unsupported : Result::Invalid;
        }
        result = Result::Valid;
    }
    return result;
}

bool DoviParser::rememberAV1Sequence(const uint8_t *data, size_t size) {
    if (!size || size > 4096) return false;
    if (av1SequenceKnown_ && (av1Sequence_.size() != size || memcmp(av1Sequence_.data(),data,size))) reset();
    av1Sequence_.assign(data,data+size);
    av1ReducedStill_ = (data[0] & 8) != 0;
    av1SequenceKnown_ = true;
    return true;
}

void DoviParser::setAV1Config(const uint8_t *data, size_t size) {
    av1SequenceKnown_ = false;
    av1Sequence_.clear();
    if (!data || size < 4 || data[0] != 0x81) return;
    size_t pos = 4;
    while (pos < size) {
        const uint8_t h = data[pos++];
        if ((h & 0x81) || !(h & 2)) return;
        if (h & 4) { if (pos == size || data[pos++] != 0) return; }
        uint64_t n = 0;
        pos = spav1::readLeb128(data,size,pos,&n);
        if (!pos || n > size-pos) return;
        if (((h >> 3) & 15) == spav1::kObuSequenceHeader && n) {
            // Only the first five sequence bits affect the show-frame prefix.
            // Full sequence/frame validation remains the decoder's job.
            if (!rememberAV1Sequence(data+pos,size_t(n))) return;
        }
        pos += size_t(n);
    }
}

DoviParser::Result DoviParser::parseAV1(const uint8_t *data, size_t size, DoviReshape& out) {
    out = DoviReshape{};
    auto invalid = [&] { reset(); out = DoviReshape{}; return Result::Invalid; };
    auto pictureDecoder = [&] { reset(); out = DoviReshape{}; return Result::NeedsPictureDecoder; };
    if (!data || !size) return invalid();
    // A TU can put T.35 before its sequence header. Establish that sequence
    // before parsing its RPU, so a changed header clears old references without
    // erasing the new picture's already parsed metadata. Only scan the prefix;
    // large compressed frame payloads are never copied or walked byte by byte.
    for (size_t p=0, n=0; p<size;) {
        if (++n>4096) return invalid();
        const uint8_t h=data[p++];
        if ((h&0x81) || !(h&2)) return invalid();
        unsigned extension = 0;
        if (h&4) {if(p==size || ((extension=data[p++])&7))return invalid();}
        uint64_t length=0;p=spav1::readLeb128(data,size,p,&length);
        if (!p || length>size-p) return invalid();
        if (extension&0x18) return pictureDecoder();
        const unsigned type=(h>>3)&15;
        if (type==spav1::kObuFrame || type==spav1::kObuFrameHeader) break;
        if (type==spav1::kObuSequenceHeader && !rememberAV1Sequence(data+p,size_t(length)))return invalid();
        p+=size_t(length);
    }
    auto& pending = av1Pending_;
    auto& pendingResult = av1PendingResult_;
    Result selected = Result::Absent;
    size_t pos = 0, count = 0, rpus = 0;
    unsigned frames = 0, shown = 0;
    bool active = false, display = false, tiles = false;
    auto& pendingTemporal = av1PendingTemporal_;
    int frameTemporal = 0;
    auto finish = [&]() -> bool {
        if (display) {
            if (pendingTemporal >= 0 && pendingTemporal != frameTemporal) return false;
            if (++shown > 1) return false;
            out = pending;
            selected = pendingResult;
            pending = {}; pendingResult = Result::Absent; pendingTemporal = -1;
        }
        // AV1 T.35 is consumed by the next visible picture, not by hidden
        // reference pictures (dav1d picture.c: dav1d_thread_picture_alloc).
        active = false; tiles = false;
        return true;
    };
    while (pos < size) {
        if (++count > 4096) return invalid();
        const uint8_t h = data[pos++];
        const unsigned type = (h >> 3) & 15;
        if ((h & 0x81) || !(h & 2)) return invalid();
        unsigned temporal = 0, spatial = 0;
        if (h & 4) {
            if (pos == size) return invalid();
            const uint8_t extension = data[pos++];
            // VT does not expose which spatial operating point produced its
            // picture. Temporal sublayers remain unambiguous with one display.
            if (extension & 7) return invalid();
            spatial = extension & 0x18;
            temporal = extension >> 5;
        }
        uint64_t payloadSize = 0;
        pos = spav1::readLeb128(data, size, pos, &payloadSize);
        if (!pos || payloadSize > size - pos) return invalid();
        if (spatial) return pictureDecoder();
        const size_t end = pos + size_t(payloadSize);
        if (type == spav1::kObuSequenceHeader) {
            if (!payloadSize || active) return invalid();
            if (!rememberAV1Sequence(data+pos,size_t(payloadSize))) return invalid();
        } else if (type == spav1::kObuMetadata) {
            uint64_t metadataType = 0;
            const size_t start = spav1::readLeb128(data, end, pos, &metadataType);
            if (!start) return invalid();
            const auto& dolby = kDoviT35Prefix;
            const bool provider = metadataType == 4 && end-start >= 3 && !memcmp(data+start,dolby,3);
            if (provider && (end-start < sizeof(dolby) || !memcmp(data+start,dolby,sizeof(dolby)))) {
                // A fragmented tile sequence with intervening metadata needs
                // tile-completion association, which the VT callback omits.
                if (active && tiles) return pictureDecoder();
                if (++rpus > 64) return invalid();
                if (h & 4) {
                    if (pendingTemporal >= 0 && pendingTemporal != int(temporal)) return pictureDecoder();
                    pendingTemporal = int(temporal);
                }
                if (end-start < sizeof(dolby)) {
                    reset(); pending = {}; pendingResult = Result::Invalid;
                } else pendingResult = parseAV1EMDF(data+start+sizeof(dolby),end-start-sizeof(dolby),pending);
            }
        } else if (type == spav1::kObuFrame || type == spav1::kObuFrameHeader) {
            if (active && !tiles) return invalid();
            if (active && !finish()) return pictureDecoder();
            if (!av1SequenceKnown_ || !payloadSize) return invalid();
            spav1::BitReader bits(data+pos,size_t(payloadSize));
            const bool existing = !av1ReducedStill_ && bits.f(1);
            if (existing) {
                bits.f(3); display = true;
                if (type == spav1::kObuFrame) return invalid();
            } else if (av1ReducedStill_) display = true;
            else { bits.f(2); display = bits.f(1); }
            if (bits.error()) return invalid();
            ++frames; active = true; tiles = false; frameTemporal = int(temporal);
            if ((type == spav1::kObuFrame || existing) && !finish()) return pictureDecoder();
        } else if (type == spav1::kObuTileGroup) {
            if (!active || frameTemporal != int(temporal)) return invalid();
            tiles = true;
        } else if (type == spav1::kObuRedundantFrameHeader) {
            if (!active || frameTemporal != int(temporal)) return invalid();
        } else if (type != spav1::kObuTemporalDelimiter && type != spav1::kObuPadding) {
            return invalid();
        }
        pos = end;
    }
    if (active && !tiles) return invalid();
    if (active && !finish()) return pictureDecoder();
    if (!frames && !av1SequenceKnown_) {
        // Metadata-only callers retain the historical single-RPU contract.
        if (rpus > 1 || pendingTemporal > 0) return invalid();
        out = pending;
        selected = pendingResult;
        pending = {}; pendingResult = Result::Absent; pendingTemporal = -1;
        return selected;
    }
    // Retain unconsumed metadata across hidden-only or metadata-only packets;
    // it belongs to the next visible picture, never the previous packet PTS.
    return shown ? selected : Result::Absent;
}

DoviParser::Result DoviParser::parseAV1EMDF(const uint8_t *rpu, size_t rpuSize, DoviReshape& out) {
    out = DoviReshape{};
    auto invalid = [&] { reset(); out = DoviReshape{}; return Result::Invalid; };
    if (!rpu) return invalid();
    if (rpuSize < 8 || rpuSize > 1024) return invalid();
    // FFmpeg ignores unknown rpu_type while retaining the previous mapping.
    // Validate the EMDF envelope/type before asking the stateful adapter.
    spav1::BitReader bits(rpu, rpuSize);
    if (bits.f(27) != 0x01be6841u) return invalid();
    unsigned payload = bits.f(8);
    if (bits.f(1)) {
        payload = ((payload + 1) << 8) | bits.f(8);
        if (bits.f(1)) return invalid();
    }
    const auto payloadBits = bits;
    if (payload < 6 || payload > 512 || bits.f(6) != 2 || bits.error()) return invalid();
    rbsp_.assign(rpu, rpu + rpuSize);
    rbsp_.resize(rpuSize + AV_INPUT_BUFFER_PADDING_SIZE, 0);
    AVDOVIMetadata *metadata = nullptr;
    const int ret = sp_dovi_parser_parse(static_cast<SPDoviParserContext *>(context_),
                                         rbsp_.data(), rpuSize, &metadata);
    const bool valid = ret > 0 && metadata && mapMetadata(metadata, out) && !out.needsEnhancement;
    av_free(metadata);
    if (valid) return Result::Valid;
    invalid();
    if (ret == AVERROR_PATCHWELCOME) {
        auto rawBits = payloadBits;
        uint8_t raw[512];
        for (unsigned i=0;i<payload;++i) raw[i] = rawBits.f(8);
        if (!rawBits.error() && intactUnsupportedRpu(raw,payload)) return Result::Unsupported;
    }
    return Result::Invalid;
}

void doviToGpuFloats(const DoviReshape& r, float *o) {
    std::fill_n(o, dovi_gpu::FloatCount, 0.0f);
    std::copy_n(r.yccToRgb, 9, o + dovi_gpu::YccToRgb);
    std::copy_n(r.yccOffset, 3, o + dovi_gpu::YccOffset);
    std::copy_n(r.rgbToLms, 9, o + dovi_gpu::RgbToLms);
    o[dovi_gpu::MinPq] = r.minPqNorm; o[dovi_gpu::MaxPq] = r.maxPqNorm;
    o[dovi_gpu::FullRange] = r.signalFullRange; o[dovi_gpu::HasCurves] = r.valid;
    o[dovi_gpu::ActiveLeft] = r.activeArea[0];
    o[dovi_gpu::ActiveRight] = r.activeArea[1];
    o[dovi_gpu::ActiveTop] = r.activeArea[2];
    o[dovi_gpu::ActiveBottom] = r.activeArea[3];
    constexpr int nlqMax[3] = {dovi_gpu::NlqMaxY, dovi_gpu::NlqMaxCb, dovi_gpu::NlqMaxCr};
    for (int c = 0; c < 3; ++c) {
        const auto& comp = r.comps[c];
        const int C = dovi_gpu::Components + c * dovi_gpu::ComponentStride;
        o[C] = comp.numPieces;
        std::copy_n(comp.pivots, 9, o + C + 1);
        for (int p = 0; p < dovi_gpu::MaxPieces; ++p) {
            const auto& piece = comp.pieces[p];
            const int P = C + dovi_gpu::PieceOffset + p * dovi_gpu::PieceStride,
                      M = dovi_gpu::Mmr + (c * dovi_gpu::MaxPieces + p) * dovi_gpu::MmrStride;
            o[P] = piece.type;
            std::copy_n(piece.c, 3, o + P + 1);
            o[M] = std::clamp(piece.mmrOrder, 0, 3);
            o[M+1] = piece.mmrConst;
            for (int j = 0; j < 3; ++j)
                std::copy_n(piece.mmrCoef[j], 7, o + M + 2 + j * 7);
        }
        float *nlq = o + dovi_gpu::Nlq + c * dovi_gpu::NlqStride;
        nlq[0] = r.nlq[c].offset;
        nlq[1] = r.nlq[c].slope;
        nlq[2] = r.nlq[c].threshold;
        o[nlqMax[c]] = r.nlq[c].max;
    }
    o[dovi_gpu::Valid] = r.valid;
    o[dovi_gpu::NeedsEnhancement] = r.needsEnhancement; // renderer enables only with a paired EL
    o[dovi_gpu::HasLevel1] = r.hasLevel1;
    o[dovi_gpu::SceneMinPq] = r.sceneMinPq;
    o[dovi_gpu::SceneMaxPq] = r.sceneMaxPq;
    o[dovi_gpu::SceneAvgPq] = r.sceneAvgPq;
    o[dovi_gpu::Cm4Status] = r.hasCm4 ? (r.cm4Usable ? 1 : 2) : 0;
    o[dovi_gpu::Cm4MinPq] = r.cm4MinPq;
    o[dovi_gpu::Cm4MaxPq] = r.cm4MaxPq;
    o[dovi_gpu::Cm4AvgPq] = r.cm4AvgPq;
    o[dovi_gpu::HasLevel8] = r.hasLevel8;
    o[dovi_gpu::Cm4ExactOnly] = r.cm4ExactOnly;
    o[dovi_gpu::TrimCount] = r.numTrims;
    for (int i=0; i<r.numTrims && i<dovi_gpu::MaxTrims; ++i) {
        const auto& t = r.trims[i];
        float *p = o + dovi_gpu::TrimTable + i * dovi_gpu::TrimStride;
        p[0]=t.targetPq; p[1]=t.gain; p[2]=t.offset; p[3]=t.gamma;
        // The last word is CPU-only. A 13-bit auxiliary value plus a small
        // family/gamut tag remain exact in float, preserving the 3968-byte ABI.
        p[4]=t.chroma; p[5]=t.saturation; p[6]=t.detail+t.kind*float(dovi_gpu::TrimKindScale);
    }
}
DoviDisplaySelection doviSelectDisplayTrims(float *o, float nits, DoviDisplayGamut gamut) {
    o[dovi_gpu::TrimEnabled] = o[dovi_gpu::Cm4Selected] = o[dovi_gpu::PublicCurveEnabled] = 0;
    if (!std::isfinite(nits) || nits <= 0 || !std::isfinite(o[dovi_gpu::TrimCount]) ||
        o[dovi_gpu::TrimCount] < 0 || o[dovi_gpu::TrimCount] > dovi_gpu::MaxTrims ||
        int(o[dovi_gpu::TrimCount]) != o[dovi_gpu::TrimCount])
        return DoviDisplaySelection::UnavailableTarget;
    const float pq = nitsToPq(nits);
    const auto select = [&](bool cm4) {
        const float *lo=nullptr, *hi=nullptr;
        const int wanted = 1+int(gamut);
        for (int i=0; i<int(o[dovi_gpu::TrimCount]); ++i) {
            const float *p=o+dovi_gpu::TrimTable+i*dovi_gpu::TrimStride;
            if (!std::isfinite(p[6]) || p[6] < -1 || p[6] > 65535) return false;
            const int kind = p[6] < dovi_gpu::TrimKindScale ? 0 : int(p[6])/dovi_gpu::TrimKindScale;
            if (cm4 ? (kind != wanted && kind != wanted+4) : kind != 0) continue;
            for (int k=0; k<6; ++k) if (!std::isfinite(p[k])) return false;
            if (p[0] <= 0 || p[0] > 1) return false;
            if (std::abs(p[0]-pq) <= .5f/4095) { lo=hi=p; }
            else {
                if (p[0] < pq && (!lo || (lo!=hi && p[0]>lo[0]))) lo=p;
                if (p[0] > pq && (!hi || (lo!=hi && p[0]<hi[0]))) hi=p;
            }
        }
        if (!lo || !hi || (cm4 && (lo[6] >= 5*dovi_gpu::TrimKindScale ||
                                  hi[6] >= 5*dovi_gpu::TrimKindScale))) return false;
        if (cm4 && o[dovi_gpu::Cm4ExactOnly] != 0 && lo != hi) return false;
        // Only conflicts at the selected endpoints matter. A malformed target
        // elsewhere must not suppress an independent authored exact match.
        for (int i=0; i<int(o[dovi_gpu::TrimCount]); ++i) {
            const float *p=o+dovi_gpu::TrimTable+i*dovi_gpu::TrimStride;
            const int kind=p[6] < dovi_gpu::TrimKindScale ? 0 : int(p[6])/dovi_gpu::TrimKindScale;
            if (cm4 ? (kind != wanted && kind != wanted+4) : kind != 0) continue;
            for (const float *endpoint : {lo, hi})
                if (std::abs(p[0]-endpoint[0]) <= .5f/4095 &&
                    memcmp(p+1,endpoint+1,6*sizeof(float))) return false;
        }
        const float mix = lo==hi ? 0 : (pq-lo[0])/(hi[0]-lo[0]);
        const float identity[5] = {1,0,1,0,0};
        for (int i=0; i<5; ++i) {
            o[dovi_gpu::TrimValues+i] = lo[1+i]+mix*(hi[1+i]-lo[1+i]);
            if (std::abs(o[dovi_gpu::TrimValues+i]-identity[i])>1e-7f) o[dovi_gpu::TrimEnabled]=1;
        }
        if (cm4) {
            const float minLo = std::fmod(lo[6], float(dovi_gpu::TrimKindScale));
            const float minHi = std::fmod(hi[6], float(dovi_gpu::TrimKindScale));
            preparePublicCurve(o,(minLo+mix*(minHi-minLo))/4095.f,nits);
        }
        return true;
    };
    if (select(false)) return DoviDisplaySelection::L2; // neutral L2 also wins
    if (o[dovi_gpu::Cm4Status] == 0) return DoviDisplaySelection::L1;
    if (o[dovi_gpu::Cm4Status] != 1) return DoviDisplaySelection::InvalidCM4;
    if (int(gamut) < 0 || int(gamut) > 2) return DoviDisplaySelection::UnavailableTarget;
    if (select(true)) { o[dovi_gpu::Cm4Selected]=1; return DoviDisplaySelection::CM4L8; }
    if (o[dovi_gpu::HasLevel8] == 0) { o[dovi_gpu::Cm4Selected]=1; return DoviDisplaySelection::CM4L3; }
    return DoviDisplaySelection::UnavailableTarget;
}
void doviPrepareActiveArea(float *o, size_t width, size_t height) {
    const float left = o[dovi_gpu::ActiveLeft], right = o[dovi_gpu::ActiveRight];
    const float top = o[dovi_gpu::ActiveTop], bottom = o[dovi_gpu::ActiveBottom];
    const bool valid=width && height && std::isfinite(left) && std::isfinite(right) &&
        std::isfinite(top) && std::isfinite(bottom) && left>=0 && right>=0 && top>=0 && bottom>=0 &&
        double(left)+right<width && double(top)+bottom<height;
    o[dovi_gpu::ActiveLeft] = valid ? left/width : 0;
    o[dovi_gpu::ActiveRight] = valid ? 1-right/width : 1;
    o[dovi_gpu::ActiveTop] = valid ? top/height : 0;
    o[dovi_gpu::ActiveBottom] = valid ? 1-bottom/height : 1;
}
DoviDisplaySelection doviPrepareDisplay(float *gpu, float targetNits,
    DoviDisplayGamut gamut, size_t width, size_t height) {
    const auto selection = doviSelectDisplayTrims(gpu, targetNits, gamut);
    // Work on the caller's snapshot; the immutable picture keeps compatible
    // L1 measurements for later draws on another display or at another target.
    if (gpu[dovi_gpu::Cm4Selected] > .5f)
        gpu[dovi_gpu::SceneMaxPq] = gpu[dovi_gpu::Cm4MaxPq];
    doviPrepareActiveArea(gpu, width, height);
    return selection;
}
} // namespace sp
