#include "TsRapScan.hpp"
#include <algorithm>

extern "C" {
#include <libavformat/avformat.h>
}

namespace sp {

SPTsRapScanResult &SPTsRapScanResult::operator=(SPTsRapScanResult &&o) noexcept {
    if (this != &o) {
        if (keyPkt) av_packet_free(&keyPkt);
        pos = o.pos; ptsUs = o.ptsUs; keyPkt = o.keyPkt; capped = o.capped;
        aborted = o.aborted; fromHead = o.fromHead; reachedFloor = o.reachedFloor;
        spanExhausted = o.spanExhausted;
        bytes = o.bytes; videoPkts = o.videoPkts; reorderMaxUs = o.reorderMaxUs;
        keys = std::move(o.keys); observed = std::move(o.observed);
        o.keyPkt = nullptr;
    }
    return *this;
}

SPTsRapScanResult::~SPTsRapScanResult() {
    if (keyPkt) av_packet_free(&keyPkt);
}

namespace {

struct SegmentTracker {
    int64_t fromDts = INT64_MIN;
    int64_t untilDts = INT64_MIN;
    void note(int64_t dts) {
        if (dts == INT64_MIN) return;
        if (fromDts == INT64_MIN) fromDts = dts;
        untilDts = dts;
    }
    bool valid() const { return fromDts != INT64_MIN; }
};

void publishSegment(SPTsRapScanResult &res, const SegmentTracker &seg, bool fromHead, bool untilEof) {
    if (!seg.valid()) return;
    SPTsRapObservation o;
    o.fromDtsUs = seg.fromDts;
    o.untilDtsUs = seg.untilDts;
    o.fromHead = fromHead;
    o.untilEof = untilEof;
    res.observed.push_back(o);
}

} // namespace

SPTsRapScanResult spTsRapScanBackward(AVFormatContext *ctx, int videoStream,
                                      int64_t absUs, int64_t floorAbsUs,
                                      const SPTsRapLimits &lim, int64_t *gopUsInOut,
                                      const std::function<bool()> *abort,
                                      const SPTsRapPacketReader *packets) {
    SPTsRapScanResult res;
    if (!ctx || videoStream < 0 || (unsigned)videoStream >= ctx->nb_streams) return res;
    AVStream *st = ctx->streams[videoStream];
    const AVRational tb = st->time_base;
    const int64_t gopUs = gopUsInOut ? *gopUsInOut : 0;

    AVPacket *probe = av_packet_alloc();
    if (!probe) return res;
    struct PacketGuard {
        AVPacket **p;
        ~PacketGuard() { av_packet_free(p); }
    } guard{&probe};
    auto readPacket = [&](int64_t remaining) {
        int64_t bytes = 0;
        const int result = packets ? packets->read(probe, remaining, bytes) : av_read_frame(ctx, probe);
        res.bytes += packets ? bytes : result >= 0 ? std::max(probe->size, 0) : 0;
        return result;
    };

    auto observePacket = [&](int64_t pts, int64_t dts, bool key, int64_t pos) {
        if (pts != INT64_MIN && dts != INT64_MIN && pts - dts > res.reorderMaxUs)
            res.reorderMaxUs = pts - dts;
        if (key && pos >= 0 && pts != INT64_MIN) res.keys.push_back({pts, pos});
    };

    int64_t bestPos = -1, bestPts = INT64_MIN;
    int64_t prevKeyPts = INT64_MIN;
    int64_t gopSample = 0;
    int64_t hiUs = absUs;
    int64_t loUs = absUs - spTsRapWindowUs(gopUs, 0);
    const int64_t spanFloorUs = absUs - lim.maxSpanUs;
    if (loUs < spanFloorUs) loUs = spanFloorUs;
    for (int attempt = 0;; ++attempt) {
        if (abort && (*abort)()) { res.aborted = true; return res; }
        if (loUs < floorAbsUs) loUs = floorAbsUs;
        if (packets) packets->flush();

        const bool headWindow = loUs == floorAbsUs &&
                                av_seek_frame(ctx, videoStream, 0, AVSEEK_FLAG_BYTE) >= 0;
        if (!headWindow) {
            const int64_t ts = av_rescale_q(loUs, AV_TIME_BASE_Q, tb);
            if (avformat_seek_file(ctx, videoStream, INT64_MIN, ts, ts, 0) < 0) break;
        }
        int64_t prevDts = INT64_MIN;
        bool discontinuity = false;
        bool hitEof = false;
        bool readError = false;
        SegmentTracker seg;
        for (;;) {
            if (abort && (*abort)()) {

                publishSegment(res, seg, headWindow, false);
                res.aborted = true;
                return res;
            }

            SPTsRapLimits winLim = lim;
            if (bestPos >= 0) winLim.maxBytes = spThumbTsRapCompletionBytes(lim.maxBytes);
            if (spTsRapExhausted(winLim, absUs - loUs, res.bytes, res.videoPkts)) {
                res.capped = true;
                break;
            }
            const int rd = readPacket(winLim.maxBytes - res.bytes);
            if (rd < 0) {

                if (rd == AVERROR_EOF) { hitEof = true; break; }
                if (rd == AVERROR_EXIT) {
                    publishSegment(res, seg, headWindow, false);
                    res.aborted = true;
                    return res;
                }
                readError = true;
                break;
            }
            if (probe->stream_index != videoStream) {
                av_packet_unref(probe);
                continue;
            }
            ++res.videoPkts;
            const int64_t pts = probe->pts != AV_NOPTS_VALUE
                                    ? av_rescale_q(probe->pts, tb, AV_TIME_BASE_Q)
                                    : INT64_MIN;
            const int64_t dts = probe->dts != AV_NOPTS_VALUE
                                    ? av_rescale_q(probe->dts, tb, AV_TIME_BASE_Q)
                                    : pts;
            const bool key = (probe->flags & AV_PKT_FLAG_KEY) != 0;
            const int64_t pos = probe->pos;
            if (dts != INT64_MIN && prevDts != INT64_MIN && dts < prevDts) {
                av_packet_unref(probe);
                discontinuity = true;
                break;
            }
            if (dts != INT64_MIN) prevDts = dts;
            seg.note(dts);
            observePacket(pts, dts, key, pos);
            if (key && pos >= 0 && pts != INT64_MIN) {
                if (prevKeyPts != INT64_MIN && pts > prevKeyPts) gopSample = pts - prevKeyPts;
                prevKeyPts = pts;
                if (pts <= absUs) {
                    bestPos = pos;
                    bestPts = pts;
                    if (!res.keyPkt) res.keyPkt = av_packet_alloc();
                    if (res.keyPkt) { av_packet_unref(res.keyPkt); av_packet_ref(res.keyPkt, probe); }
                }
            }
            av_packet_unref(probe);
            if (dts != INT64_MIN && dts > hiUs) break;
        }

        if (!discontinuity) publishSegment(res, seg, headWindow, hitEof);
        if (!discontinuity && !readError && !res.capped && loUs == floorAbsUs) res.reachedFloor = true;
        if (readError) res.capped = true;
        if (bestPos >= 0 || discontinuity || res.capped) break;
        if (loUs == floorAbsUs) break;
        if (loUs <= spanFloorUs) {
            res.capped = true;
            res.spanExhausted = true;
            break;
        }
        hiUs = loUs;
        loUs = absUs - spTsRapWindowUs(gopUs, attempt + 1);

        if (loUs < spanFloorUs) loUs = spanFloorUs;
        if (spTsRapExhausted(lim, absUs - loUs, res.bytes, res.videoPkts)) {
            res.capped = true;
            break;
        }
    }

    if (bestPos < 0 && !res.aborted) {
        if (packets) packets->flush();

        bool positioned = av_seek_frame(ctx, videoStream, 0, AVSEEK_FLAG_BYTE) >= 0;
        if (!positioned) {
            const int64_t ts = av_rescale_q(floorAbsUs, AV_TIME_BASE_Q, tb);
            positioned = avformat_seek_file(ctx, videoStream, INT64_MIN, ts, ts, 0) >= 0;
        }
        if (positioned) {
            int64_t fbBytes = 0, fbPkts = 0;
            SegmentTracker seg;
            for (;;) {
                if (abort && (*abort)()) {
                    publishSegment(res, seg, /*fromHead=*/true, /*untilEof=*/false);
                    res.aborted = true;
                    return res;
                }
                if (fbBytes > 4LL * 1024 * 1024 || fbPkts > 256) {
                    publishSegment(res, seg, /*fromHead=*/true, /*untilEof=*/false);
                    res.capped = true;
                    return res;
                }
                const int64_t before = res.bytes;
                const int rd = readPacket(4LL * 1024 * 1024 - fbBytes);
                fbBytes += res.bytes - before;
                if (rd < 0) {
                    if (rd == AVERROR_EXIT) {
                        publishSegment(res, seg, /*fromHead=*/true, /*untilEof=*/false);
                        res.aborted = true;
                        return res;
                    }
                    break;
                }
                if (probe->stream_index != videoStream) { av_packet_unref(probe); continue; }
                ++fbPkts;
                ++res.videoPkts;
                const bool key = (probe->flags & AV_PKT_FLAG_KEY) != 0;
                const int64_t pos = probe->pos;
                const int64_t pts = probe->pts != AV_NOPTS_VALUE
                                        ? av_rescale_q(probe->pts, tb, AV_TIME_BASE_Q)
                                        : INT64_MIN;
                const int64_t dts = probe->dts != AV_NOPTS_VALUE
                                        ? av_rescale_q(probe->dts, tb, AV_TIME_BASE_Q)
                                        : pts;
                seg.note(dts);
                observePacket(pts, dts, key, pos);
                if (key && pos >= 0 && pts != INT64_MIN) {
                    bestPos = pos; bestPts = pts; res.capped = false; res.fromHead = true;
                    if (!res.keyPkt) res.keyPkt = av_packet_alloc();
                    if (res.keyPkt) { av_packet_unref(res.keyPkt); av_packet_ref(res.keyPkt, probe); }
                    av_packet_unref(probe);
                    break;
                }
                av_packet_unref(probe);
            }
            publishSegment(res, seg, /*fromHead=*/true, /*untilEof=*/false);
        }
    }
    if (bestPos >= 0 && res.keyPkt) {
        res.pos = bestPos;
        res.ptsUs = bestPts;
        if (gopUsInOut) *gopUsInOut = spTsRapBlendGopUs(gopUs, gopSample);
    } else if (res.keyPkt) {
        av_packet_free(&res.keyPkt);
    }
    return res;
}

} // namespace sp
