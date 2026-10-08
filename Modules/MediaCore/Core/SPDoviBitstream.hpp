// Bounded NAL framing shared by the DV demux adapter and RPU parser.
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace sp {
struct DoviNal { const uint8_t *data; size_t size; };
using DoviParameterSets = std::array<std::vector<uint8_t>, 3>;
inline bool doviSplitNals(const uint8_t *data, size_t size, int ls, std::vector<DoviNal>& nals,
                          bool avc = false) {
    nals.clear();
    const size_t header = avc ? 1 : 2;
    if (!data || size < header || ls < 0 || ls > 4) return false;
    if (ls) {
        size_t pos = 0;
        while (pos < size) {
            if (nals.size() >= 65536) { nals.clear(); return false; }
            if (size - pos < size_t(ls)) { nals.clear(); return false; }
            uint32_t len = 0;
            for (int i = 0; i < ls; ++i) len = (len << 8) | data[pos++];
            if (len < header || len > size - pos) { nals.clear(); return false; }
            nals.push_back({data + pos, len});
            pos += len;
        }
    } else {
        size_t start = size;
        // memchr finds each 0x01 candidate; a 4K AU is several MB of payload.
        for (size_t i = 0; i + 2 < size;) {
            const auto *one = static_cast<const uint8_t *>(memchr(data + i + 2, 1, size - i - 2));
            if (!one) break;
            i = size_t(one - data) - 2;
            if (data[i] || data[i + 1]) { ++i; continue; }
            size_t end = i;
            while (end && data[end - 1] == 0) --end;
            if (start != size) {
                if (nals.size() >= 65536) { nals.clear(); return false; }
                if (end < start + header) { nals.clear(); return false; }
                nals.push_back({data + start, end - start});
            } else {
                // Only leading_zero_8bits may precede the first start code.
                for (size_t k = 0; k < i; ++k)
                    if (data[k]) { nals.clear(); return false; }
            }
            start = i + 3;
            i += 3;
        }
        if (start == size) return false;
        size_t end = size;
        while (end > start && data[end - 1] == 0) --end;
        if (end < start + header) { nals.clear(); return false; }
        nals.push_back({data + start, end - start});
    }
    // Reject forbidden_zero_bit / temporal_id_plus1=0; resource use is bounded
    // by the already-owned packet, with an additional AU-size sanity bound.
    if (nals.size() > 65536) { nals.clear(); return false; }
    for (auto nal : nals) {
        if ((nal.data[0] & 0x80) || (!avc && !(nal.data[1] & 7))) {
            nals.clear(); return false;
        }
    }
    return !nals.empty();
}

// Read only the bounded prefix needed for parameter-set references. The full
// HEVC syntax remains the codec's responsibility; no unbounded Exp-Golomb reads.
// Callers bound the NAL size; `decodedLimit` stops unescaping after that many
// payload bytes when only a slice-header prefix is needed.
class DoviHEVCBits {
    std::vector<uint8_t> bytes_;
    size_t bit_ = 0;
    bool good_ = true;
public:
    explicit DoviHEVCBits(DoviNal nal, size_t decodedLimit = SIZE_MAX) {
        if (nal.size < 3) { good_ = false; return; }
        for (size_t i = 2; i < nal.size && bytes_.size() < decodedLimit; ++i) {
            if (i >= 4 && nal.data[i] == 3 && !nal.data[i-1] && !nal.data[i-2]) {
                if (i + 1 == nal.size || nal.data[i+1] > 3) { good_ = false; return; }
                continue;
            }
            bytes_.push_back(nal.data[i]);
        }
    }
    unsigned read(unsigned n) {
        if (n > 32 || bit_ + n > bytes_.size()*8) { good_ = false; return 0; }
        unsigned value = 0;
        while (n--) { value = (value << 1) | ((bytes_[bit_/8] >> (7-bit_%8)) & 1); ++bit_; }
        return value;
    }
    void skip(unsigned n) { while (n > 32) { read(32); n -= 32; } read(n); }
    unsigned ue() {
        unsigned zeros = 0;
        while (good_ && !read(1)) if (++zeros > 15) { good_ = false; return 0; }
        return ((1u << zeros)-1) + read(zeros);
    }
    bool good() const { return good_; }
};

class DoviParameterBank {
    struct Set { std::vector<uint8_t> bytes; unsigned parent = 0; };
    std::array<Set,16> vps_, sps_;
    std::array<Set,64> pps_;
    size_t bytes_ = 0;
public:
    bool add(DoviNal nal, bool replace = true) {
        if (nal.size < 3 || nal.size > 65536 || (nal.data[0] & 0x80) || !(nal.data[1]&7)) return false;
        const int type = (nal.data[0] >> 1) & 63;
        DoviHEVCBits b(nal);
        unsigned id = 0, parent = 0;
        if (type == 32) id = b.read(4);
        else if (type == 33) {
            parent = b.read(4);
            unsigned sub = b.read(3); b.read(1);
            if (sub > 6) return false;
            b.skip(96); // general profile_tier_level
            unsigned profile[7] = {}, level[7] = {};
            for (unsigned i=0; i<sub; ++i) { profile[i]=b.read(1); level[i]=b.read(1); }
            if (sub) b.skip(2*(8-sub));
            for (unsigned i=0; i<sub; ++i) { if (profile[i]) b.skip(88); if (level[i]) b.skip(8); }
            id = b.ue();
        } else if (type == 34) { id = b.ue(); parent = b.ue(); }
        else return false;
        if (!b.good() || id >= (type == 34 ? 64u : 16u) || parent >= 16) return false;
        Set& set = type == 32 ? vps_[id] : type == 33 ? sps_[id] : pps_[id];
        if (!replace && !set.bytes.empty())
            return set.bytes.size() == nal.size && !memcmp(set.bytes.data(), nal.data, nal.size);
        if (bytes_ - set.bytes.size() + nal.size > 65536) return false;
        bytes_ = bytes_ - set.bytes.size() + nal.size;
        set.bytes.assign(nal.data, nal.data + nal.size); set.parent = parent;
        return true;
    }
    bool select(unsigned pps, DoviParameterSets& out) const {
        if (pps >= pps_.size() || pps_[pps].bytes.empty()) return false;
        const auto& p = pps_[pps]; const auto& s = sps_[p.parent];
        if (s.bytes.empty() || vps_[s.parent].bytes.empty()) return false;
        out = {vps_[s.parent].bytes, s.bytes, p.bytes}; return true;
    }
    bool single(DoviParameterSets& out) const {
        unsigned count = 0, id = 0;
        for (unsigned i=0; i<pps_.size(); ++i) if (!pps_[i].bytes.empty()) { ++count; id=i; }
        return count == 1 && select(id, out);
    }
    bool complete() const {
        DoviParameterSets selected;
        for (unsigned i=0; i<pps_.size(); ++i)
            if (!pps_[i].bytes.empty() && !select(i, selected)) return false;
        return bytes_ && !selected[2].empty();
    }
};

inline bool doviSlicePPS(DoviNal nal, unsigned& pps) {
    if (nal.size < 3 || ((nal.data[0] >> 1) & 63) > 31) return false;
    // Only the prefix is needed even for a multi-megabyte slice.
    DoviHEVCBits b(nal, 2); // first flag, optional IRAP flag, and PPS ID <= 63
    b.read(1); // first_slice_segment_in_pic_flag
    const int type = (nal.data[0] >> 1) & 63;
    if (type >= 16 && type <= 23) b.read(1);
    pps = b.ue(); return b.good() && pps < 64;
}

// hvcC and hvcE carry the same HEVCDecoderConfigurationRecord syntax.
// All-or-nothing: malformed records never replace valid in-band sets.
inline bool doviReadHEVCConfig(const uint8_t *data, size_t size, DoviParameterBank& sets) {
    if (!data || size < 23 || size > 65536 || data[0] != 1) return false;
    DoviParameterBank parsed;
    size_t pos = 23;
    for (unsigned a = 0; a < data[22]; ++a) {
        if (size - pos < 3) return false;
        const int type = data[pos++] & 63;
        const unsigned count = unsigned(data[pos]) * 256 + data[pos+1]; pos += 2;
        for (unsigned n = 0; n < count; ++n) {
            if (size - pos < 2) return false;
            const size_t len = unsigned(data[pos]) * 256 + data[pos+1]; pos += 2;
            if (len < 2 || len > size - pos || (data[pos] & 0x80) || !(data[pos+1] & 7) ||
                ((data[pos] >> 1) & 63) != type) return false;
            if (type >= 32 && type <= 34) {
                if (!parsed.add({data + pos, len}, false)) return false;
            }
            pos += len;
        }
    }
    if (pos != size || !parsed.complete()) return false;
    sets = std::move(parsed);
    return true;
}
inline bool doviReadHEVCConfig(const uint8_t *data, size_t size, DoviParameterSets& sets) {
    DoviParameterBank bank;
    return doviReadHEVCConfig(data, size, bank) && bank.single(sets);
}
} // namespace sp
