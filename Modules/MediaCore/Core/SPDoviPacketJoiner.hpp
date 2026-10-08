// Bounded join of explicitly associated Dolby Vision HEVC tracks/PIDs.
// All non-EL packets retain their original order and FFmpeg properties.
#pragma once
#include "SPDoviConfig.hpp"
#include "SPDoviPacket.hpp"
#include <algorithm>
#include <deque>
#include <memory>
extern "C" {
#include <libavutil/mathematics.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
}
namespace sp {
class DoviPacketJoiner {
    struct FreePacket { void operator()(AVPacket *p) const { av_packet_free(&p); } };
    using Packet = std::unique_ptr<AVPacket, FreePacket>;
    struct BufferedPacket {
        Packet packet;
        size_t bytes;
        int nalLengthSize; // EL queue only: length prefix in effect when it was read
    };
    using PacketQueue = std::deque<BufferedPacket>;
    PacketQueue pending_, retired_, enhancement_;
    size_t bytes_ = 0;
    int base_ = -1, el_ = -1, elLength_ = 0;
    // A raw read error that arrived while older packets were buffered. It is
    // reported after those packets, without another raw read, so the caller
    // still observes it at the I/O position where it happened.
    int deferredError_ = 0;
    AVRational baseTB_{0,1}, elTB_{0,1};
    uint64_t association_ = 0;
    static constexpr size_t maxPackets = 128, maxBytes = 16 * 1024 * 1024;

    static size_t packetCharge(const AVPacket *packet) {
        // A tiny payload can retain a large backing buffer or side-data block.
        // One oversized BL must still be delivered intact. Saturating its charge
        // just above the soft ceiling stops read-ahead without size overflow.
        constexpr size_t limit = maxBytes + 1;
        if (packet->size < 0) return limit;
        size_t bytes = std::min(limit, std::max(size_t(packet->size),
                                              packet->buf ? packet->buf->size : size_t(0)));
        for (int i = 0; i < packet->side_data_elems; ++i) {
            if (packet->side_data[i].size >= limit - bytes) return limit;
            bytes += packet->side_data[i].size;
        }
        return bytes;
    }
    void enqueue(PacketQueue& queue, Packet packet, size_t bytes, int nalLengthSize = 0) {
        queue.push_back({std::move(packet), bytes, nalLengthSize});
        bytes_ += bytes;
    }
    void discardFront(PacketQueue& queue) {
        bytes_ -= queue.front().bytes;
        queue.pop_front();
    }
    int deliverFront(PacketQueue& queue, AVPacket *out) {
        av_packet_unref(out);
        av_packet_move_ref(out, queue.front().packet.get());
        discardFront(queue);
        return 0;
    }
    bool pairEnhancement(BufferedPacket& base) {
        const auto *packet = base.packet.get();
        if (packet->stream_index != base_ || packet->pts == AV_NOPTS_VALUE) return false;
        for (auto it = enhancement_.begin(); it != enhancement_.end(); ++it) {
            if (it->packet->pts == AV_NOPTS_VALUE ||
                av_compare_ts(packet->pts, baseTB_, it->packet->pts, elTB_) != 0) continue;
            AVPacket *el = it->packet.release();
            if (doviAdoptEnhancement(base.packet.get(), &el, it->nalLengthSize)) {
                // Ownership moves into the queued BL. Its EL is still retained
                // during PMT retirement, so the total charge must not shrink.
                base.bytes += it->bytes;
            } else {
                bytes_ -= it->bytes;
            }
            av_packet_free(&el); // null once adopted
            // Consume each EL at most once, including allocation-failure fallback.
            enhancement_.erase(it);
            return true;
        }
        return false;
    }
    void accept(Packet pkt) {
        if (pkt->stream_index == el_) {
            if (pkt->pts == AV_NOPTS_VALUE || pkt->size <= 0) return;
            const size_t bytes = packetCharge(pkt.get());
            if (bytes > maxBytes) return;
            size_t extraSize = 0;
            if (const auto *extra = av_packet_get_side_data(pkt.get(), AV_PKT_DATA_NEW_EXTRADATA, &extraSize))
                elLength_ = doviNalLengthSize(AV_CODEC_ID_HEVC, extra, extraSize);
            enqueue(enhancement_, std::move(pkt), bytes, elLength_);
            while (enhancement_.size() > maxPackets ||
                   (bytes_ > maxBytes && !enhancement_.empty()))
                discardFront(enhancement_);
            return;
        }
        if (pkt->stream_index == base_)
            doviAttachEnhancement(pkt.get(), nullptr, 0, association_);
        const size_t bytes = packetCharge(pkt.get());
        enqueue(pending_, std::move(pkt), bytes);
    }
public:
    void clear() { pending_.clear(); retired_.clear(); enhancement_.clear(); bytes_ = 0; deferredError_ = 0; }
    void configure(int base, int el, AVRational baseTB, AVRational elTB, int elLength) {
        clear(); base_ = base; el_ = el; baseTB_ = baseTB; elTB_ = elTB; elLength_ = elLength;
        ++association_;
    }
    // May be called by readRaw immediately after a changed PMT. Complete only
    // old pairs already present, drain old BL/audio in order, and start a fresh
    // association. No equal PTS can join packets from opposite sides of a PMT.
    void changeAssociation(int el, AVRational elTB, int elLength) {
        for (auto& front : pending_) {
            pairEnhancement(front);
            retired_.push_back(std::move(front));
        }
        pending_.clear();
        while (!enhancement_.empty()) discardFront(enhancement_);
        el_ = el; elTB_ = elTB; elLength_ = elLength; ++association_;
    }
    // A configured BL must still observe PMT changes while its EL is absent.
    bool configured() const { return base_ >= 0; }
    bool active() const { return configured() && el_ >= 0; }
    int enhancementStream() const { return el_; }
    // Retained payload/side-data charge; an oversized packet saturates at maxBytes + 1.
    size_t bufferedBytes() const { return bytes_; }
    template<class Read> int read(AVPacket *out, Read&& readRaw) {
        if (!configured()) return readRaw(out);
        // BL without an associated EL: nothing to join, so read in place. Only
        // the BL carries the association epoch. A PMT seen inside readRaw may
        // associate an EL; that packet then joins through the queues below.
        if (!active() && pending_.empty() && retired_.empty() && !deferredError_) {
            const int status = readRaw(out);
            Packet joined(status >= 0 && active() ? av_packet_alloc() : nullptr);
            if (!joined) {
                if (status >= 0 && out->stream_index == base_)
                    doviAttachEnhancement(out, nullptr, 0, association_);
                return status;
            }
            av_packet_move_ref(joined.get(), out);
            accept(std::move(joined));
        }
        size_t reads = 0;
        for (;;) {
            if (!retired_.empty()) return deliverFront(retired_, out);
            if (!pending_.empty()) {
                auto& front = pending_.front();
                const bool ready = !active() || front.packet->stream_index != base_ ||
                                   front.packet->pts == AV_NOPTS_VALUE || pairEnhancement(front);
                // B-frame PTS is not monotonic: a later PTS alone is never
                // evidence of a missing EL. Bound waiting by packets/bytes.
                if (ready || deferredError_ < 0 || reads >= maxPackets ||
                    pending_.size() >= maxPackets || bytes_ >= maxBytes)
                    return deliverFront(pending_, out);
            }
            if (deferredError_ < 0) {
                const int error = deferredError_;
                clear();
                return error;
            }
            Packet pkt(av_packet_alloc());
            if (!pkt) return AVERROR(ENOMEM);
            const int status = readRaw(pkt.get());
            ++reads;
            if (status == AVERROR_EXIT) { clear(); return status; }
            if (status < 0) { deferredError_ = status; continue; }
            accept(std::move(pkt));
        }
    }
};
} // namespace sp
