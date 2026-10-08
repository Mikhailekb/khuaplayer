#pragma once

#include <cstdint>
#include <functional>
#include <utility>
#include <vector>

#include "TsRapPolicy.hpp"

struct AVFormatContext;
struct AVPacket;

namespace sp {

struct SPTsRapObservation {
    int64_t fromDtsUs = 0;
    int64_t untilDtsUs = 0;
    bool fromHead = false;
    bool untilEof = false;
};

// Optional shadow-reader association (e.g. Dolby BL/EL). It must preserve BL
// PTS, include actual read-ahead in bytesRead and obey the remaining byte
// budget. flush drops buffered packets at every seek. Null keeps raw FFmpeg.
struct SPTsRapPacketReader {
    std::function<int(AVPacket *, int64_t remainingBytes, int64_t& bytesRead)> read;
    std::function<void()> flush;
};

struct SPTsRapScanResult {
    int64_t pos = -1;
    int64_t ptsUs = INT64_MIN;

    AVPacket *keyPkt = nullptr;
    bool capped = false;
    bool aborted = false;

    bool fromHead = false;
    bool reachedFloor = false;

    bool spanExhausted = false;
    int64_t bytes = 0;
    int64_t videoPkts = 0;
    int64_t reorderMaxUs = 0;
    std::vector<std::pair<int64_t, int64_t>> keys;
    std::vector<SPTsRapObservation> observed;

    SPTsRapScanResult() = default;
    SPTsRapScanResult(const SPTsRapScanResult &) = delete;
    SPTsRapScanResult &operator=(const SPTsRapScanResult &) = delete;
    SPTsRapScanResult(SPTsRapScanResult &&o) noexcept { *this = std::move(o); }
    SPTsRapScanResult &operator=(SPTsRapScanResult &&o) noexcept;
    ~SPTsRapScanResult();
};

inline SPTsRapLimits spThumbTsRapLimits(int64_t bytesPerSec = 0) {
    SPTsRapLimits lim;
    lim.maxSpanUs = 30LL * 1000000;
    constexpr int64_t kMiB = 1024 * 1024;
    int64_t bytes = bytesPerSec > 0 ? bytesPerSec * 24 : 32 * kMiB;
    if (bytes < 16 * kMiB) bytes = 16 * kMiB;
    if (bytes > 48 * kMiB) bytes = 48 * kMiB;
    lim.maxBytes = bytes;
    lim.maxVideoPackets = 4096;
    return lim;
}

inline int64_t spThumbTsRapCompletionBytes(int64_t maxBytes) {
    return maxBytes + maxBytes / 2;
}

SPTsRapScanResult spTsRapScanBackward(AVFormatContext *ctx, int videoStream,
                                      int64_t absUs, int64_t floorAbsUs,
                                      const SPTsRapLimits &lim, int64_t *gopUsInOut,
                                      const std::function<bool()> *abort,
                                      const SPTsRapPacketReader *packets = nullptr);

} // namespace sp
