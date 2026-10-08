// Built INSIDE the pinned FFmpeg source tree, then archived into libavcodec.
// Keep all access to private FFmpeg structures here, never in the app ABI.
#include "sp_dovi_rpu.h"
#include "libavcodec/dovi_rpu.h"
#include "libavcodec/defs.h"
#include "libavutil/mem.h"
#include "libavutil/error.h"

struct SPDoviParserContext {
    DOVIContext context;
    AVDOVIDecoderConfigurationRecord config;
};

SPDoviParserContext *sp_dovi_parser_create(int profile, int compatibility, int compression)
{
    SPDoviParserContext *p = av_mallocz(sizeof(*p));
    if (p) {
        p->context.cfg.dv_profile = profile;
        p->context.cfg.dv_bl_signal_compatibility_id = compatibility;
        p->context.cfg.dv_md_compression = compression;
        p->config = p->context.cfg;
    }
    return p;
}

void sp_dovi_parser_free(SPDoviParserContext **p)
{
    if (p && *p) {
        ff_dovi_ctx_unref(&(*p)->context);
        av_freep(p);
    }
}

void sp_dovi_parser_flush(SPDoviParserContext *p)
{
    if (p) {
        ff_dovi_ctx_flush(&p->context);
        // Some parser errors unref the whole context, including cfg.
        p->context.cfg = p->config;
    }
}

int sp_dovi_parser_parse(SPDoviParserContext *p, const uint8_t *rbsp,
                         size_t size, AVDOVIMetadata **metadata)
{
    if (!metadata) return AVERROR(EINVAL);
    *metadata = NULL;
    if (!p || !rbsp) return AVERROR(EINVAL);
    int ret = ff_dovi_rpu_parse(&p->context, rbsp, size,
                               AV_EF_CRCCHECK | AV_EF_EXPLODE);
    if (ret >= 0) ret = ff_dovi_get_metadata(&p->context, metadata);
    if (ret < 0) sp_dovi_parser_flush(p);
    return ret;
}
