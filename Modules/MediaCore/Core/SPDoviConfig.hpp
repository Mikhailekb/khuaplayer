// DV transport data in public FFmpeg structures. No private FFmpeg ABI.
#pragma once
#include "SPDoviBitstream.hpp"
#include <cstring>
#include <string>
extern "C" {
#include <libavcodec/codec_par.h>
#include <libavcodec/packet.h>
#include <libavutil/dict.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mem.h>
}

namespace sp {
inline const AVDOVIDecoderConfigurationRecord *doviConfig(const AVCodecParameters *par) {
    if (!par) return nullptr;
    const auto *side = av_packet_side_data_get(par->coded_side_data,
        par->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    return side && side->size >= sizeof(AVDOVIDecoderConfigurationRecord)
        ? reinterpret_cast<const AVDOVIDecoderConfigurationRecord *>(side->data) : nullptr;
}
inline int doviNalLengthSize(AVCodecID codec, const uint8_t *extra, size_t size) {
    if (!extra || !size || extra[0] != 1) return 0;
    if (codec == AV_CODEC_ID_H264) return size >= 7 ? (extra[4] & 3) + 1 : 0;
    return codec == AV_CODEC_ID_HEVC && size >= 23 ? (extra[21] & 3) + 1 : 0;
}
inline int doviNalLengthSize(const AVCodecParameters *par) {
    return par ? doviNalLengthSize(par->codec_id, par->extradata,
                                   par->extradata_size > 0 ? par->extradata_size : 0) : 0;
}
inline bool doviMetadataCompressionSupported(int compression) {
    // Configuration IDs differ from the RPU's dm_compression method: both
    // LIMITED and EXTENDED can reuse static DM (method 1). Reserved ID 2 and
    // dynamic DM compression methods remain unsupported by the pinned parser.
    return compression == AV_DOVI_COMPRESSION_NONE ||
           compression == AV_DOVI_COMPRESSION_LIMITED ||
           compression == AV_DOVI_COMPRESSION_EXTENDED;
}
inline bool doviLegacyHEVCProfile(int profile) {
    return profile == 2 || profile == 3 || profile == 4 || profile == 6;
}
inline bool doviHEVCDualLayerProfile(int profile) {
    return profile == 7 || doviLegacyHEVCProfile(profile);
}
// Input recognition only. P20 is a bounded base-view reconstruction path;
// accepting its RPU does not implement cinema DM or stereoscopic presentation.
inline bool doviMappingSupported(const AVCodecParameters *par) {
    const auto *cfg = doviConfig(par);
    if (!cfg) return false;
    const int p = cfg->dv_profile, c = cfg->dv_bl_signal_compatibility_id;
    if (par->codec_id == AV_CODEC_ID_H264) return p == 9 && c == 2 && !cfg->el_present_flag;
    if (par->codec_id == AV_CODEC_ID_AV1)
        return p == 10 && !cfg->el_present_flag && (c == 0 || c == 1 || c == 2 || c == 4);
    if (par->codec_id != AV_CODEC_ID_HEVC) return false;
    // RPU parsing additionally gates the supported PQ reconstruction subset.
    // P3 has no compatible BL and requires reconstructed output on every frame.
    if (doviLegacyHEVCProfile(p))
        return c == (p == 3 ? 0 : p == 6 ? 1 : 2) && cfg->el_present_flag && cfg->rpu_present_flag &&
               cfg->dv_md_compression == AV_DOVI_COMPRESSION_NONE;
    return p == 5 || p == 7 || (p == 8 && (c == 1 || c == 2 || c == 4)) ||
           (p == 20 && !cfg->el_present_flag &&
            doviMetadataCompressionSupported(cfg->dv_md_compression) && (c == 0 || c == 4));
}
inline bool doviHEVCDualLayerSupported(const AVCodecParameters *par) {
    const auto *cfg = doviConfig(par);
    return cfg && doviHEVCDualLayerProfile(cfg->dv_profile) &&
           par->codec_id == AV_CODEC_ID_HEVC && doviMappingSupported(par);
}
// OpenIssued only. A BL may omit VUI; its signaled compatibility then fills
// each unspecified field (declared fields always win) and takes precedence
// over resolution heuristics. Returns whether any field was filled.
// - Legacy P4 (SDR) / P6 (HDR10) bases: primaries, transfer, matrix and range.
// - P8/P10/P20 HDR10 (1) or HLG (4) bases: BT.2020 primaries/matrix and PQ/HLG.
inline bool doviFillBaseColor(int profile, int compatibility,
    int& primaries, int& transfer, int& matrix, int& range) {
    const int before[4] = {primaries, transfer, matrix, range};
    if (doviLegacyHEVCProfile(profile) && profile != 3 && compatibility == (profile == 6 ? 1 : 2)) {
        const bool hdr = compatibility == 1;
        if (primaries == AVCOL_PRI_UNSPECIFIED) primaries = hdr ? AVCOL_PRI_BT2020 : AVCOL_PRI_BT709;
        if (transfer == AVCOL_TRC_UNSPECIFIED) transfer = hdr ? AVCOL_TRC_SMPTE2084 : AVCOL_TRC_BT709;
        if (matrix == AVCOL_SPC_UNSPECIFIED) matrix = hdr ? AVCOL_SPC_BT2020_NCL : AVCOL_SPC_BT709;
        if (range == AVCOL_RANGE_UNSPECIFIED) range = AVCOL_RANGE_MPEG;
    } else if ((profile == 8 || profile == 10 || profile == 20) && (compatibility == 1 || compatibility == 4)) {
        if (transfer == AVCOL_TRC_UNSPECIFIED)
            transfer = compatibility == 1 ? AVCOL_TRC_SMPTE2084 : AVCOL_TRC_ARIB_STD_B67;
        if (primaries == AVCOL_PRI_UNSPECIFIED) primaries = AVCOL_PRI_BT2020;
        if (matrix == AVCOL_SPC_UNSPECIFIED) matrix = AVCOL_SPC_BT2020_NCL;
    }
    return before[0] != primaries || before[1] != transfer || before[2] != matrix || before[3] != range;
}
inline bool doviRequiresUnsupportedMetadata(const AVCodecParameters *par) {
    const auto *cfg=doviConfig(par);
    // P3 cannot use its undecorated BL if its configuration is unsupported.
    if (cfg && cfg->dv_profile == 3) return !doviMappingSupported(par);
    // Dolby's public P20 notes forbid displaying a compressed P20.0 signal
    // when that compression is unsupported; it has no compatible base view.
    return cfg && cfg->dv_profile==20 && cfg->dv_bl_signal_compatibility_id==0 &&
           !doviMetadataCompressionSupported(cfg->dv_md_compression);
}
// Shared by playback and previews. Rejection of an intact unsupported RPU is
// distinct from an absent RPU: uncompressed P20.0 retains its fixed fallback,
// while P3 and compressed P20.0 require valid metadata on each output picture.
struct DoviMetadataPolicy {
    bool requireFrameMetadata = false;
    bool rejectUnsupportedRPU = false;
};
inline DoviMetadataPolicy doviMetadataPolicy(const AVDOVIDecoderConfigurationRecord *cfg) {
    if (!cfg) return {};
    const bool p3 = cfg->dv_profile == 3;
    const bool p20 = cfg->dv_profile == 20 && cfg->dv_bl_signal_compatibility_id == 0;
    return {p3 || (p20 && cfg->dv_md_compression != AV_DOVI_COMPRESSION_NONE), p3 || p20};
}
inline bool doviStoreEnhancementConfig(AVCodecParameters *par, const uint8_t *data, size_t size) {
    DoviParameterBank checked;
    if (!doviReadHEVCConfig(data, size, checked)) return false;
    static const char hex[] = "0123456789abcdef";
    std::string value(size * 2, '\0');
    for (size_t i = 0; i < size; ++i) {
        value[2*i] = hex[data[i] >> 4]; value[2*i+1] = hex[data[i] & 15];
    }
    AVDictionary *dict = nullptr;
    const auto *old = av_packet_side_data_get(par->coded_side_data,
        par->nb_coded_side_data, AV_PKT_DATA_STRINGS_METADATA);
    if (old && av_packet_unpack_dictionary(old->data, old->size, &dict) < 0) {
        av_dict_free(&dict); return false;
    }
    if (av_dict_set(&dict, "sp.dovi.el_config.v1", value.c_str(), 0) < 0) {
        av_dict_free(&dict); return false;
    }
    size_t packedSize = 0;
    uint8_t *packed = av_packet_pack_dictionary(dict, &packedSize);
    av_dict_free(&dict);
    if (!packed) return false;
    if (!av_packet_side_data_add(&par->coded_side_data, &par->nb_coded_side_data,
        AV_PKT_DATA_STRINGS_METADATA, packed, packedSize, 0)) { av_free(packed); return false; }
    return true;
}
template<class Sets>
inline bool doviReadEnhancementConfig(const AVCodecParameters *par, Sets& sets) {
    const auto *side = av_packet_side_data_get(par->coded_side_data,
        par->nb_coded_side_data, AV_PKT_DATA_STRINGS_METADATA);
    if (!side || side->size > 256 * 1024) return false;
    AVDictionary *dict = nullptr;
    bool valid = false;
    if (av_packet_unpack_dictionary(side->data, side->size, &dict) >= 0) {
        const auto *entry = av_dict_get(dict, "sp.dovi.el_config.v1", nullptr, 0);
        if (entry) {
            const size_t n = strlen(entry->value);
            if (n >= 46 && n <= 131072 && !(n % 2)) {
                std::vector<uint8_t> bytes(n / 2);
                auto digit = [](char c) { return c >= '0' && c <= '9' ? c-'0' :
                    c >= 'a' && c <= 'f' ? c-'a'+10 : -1; };
                bool hex = true;
                for (size_t i = 0; i < bytes.size(); ++i) {
                    const int a = digit(entry->value[2*i]), b = digit(entry->value[2*i+1]);
                    if (a < 0 || b < 0) { hex = false; break; }
                    bytes[i] = uint8_t(a*16+b);
                }
                valid = hex && doviReadHEVCConfig(bytes.data(), bytes.size(), sets);
            }
        }
    }
    av_dict_free(&dict);
    return valid;
}
} // namespace sp
