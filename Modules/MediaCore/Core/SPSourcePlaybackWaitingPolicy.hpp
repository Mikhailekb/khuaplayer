#pragma once
#include <cstdint>

// A slow source read is not necessarily visible to the viewer: queued packets
// can keep playing normally. This main-thread policy reports only a sustained
// playback hold or a seek that is actually blocked on source I/O.
namespace spplaywait {
inline constexpr int64_t kNoticeDelayUs = 750000;
enum class WaitReason : uint8_t { none = 0, sourceIO = 1, pipelineHold = 2 };

// A visible hold can wait for decoded/queued media even when no source read is
// pending. Classification changes the explanation only, not the hold policy.
inline WaitReason waitReason(bool visibleWaiting, bool rawWaiting) {
    if (!visibleWaiting) return WaitReason::none;
    return rawWaiting ? WaitReason::sourceIO : WaitReason::pipelineHold;
}

struct Input {
    int64_t nowUs = 0;
    uint64_t openGeneration = 0;
    int64_t seekGeneration = 0;
    bool sessionActive = false;
    bool sourceEligible = false;
    bool playing = false;
    bool rebufferHold = false;
    bool audioStarved = false;
    bool seekPending = false;
    bool seekFramePending = false;
    bool rawWaiting = false;
};
struct Decision {
    bool waiting = false;
    bool blocking = false;
    bool changed = false;
};
class Policy {
public:
    Decision update(const Input& in) {
        // A delayed callback cannot restore a notice from an older source/seek.
        if (hasIdentity_ && (in.openGeneration < openGeneration_ ||
            (in.openGeneration == openGeneration_ && in.seekGeneration < seekGeneration_))) {
            return {waiting_, false, false};
        }
        const bool old = waiting_;
        const bool clockMovedBack = hasIdentity_ && in.nowUs < lastNowUs_;
        if (!hasIdentity_ || in.openGeneration != openGeneration_ || in.seekGeneration != seekGeneration_) {
            hasIdentity_ = true;
            openGeneration_ = in.openGeneration;
            seekGeneration_ = in.seekGeneration;
            sinceUs_ = -1;
            waiting_ = false;
        }
        lastNowUs_ = in.nowUs;
        const bool blocking = in.sessionActive && in.sourceEligible &&
            ((in.playing && (in.rebufferHold || (in.audioStarved && in.rawWaiting))) ||
             ((in.seekPending || in.seekFramePending) && in.rawWaiting));
        if (!blocking) {
            sinceUs_ = -1;
            waiting_ = false;
        } else {
            if (sinceUs_ < 0 || clockMovedBack) sinceUs_ = in.nowUs;
            waiting_ = in.nowUs >= sinceUs_ && in.nowUs - sinceUs_ >= kNoticeDelayUs;
        }
        return {waiting_, blocking, waiting_ != old};
    }
    bool reset() {
        const bool old = waiting_;
        hasIdentity_ = false;
        waiting_ = false;
        sinceUs_ = -1;
        lastNowUs_ = 0;
        return old;
    }
    bool waiting() const { return waiting_; }
private:
    bool hasIdentity_ = false;
    bool waiting_ = false;
    int64_t sinceUs_ = -1;
    int64_t lastNowUs_ = 0;
    uint64_t openGeneration_ = 0;
    int64_t seekGeneration_ = 0;
};
} // namespace spplaywait
