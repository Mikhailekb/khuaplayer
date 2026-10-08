// Bounded packet ownership for the P10 VideoToolbox-to-picture-decoder handoff.
// Decoder creation, output filtering and the actual handoff stay with its caller.
#pragma once
#include <climits>
#include <cstdint>
#include <cstring>
#include <memory>
#include <utility>
#include <vector>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/mem.h>
}

namespace sp {
class DoviAV1Replay {
    struct FreeParameters {
        void operator()(AVCodecParameters *p) const { avcodec_parameters_free(&p); }
    };
    struct FreePacket {
        void operator()(AVPacket *p) const { av_packet_free(&p); }
    };
    using Packet = std::unique_ptr<AVPacket, FreePacket>;
    std::unique_ptr<AVCodecParameters, FreeParameters> parameters_;
    std::vector<Packet> packets_;
    size_t bytes_ = 0;
    bool complete_ = false;
    bool configurationValid_ = false;

    bool replaceConfiguration(const uint8_t *extra, size_t size) {
        // A failed update must not let a later key restart with the old config.
        // Keep the owned bytes intact until their replacement is fully copied.
        configurationValid_ = false;
        if (size > MaxBytes || size > INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE) return false;
        auto *copy = static_cast<uint8_t *>(av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE));
        if (!copy) return false;
        memcpy(copy, extra, size);
        av_freep(&parameters_->extradata);
        parameters_->extradata = copy;
        parameters_->extradata_size = static_cast<int>(size);
        configurationValid_ = true;
        return true;
    }

public:
    static constexpr size_t MaxBytes = 16 * 1024 * 1024;
    static constexpr size_t MaxPackets = 256;
    bool required = false;
    int64_t returnedThrough = INT64_MIN;

    explicit DoviAV1Replay(const AVCodecParameters *source)
        : parameters_(avcodec_parameters_alloc()) {
        if (parameters_ && avcodec_parameters_copy(parameters_.get(), source) < 0)
            parameters_.reset();
        configurationValid_ = bool(parameters_);
    }
    const AVCodecParameters *parameters() const {
        return configurationValid_ ? parameters_.get() : nullptr;
    }
    const auto& packets() const { return packets_; }
    bool ready() const { return configurationValid_ && complete_ && !packets_.empty(); }
    void clear() {
        packets_.clear(); bytes_ = 0; complete_ = false;
        // Seek/window eviction cannot repair a failed codec-config update or
        // undo a picture-association requirement discovered earlier.
    }
    // Seek: the retained GOP and the presentation frontier both restart.
    void resetForSeek() { clear(); returnedThrough = INT64_MIN; }
    void remember(const AVPacket *packet) {
        if (!parameters_ || !packet || packet->size <= 0) { clear(); return; }
        size_t extraSize = 0;
        if (const auto *extra = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &extraSize)) {
            clear();
            if (!replaceConfiguration(extra, extraSize)) return;
        }
        if (!configurationValid_) return;
        if (packet->flags & AV_PKT_FLAG_KEY) { clear(); complete_ = true; }
        if (!complete_) return;

        // Count the entire retained buffer and each cloned side-data block.
        // Subtract before adding so oversized metadata cannot wrap the budget.
        size_t cost = packet->buf ? packet->buf->size : size_t(packet->size);
        if (packets_.size() >= MaxPackets || cost > MaxBytes) { clear(); return; }
        for (int i = 0; i < packet->side_data_elems; ++i) {
            const size_t size = packet->side_data[i].size;
            if (size > MaxBytes - cost) { clear(); return; }
            cost += size;
        }
        if (cost > MaxBytes - bytes_) { clear(); return; }
        Packet copy(av_packet_clone(packet));
        if (!copy) { clear(); return; }
        packets_.push_back(std::move(copy)); bytes_ += cost;
    }
};
} // namespace sp
