// Ref-counted EL packet carried with its matching BL through packet queues,
// prelude/race clones and GOP replay. No BL copy and no timestamp rewriting.
#pragma once
#include <cstdint>
extern "C" {
#include <libavcodec/packet.h>
#include <libavutil/buffer.h>
#include <libavutil/mem.h>
}
namespace sp {
struct DoviPacketEnhancement {
    uint64_t magic;
    AVPacket *packet;
    int nalLengthSize;
    uint64_t association;
};
inline constexpr uint64_t kDoviPacketMagic = UINT64_C(0x5350444f56494531);
inline const DoviPacketEnhancement *doviPacketContext(const AVPacket *base) {
    if (!base || !base->opaque_ref || base->opaque_ref->size != sizeof(DoviPacketEnhancement)) return nullptr;
    const auto *p = reinterpret_cast<const DoviPacketEnhancement *>(base->opaque_ref->data);
    return p->magic == kDoviPacketMagic ? p : nullptr;
}
inline const DoviPacketEnhancement *doviPacketEnhancement(const AVPacket *base) {
    const auto *p = doviPacketContext(base);
    return p && p->packet ? p : nullptr;
}
inline size_t doviReferencedPacketBytes(const AVPacket *base) {
    auto packetBytes = [](const AVPacket *p) {
        size_t bytes = p->size >= 0 ? size_t(p->size) : SIZE_MAX;
        for (int i = 0; i < p->side_data_elems && bytes != SIZE_MAX; ++i)
            bytes = p->side_data[i].size <= SIZE_MAX - bytes ? bytes + p->side_data[i].size : SIZE_MAX;
        return bytes;
    };
    size_t bytes = packetBytes(base);
    if (const auto *el = doviPacketEnhancement(base)) {
        const size_t extra = packetBytes(el->packet);
        bytes = extra <= SIZE_MAX - bytes ? bytes + extra : SIZE_MAX;
    }
    return bytes;
}
inline bool doviAttachEnhancement(AVPacket *base, const AVPacket *el, int nalLengthSize,
                                  uint64_t association = 0) {
    const auto *old = doviPacketContext(base);
    if (base->opaque_ref && (!old || old->packet)) return false;
    if (old && !association) association = old->association;
    auto *p = static_cast<DoviPacketEnhancement *>(av_mallocz(sizeof(DoviPacketEnhancement)));
    if (!p) return false;
    p->magic = kDoviPacketMagic;
    p->nalLengthSize = nalLengthSize;
    p->association = association;
    p->packet = el ? av_packet_clone(el) : nullptr;
    if (el && !p->packet) { av_free(p); return false; }
    // Not flagged read-only: the joiner may still fill in the EL of a context
    // it created and nobody else references (see doviAdoptEnhancement).
    auto *ref = av_buffer_create(reinterpret_cast<uint8_t *>(p), sizeof(*p),
        [](void *, uint8_t *data) {
            auto *owned = reinterpret_cast<DoviPacketEnhancement *>(data);
            av_packet_free(&owned->packet);
            av_free(owned);
        }, nullptr, 0);
    if (!ref) { av_packet_free(&p->packet); av_free(p); return false; }
    av_buffer_unref(&base->opaque_ref);
    base->opaque_ref = ref;
    return true;
}
// Attaches `*el` and takes ownership (sets it to null) when `base` carries an
// EL-less context referenced only by this packet: no allocation or copy.
// Otherwise attaches a clone and leaves `*el` with the caller.
inline bool doviAdoptEnhancement(AVPacket *base, AVPacket **el, int nalLengthSize) {
    const auto *context = doviPacketContext(base);
    if (context && !context->packet && av_buffer_is_writable(base->opaque_ref)) {
        auto *owned = reinterpret_cast<DoviPacketEnhancement *>(base->opaque_ref->data);
        owned->packet = *el;
        owned->nalLengthSize = nalLengthSize;
        *el = nullptr;
        return true;
    }
    return doviAttachEnhancement(base, *el, nalLengthSize);
}
} // namespace sp
