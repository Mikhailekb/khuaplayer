#pragma once
#include <algorithm>
#include <cstdint>
#include <limits>
#include <vector>

// Cache coverage is a fact about resident bytes, not a bitrate estimate or a
// promise that every decoder dependency is ready. Unknown gaps stay unknown.
namespace spcachetime {
struct ByteRange { int64_t lower = 0, upper = 0; };
struct TimeRange { int64_t lower = 0, upper = 0; };
struct Point { int64_t position = -1, timeUs = -1; };
struct Span { int64_t byteLower = -1, byteUpper = -1, timeLower = -1, timeUpper = -1; };
struct StreamMap { int stream = -1; std::vector<Span> spans; };
struct SourceMap {
    int64_t sourceSize = 0, durationUs = 0;
    std::vector<StreamMap> streams;
};

// Fast MP4 opens can have a known stream duration before FFmpeg fills the
// format duration. Use the same metadata fallback as the playback core.
inline int64_t metadataDuration(int64_t formatUs, int64_t primaryStreamUs) {
    return formatUs > 0 ? formatUs : std::max<int64_t>(0, primaryStreamUs);
}

inline std::vector<ByteRange> normalizeBytes(std::vector<ByteRange> in, int64_t size) {
    std::vector<ByteRange> out;
    if (size <= 0) return out;
    for (auto &r : in) { r.lower = std::max<int64_t>(0, r.lower); r.upper = std::min(size, r.upper); }
    std::sort(in.begin(), in.end(), [](auto a, auto b) { return a.lower < b.lower || (a.lower == b.lower && a.upper < b.upper); });
    for (const auto &r : in) {
        if (r.lower >= r.upper) continue;
        if (!out.empty() && r.lower <= out.back().upper) out.back().upper = std::max(out.back().upper, r.upper);
        else out.push_back(r);
    }
    return out;
}

inline bool covers(const std::vector<ByteRange> &bytes, int64_t lower, int64_t upper) {
    if (lower < 0 || upper <= lower) return false;
    auto it = std::upper_bound(bytes.begin(), bytes.end(), lower, [](int64_t p, const ByteRange &r) { return p < r.lower; });
    if (it == bytes.begin()) return false;
    --it;
    return it->lower <= lower && it->upper >= upper;
}

inline std::vector<TimeRange> normalizeTimes(std::vector<TimeRange> in, int64_t duration) {
    std::vector<TimeRange> out;
    for (auto &r : in) { r.lower = std::max<int64_t>(0, r.lower); if (duration > 0) r.upper = std::min(duration, r.upper); }
    std::sort(in.begin(), in.end(), [](auto a, auto b) { return a.lower < b.lower || (a.lower == b.lower && a.upper < b.upper); });
    for (const auto &r : in) {
        if (r.lower >= r.upper) continue;
        if (!out.empty() && r.lower <= out.back().upper) out.back().upper = std::max(out.back().upper, r.upper);
        else out.push_back(r);
    }
    return out;
}

// Adjacent real index anchors delimit a conservative physical interval. A
// partially cached interval is omitted instead of interpolating through VBR.
inline std::vector<Span> indexSpans(std::vector<Point> points, int64_t size, int64_t duration) {
    std::vector<Span> out;
    std::sort(points.begin(), points.end(), [](auto a, auto b) { return a.position < b.position || (a.position == b.position && a.timeUs < b.timeUs); });
    std::vector<Point> valid;
    for (const auto &p : points) {
        if (p.position < 0 || p.position >= size || p.timeUs < 0 || (duration > 0 && p.timeUs >= duration)) continue;
        if (!valid.empty() && (p.position <= valid.back().position || p.timeUs <= valid.back().timeUs)) continue;
        valid.push_back(p);
    }
    for (size_t i = 1; i < valid.size(); ++i)
        out.push_back({valid[i-1].position, valid[i].position, valid[i-1].timeUs, valid[i].timeUs});
    // A static file's declared end is useful only as the final interval end;
    // it never invents a starting anchor for an otherwise unindexed source.
    if (!valid.empty() && duration > valid.back().timeUs && size > valid.back().position)
        out.push_back({valid.back().position, size, valid.back().timeUs, duration});
    return out;
}

inline std::vector<TimeRange> covered(const std::vector<Span> &spans, const std::vector<ByteRange> &bytes, int64_t duration) {
    std::vector<TimeRange> out;
    for (const auto &s : spans)
        if (s.timeLower >= 0 && s.timeUpper > s.timeLower && covers(bytes, s.byteLower, s.byteUpper)) out.push_back({s.timeLower, s.timeUpper});
    return normalizeTimes(std::move(out), duration);
}

inline std::vector<TimeRange> intersect(const std::vector<TimeRange> &a, const std::vector<TimeRange> &b) {
    std::vector<TimeRange> out;
    size_t i = 0, j = 0;
    while (i < a.size() && j < b.size()) {
        const int64_t lower = std::max(a[i].lower, b[j].lower), upper = std::min(a[i].upper, b[j].upper);
        if (upper > lower) out.push_back({lower, upper});
        if (a[i].upper < b[j].upper) ++i; else ++j;
    }
    return out;
}
} // namespace spcachetime
