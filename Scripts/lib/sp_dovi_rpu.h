// Narrow adapter to the parser in the pinned FFmpeg build.
// The private DOVIContext never crosses the library boundary.
#ifndef SP_DOVI_RPU_H
#define SP_DOVI_RPU_H
#include <stddef.h>
#include <stdint.h>
#include <libavutil/dovi_meta.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SPDoviParserContext SPDoviParserContext;
SPDoviParserContext *sp_dovi_parser_create(int profile, int compatibility, int compression);
void sp_dovi_parser_free(SPDoviParserContext **parser);
void sp_dovi_parser_flush(SPDoviParserContext *parser);
// Padded unescaped RBSP (HEVC 0x19 prefix, or AV1 P10 EMDF envelope).
// Metadata is owned by caller
// and freed with av_free(). Returns its byte size, zero, or an AVERROR.
int sp_dovi_parser_parse(SPDoviParserContext *parser, const uint8_t *rbsp,
                         size_t size, AVDOVIMetadata **metadata);
#ifdef __cplusplus
}
#endif
#endif
