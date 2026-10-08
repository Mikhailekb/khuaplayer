// Demux-side Dolby Vision transport for one input: explicit BL/EL stream
// association, MPEG-TS PMT tracking, the bounded BL/EL packet join and the
// byte replay that keeps an EL PES muxed ahead of its BL RAP. Owned by the
// demux thread; Demuxer keeps only call sites. Holds no FFmpeg pointers, so a
// recovery that replaces the AVFormatContext can never leave one dangling.
#pragma once
#include "SPDoviPacketJoiner.hpp"
#include "SPDoviStreamAssociation.hpp"
#include <functional>
#include <vector>
extern "C" {
#include <libavformat/avformat.h>
}

namespace sp {

class DoviTransport {
public:
    // Stream-table rebuild, before per-stream info: EL-only streams become
    // dependent (never selectable as video) and each BL with exactly one
    // explicitly associated EL advertises the combined configuration.
    void prepareStreams(AVFormatContext *fmt) {
        enhancements_.assign(fmt->nb_streams, -1);
        for (unsigned i = 0; i < fmt->nb_streams; ++i) {
            const int base = doviBaseStream(fmt, i);
            if (base >= 0) enhancements_[base] = enhancements_[base] == -1 ? int(i) : -2;
        }
        for (unsigned i = 0; i < fmt->nb_streams; ++i) {
            AVStream *s = fmt->streams[i];
            const auto *cfg = doviConfig(s->codecpar);
            if (cfg && doviHEVCDualLayerProfile(cfg->dv_profile) && !cfg->bl_present_flag)
                s->disposition |= AV_DISPOSITION_DEPENDENT;
            if (enhancements_[i] >= 0 &&
                !doviPublishCombinedConfig(s->codecpar, fmt->streams[enhancements_[i]]->codecpar))
                enhancements_[i] = -1;
        }
    }

    // After stream selection. A dual-layer BL in an MPEG-TS program stays
    // configured without an EL so a later PMT can still attach one.
    void select(AVFormatContext *fmt, int video, bool mpegts) {
        reset();
        if (video < 0 || unsigned(video) >= enhancements_.size()) return;
        const int el = std::max(enhancements_[video], -1);
        const AVStream *base = fmt->streams[video];
        const auto *cfg = doviConfig(base->codecpar);
        const AVProgram *program = mpegts && cfg && doviHEVCDualLayerProfile(cfg->dv_profile)
            ? av_find_program_from_stream(fmt, nullptr, video) : nullptr;
        if (el < 0 && !program) return;
        video_ = video;
        configureJoiner(fmt, el);
        if (program) {
            programId_ = program->id;
            pmtVersion_ = program->pmt_version;
            streamCount_ = fmt->nb_streams;
        }
    }

    void reset() {
        joiner_.configure(-1, -1, {0, 1}, {0, 1}, 0);
        video_ = programId_ = pmtVersion_ = elId_ = -1;
        streamCount_ = 0;
        errorPosBefore_ = reportedErrorPos_ = -1;
    }
    // Seek or any other repositioning: buffered packets are stale.
    void clear() {
        joiner_.clear();
        errorPosBefore_ = -1;
    }

    bool configured() const { return joiner_.configured(); }
    bool active() const { return joiner_.active(); }
    int enhancementStream() const { return joiner_.enhancementStream(); }

    // Stream-discard predicate beyond the selected streams. A backward seek can
    // reactivate a formerly associated EL before the next read returns its PMT,
    // so every dual-layer EL of a tracked program keeps its PES available.
    bool retainsStream(const AVStream *s, int index) const {
        if (index == enhancementStream()) return true;
        if (programId_ < 0) return false;
        const auto *cfg = doviConfig(s->codecpar);
        return cfg && doviHEVCDualLayerProfile(cfg->dv_profile) && !cfg->bl_present_flag;
    }

    // Playback read. `raw` reads one packet from `fmt`. Returns true in
    // `associationChanged` when a PMT added, removed or replaced the EL (the
    // caller re-applies stream discard). A deferred raw error keeps the AVIO
    // position of the read that failed: see takeReportedErrorPos().
    template <class Raw>
    int read(AVPacket *out, AVFormatContext *fmt, Raw &&raw, bool *associationChanged) {
        reportedErrorPos_ = -1;
        const int ret = joiner_.read(out, [&](AVPacket *p) {
            const int64_t before = fmt->pb ? avio_tell(fmt->pb) : 0;
            const int status = raw(p);
            if (status >= 0) { if (refresh(fmt)) *associationChanged = true; }
            else errorPosBefore_ = before;
            return status;
        });
        if (ret < 0) {
            reportedErrorPos_ = errorPosBefore_;
            errorPosBefore_ = -1;
        }
        return ret;
    }
    // Probe reads (RAP scans, landing verification): no PMT tracking.
    template <class Raw>
    int readProbe(AVPacket *out, Raw &&raw) { return joiner_.read(out, raw); }

    // AVIO position before the raw read whose error the latest read() reported
    // after delivering packets buffered ahead of it, or -1. Consumed on read.
    int64_t takeReportedErrorPos() {
        const int64_t pos = reportedErrorPos_;
        reportedErrorPos_ = -1;
        return pos;
    }

    // Byte offset that replays a BL RAP together with its paired EL PES, which
    // mpegts may deliver after the BL although it starts before it.
    static int64_t landingPos(const AVPacket *base) {
        int64_t pos = base->pos;
        if (const auto *el = doviPacketEnhancement(base); el && el->packet->pos >= 0)
            pos = pos >= 0 ? std::min(pos, el->packet->pos) : el->packet->pos;
        return pos;
    }

    // MPEG-TS byte replay of a BL RAP at `pos` (absolute pts in us). A RAP
    // paired while probing already includes its EL in `pos`. Otherwise the EL
    // PES ended before the BL PES: look back a bounded window for it. The look
    // back honors `abortFn`; a superseded seek simply replays from `pos`.
    int tsByteReplay(AVFormatContext *fmt, int video, int64_t pos, int64_t ptsUs, bool paired,
                     const std::function<bool()> *abortFn) {
        clear();
        int64_t from = pos;
        const int el = enhancementStream();
        if (!paired && el >= 0 && pos > 0 && ptsUs != AV_NOPTS_VALUE)
            from = lookBackForEnhancement(fmt, video, el, pos, ptsUs, abortFn);
        return av_seek_frame(fmt, video, from, AVSEEK_FLAG_BYTE);
    }

private:
    DoviPacketJoiner joiner_;
    std::vector<int> enhancements_; // per stream: associated EL, -1 none, -2 ambiguous
    int video_ = -1, programId_ = -1, pmtVersion_ = -1, elId_ = -1;
    unsigned streamCount_ = 0;
    int64_t errorPosBefore_ = -1, reportedErrorPos_ = -1;

    void configureJoiner(AVFormatContext *fmt, int el) {
        const AVStream *e = el >= 0 ? fmt->streams[el] : nullptr;
        joiner_.configure(video_, el, fmt->streams[video_]->time_base,
                          e ? e->time_base : AVRational{0, 1}, e ? doviNalLengthSize(e->codecpar) : 0);
        elId_ = e ? e->id : -1;
    }

    // Tracked TS programs only. Looks the program up by id on every call:
    // one or a few programs, and no pointer survives a context replacement.
    bool refresh(AVFormatContext *fmt) {
        if (programId_ < 0) return false;
        const AVProgram *program = nullptr;
        for (unsigned i = 0; i < fmt->nb_programs && !program; ++i)
            if (fmt->programs[i]->id == programId_) program = fmt->programs[i];
        const int version = program ? program->pmt_version : -1;
        if (version == pmtVersion_ && fmt->nb_streams == streamCount_) return false;
        pmtVersion_ = version;
        streamCount_ = fmt->nb_streams;
        const int el = program ? doviUniqueEnhancement(fmt, video_) : -1;
        const AVStream *e = el >= 0 ? fmt->streams[el] : nullptr;
        const int id = e ? e->id : -1;
        if (el == enhancementStream() && id == elId_) return false;
        elId_ = id;
        joiner_.changeAssociation(el, e ? e->time_base : AVRational{0, 1},
                                  e ? doviNalLengthSize(e->codecpar) : 0);
        return true;
    }

    int64_t lookBackForEnhancement(AVFormatContext *fmt, int video, int el, int64_t pos,
                                   int64_t ptsUs, const std::function<bool()> *abortFn) {
        constexpr int64_t kLookBack = 4ll << 20;
        constexpr int kMaxPackets = 4096;
        int64_t from = pos;
        if (av_seek_frame(fmt, video, std::max<int64_t>(0, pos - kLookBack), AVSEEK_FLAG_BYTE) < 0)
            return from;
        AVPacket *p = av_packet_alloc();
        if (!p) return from;
        const AVRational tb = fmt->streams[el]->time_base;
        // mpegts delivers a PES when it completes, so an EL that starts earlier
        // can still arrive after its BL: read until two later BL pictures.
        int later = 0;
        for (int n = 0; n < kMaxPackets && !(abortFn && (*abortFn)()) &&
                        av_read_frame(fmt, p) >= 0; ++n) {
            const int64_t at = p->pos;
            const bool found = p->stream_index == el && p->pts != AV_NOPTS_VALUE && at >= 0 &&
                               av_rescale_q(p->pts, tb, AV_TIME_BASE_Q) == ptsUs;
            const bool base = p->stream_index == video;
            av_packet_unref(p);
            if (found) { from = std::min(at, pos); break; }
            if (base && at > pos && ++later >= 2) break;
        }
        av_packet_free(&p);
        return from;
    }
};

} // namespace sp
