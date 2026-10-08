#pragma once
#include "SPDoviConfig.hpp"
#include <cstdlib>
#include <climits>
extern "C" {
#include <libavformat/avformat.h>
}
namespace sp {
// Only explicit container association is accepted. Never infer EL from its
// resolution, track order, filename or the presence of a second video track.
inline int doviBaseStream(const AVFormatContext *fmt, unsigned el) {
    const AVStream *s = fmt->streams[el];
    const auto *cfg = doviConfig(s->codecpar);
    // Preserve an explicit P3 identity even when its config is unsupported:
    // publishing it on BL lets the open/preview gate reject an unsafe raw base.
    if (s->codecpar->codec_id != AV_CODEC_ID_HEVC || !cfg || cfg->bl_present_flag ||
        (cfg->dv_profile != 3 && (!doviHEVCDualLayerSupported(s->codecpar) ||
         !cfg->el_present_flag || !cfg->rpu_present_flag))) return -1;
    const auto *ref = av_dict_get(s->metadata, "sp.dovi.base_id", nullptr, 0);
    if (!ref || !ref->value[0]) return -1;
    char *end = nullptr;
    const long id = strtol(ref->value, &end, 10);
    if (!end || *end || id < 0 || id > INT_MAX) return -1;
    int base = -1;
    for (unsigned i = 0; i < fmt->nb_streams; ++i) {
        const auto *b = fmt->streams[i];
        if (i == el || b->id != id || b->codecpar->codec_id != AV_CODEC_ID_HEVC ||
            b->codecpar->codec_type != AVMEDIA_TYPE_VIDEO ||
            (b->disposition & (AV_DISPOSITION_DEPENDENT | AV_DISPOSITION_ATTACHED_PIC))) continue;
        const auto *bc = doviConfig(b->codecpar);
        if (bc && (bc->dv_profile != cfg->dv_profile || !bc->bl_present_flag ||
                   (cfg->dv_profile != 7 &&
                    bc->dv_bl_signal_compatibility_id != cfg->dv_bl_signal_compatibility_id))) continue;
        if (base >= 0) return -1; // duplicate IDs are ambiguous
        base = int(i);
    }
    if (base < 0) return -1;
    if (fmt->nb_programs) {
        bool shared = false;
        for (unsigned p = 0; p < fmt->nb_programs; ++p) {
            bool hasBase = false, hasEL = false;
            const AVProgram *program = fmt->programs[p];
            for (unsigned j = 0; j < program->nb_stream_indexes; ++j) {
                hasBase |= program->stream_index[j] == unsigned(base);
                hasEL |= program->stream_index[j] == el;
            }
            shared |= hasBase && hasEL;
        }
        if (!shared) return -1;
    }
    return base;
}
// The single EL whose explicit association names `base`; -1 when there is
// none or more than one (ambiguous association never pairs).
inline int doviUniqueEnhancement(const AVFormatContext *fmt, int base) {
    int el = -1;
    for (unsigned i = 0; i < fmt->nb_streams; ++i) {
        if (doviBaseStream(fmt, i) != base) continue;
        if (el >= 0) return -1;
        el = int(i);
    }
    return el;
}
// An EL with an hvcC (MP4/MKV) that cannot be carried is not associated: the
// BL then keeps its own configuration and plays alone. Transport-stream ELs
// expose Annex-B parameter sets, which also travel in-band.
inline bool doviPublishCombinedConfig(AVCodecParameters *base, const AVCodecParameters *el) {
    const auto *cfg = doviConfig(el);
    if (!cfg) return false;
    if (el->extradata_size > 0 && el->extradata[0] == 1 &&
        !doviStoreEnhancementConfig(base, el->extradata, el->extradata_size)) return false;
    auto *copy = static_cast<AVDOVIDecoderConfigurationRecord *>(av_memdup(cfg, sizeof(*cfg)));
    if (!copy) return false;
    copy->bl_present_flag = 1;
    if (!av_packet_side_data_add(&base->coded_side_data, &base->nb_coded_side_data,
        AV_PKT_DATA_DOVI_CONF, reinterpret_cast<uint8_t *>(copy), sizeof(*copy), 0)) {
        av_free(copy); return false;
    }
    return true;
}
} // namespace sp
