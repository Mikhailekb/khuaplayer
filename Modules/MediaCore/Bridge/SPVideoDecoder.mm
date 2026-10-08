#include "SPVideoDecoder.h"
#include "SPVideoColorMetadata.hpp"
#include "SPAnnexBStartCode.hpp"
#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CMFormatDescription.h>
#include <mutex>
#include <atomic>
#include <condition_variable>
#include <vector>
#include <map>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/pixdesc.h>
}

#include "SPRuntimeGates.hpp"

static void spAVBufferBlockFree(void *refCon, void *doomedMemoryBlock, size_t sizeInBytes) {
    (void)doomedMemoryBlock; (void)sizeInBytes;
    AVBufferRef *ref = (AVBufferRef *)refCon;
    av_buffer_unref(&ref);
}

#pragma mark - Process-wide decoder initialization

static std::mutex gVtFirstSessionMtx;
static std::atomic<bool> gVtDriverLoaded{false};

extern "C" BOOL SPVideoToolboxDriverLoaded(void) {
    return gVtDriverLoaded.load(std::memory_order_acquire) ? YES : NO;
}

#pragma mark - Codec mapping

static constexpr CMVideoCodecType spFourCC(char a, char b, char c, char d) {
    return (CMVideoCodecType)(((uint32_t)a << 24) | ((uint32_t)b << 16) | ((uint32_t)c << 8) | (uint32_t)d);
}

static constexpr uint32_t spFFmpegCodecTag(char a, char b, char c, char d) {
    return (uint32_t)(uint8_t)a | ((uint32_t)(uint8_t)b << 8) |
           ((uint32_t)(uint8_t)c << 16) | ((uint32_t)(uint8_t)d << 24);
}

static CMVideoCodecType codecTypeForFFmpeg(AVCodecID id, int profile) {
    switch (id) {
        case AV_CODEC_ID_H264:  return kCMVideoCodecType_H264;
        case AV_CODEC_ID_HEVC:  return kCMVideoCodecType_HEVC;
        case AV_CODEC_ID_VP9:   return spFourCC('v','p','0','9');
        case AV_CODEC_ID_AV1:   return spFourCC('a','v','0','1');
        case AV_CODEC_ID_MPEG2VIDEO: return spFourCC('m','p','2','v');
        case AV_CODEC_ID_MPEG4: return spFourCC('m','p','4','v');
        case AV_CODEC_ID_VC1:   return spFourCC('v','c','1',' ');
        case AV_CODEC_ID_VP8:   return spFourCC('v','p','0','8');
        case AV_CODEC_ID_PRORES: {
            switch (profile) {
                case AV_PROFILE_PRORES_PROXY:    return spFourCC('a','p','c','o');
                case AV_PROFILE_PRORES_LT:       return spFourCC('a','p','c','s');
                case AV_PROFILE_PRORES_STANDARD: return spFourCC('a','p','c','n');
                case AV_PROFILE_PRORES_HQ:       return spFourCC('a','p','c','h');
                case AV_PROFILE_PRORES_4444:     return spFourCC('a','p','4','h');
                case AV_PROFILE_PRORES_XQ:       return spFourCC('a','p','4','x');
                default:                         return spFourCC('a','p','c','n');
            }
        }
        default: return 0;
    }
}

static inline void spAppendDescrLength(std::vector<uint8_t> &b, int len) {
    if (len < 0x80) { b.push_back((uint8_t)len); return; }
    uint8_t tmp[4];
    int n = 0;
    while (len > 0) { tmp[n++] = (uint8_t)(len & 0x7F); len >>= 7; }
    for (int i = n - 1; i >= 0; i--) {
        b.push_back((uint8_t)(tmp[i] | (i > 0 ? 0x80 : 0)));
    }
}

#pragma mark - Annex-B conversion

static inline int spNALType(uint8_t firstByte, bool hevc) {
    return hevc ? ((firstByte >> 1) & 0x3F) : (firstByte & 0x1F);
}
static inline bool spNALIsVCL(int type, bool hevc) {
    return hevc ? (type <= 31) : (type >= 1 && type <= 5);
}

static inline size_t spFindStartCodePos(const uint8_t *d, size_t size, size_t from) {
    return spvideo::findStartCode(d, size, from);
}

#define SPLOG(fmt, ...) NSLog(@"[c%u]" fmt, self->_spLogId, ##__VA_ARGS__)

static void spExtractAnnexBParams(const uint8_t *data, size_t size, int wantedType, bool hevc,
                                  std::vector<const uint8_t *> &ptrs, std::vector<size_t> &sizes) {
    size_t pos = 0;
    while (pos < size) {
        size_t sc = spFindStartCodePos(data, size, pos);
        if (sc == SIZE_MAX) break;
        size_t scLen = (data[sc + 2] == 1) ? 3 : 4;
        size_t nalStart = sc + scLen;
        size_t nextSc = spFindStartCodePos(data, size, nalStart);
        size_t nalEnd = (nextSc == SIZE_MAX) ? size : nextSc;
        size_t nalLen = nalEnd - nalStart;
        if (nalLen > 0) {
            int type = spNALType(data[nalStart], hevc);
            if (type == wantedType) {
                ptrs.push_back(data + nalStart);
                sizes.push_back(nalLen);
            }
        }
        if (nextSc == SIZE_MAX) break;
        pos = nextSc;
    }
}

static inline bool spIsScanParameterSet(int type, bool hevc);
static void spAppendScanParameterSet(std::vector<uint8_t> &out,
                                     const uint8_t *data, size_t size);

static void spAnnexBToAVCC(const uint8_t *in, size_t inSize,
                           std::vector<uint8_t> &out, bool hevc,
                           std::vector<uint8_t> *parameterSets) {
    size_t pos = 0;
    bool reachedVCL = false;
    while (pos < inSize) {
        size_t sc = spFindStartCodePos(in, inSize, pos);
        if (sc == SIZE_MAX) break;
        size_t scLen = (in[sc + 2] == 1) ? 3 : 4;
        size_t nalStart = sc + scLen;
        size_t nextSc = spFindStartCodePos(in, inSize, nalStart);
        size_t nalEnd = (nextSc == SIZE_MAX) ? inSize : nextSc;
        size_t nalLen = nalEnd - nalStart;
        if (nalLen > 0 && parameterSets && !reachedVCL) {
            int type = spNALType(in[nalStart], hevc);
            bool vcl = spNALIsVCL(type, hevc);
            reachedVCL = vcl;
            if (!vcl && spIsScanParameterSet(type, hevc)) {
                spAppendScanParameterSet(*parameterSets, in + nalStart, nalLen);
            }
        }

        out.push_back((uint8_t)(nalLen >> 24));
        out.push_back((uint8_t)(nalLen >> 16));
        out.push_back((uint8_t)(nalLen >> 8));
        out.push_back((uint8_t)nalLen);
        out.insert(out.end(), in + nalStart, in + nalStart + nalLen);
        if (nextSc == SIZE_MAX) break;
        pos = nextSc;
    }
}

static uint64_t spParamSetFpAvcc(const uint8_t *d, size_t size, bool hevc) {
    uint64_t fp = 0;
    size_t i = 0;
    while (i + 4 <= size) {
        uint32_t len = ((uint32_t)d[i] << 24) | ((uint32_t)d[i + 1] << 16) |
                       ((uint32_t)d[i + 2] << 8) | d[i + 3];
        i += 4;
        if (len == 0 || i + len > size) break;
        int t = spNALType(d[i], hevc);
        bool ps = hevc ? (t == 32 || t == 33 || t == 34) : (t == 7 || t == 8);
        if (ps) {
            size_t n = len;
            while (n > 0 && d[i + n - 1] == 0) n--;
            if (!fp) fp = 1469598103934665603ull;
            for (size_t j = 0; j < n; j++) { fp ^= d[i + j]; fp *= 1099511628211ull; }
        }
        i += len;
    }
    return fp;
}

static uint64_t spParamSetFpAnnexB(const uint8_t *d, size_t size, bool hevc) {
    uint64_t fp = 0;
    size_t pos = 0;
    while (pos < size) {
        size_t sc = spFindStartCodePos(d, size, pos);
        if (sc == SIZE_MAX) break;
        size_t scLen = (d[sc + 2] == 1) ? 3 : 4;
        size_t nalStart = sc + scLen;
        size_t nextSc = spFindStartCodePos(d, size, nalStart);
        size_t nalEnd = (nextSc == SIZE_MAX) ? size : nextSc;
        if (nalEnd > nalStart) {
            int t = spNALType(d[nalStart], hevc);
            bool ps = hevc ? (t == 32 || t == 33 || t == 34) : (t == 7 || t == 8);
            if (ps) {
                size_t n = nalEnd - nalStart;
                while (n > 0 && d[nalStart + n - 1] == 0) n--;
                if (!fp) fp = 1469598103934665603ull;
                for (size_t j = 0; j < n; j++) { fp ^= d[nalStart + j]; fp *= 1099511628211ull; }
            }
        }
        if (nextSc == SIZE_MAX) break;
        pos = nextSc;
    }
    return fp;
}

static inline bool spIsScanParameterSet(int type, bool hevc) {
    return hevc ? (type == 32 || type == 33 || type == 34)
                : (type == 7 || type == 8);
}

static void spAppendScanParameterSet(std::vector<uint8_t> &out,
                                     const uint8_t *data, size_t size) {
    static const uint8_t startCode[] = {0, 0, 0, 1};
    out.insert(out.end(), startCode, startCode + sizeof(startCode));
    out.insert(out.end(), data, data + size);
}

enum class SPScanDataKind {
    Extradata,
    AnnexB,
    LengthPrefixed,
};

struct SPNormalizedScanParameterSets {
    std::vector<uint8_t> bytes;
    bool valid = true;
};

// Normalize H.264/HEVC parameter sets into Annex-B. Packet framing is supplied
// by the decoder instead of guessed from payload bytes: a valid length-prefixed
// NAL can itself contain 00 00 01 and must never be mistaken for Annex-B.
static SPNormalizedScanParameterSets spNormalizedScanParameterSets(
    const uint8_t *data, size_t size, bool hevc, SPScanDataKind kind,
    int nalLengthSize) {
    SPNormalizedScanParameterSets result;
    std::vector<uint8_t> &out = result.bytes;
    auto invalid = [&]() -> SPNormalizedScanParameterSets {
        result.bytes.clear();
        result.valid = false;
        return result;
    };
    if (!data || size == 0) return result;
    if (size < 4) return invalid();
    const bool beginsWithAnnexBStartCode =
        (size >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1) ||
        (size >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 &&
         data[3] == 1);
    if (kind == SPScanDataKind::AnnexB ||
        (kind == SPScanDataKind::Extradata && beginsWithAnnexBStartCode)) {
        size_t firstStart = spFindStartCodePos(data, size, 0);
        if (firstStart == SIZE_MAX) return invalid();
        size_t pos = firstStart;
        while (pos < size) {
            size_t sc = spFindStartCodePos(data, size, pos);
            if (sc == SIZE_MAX) break;
            size_t scLen = data[sc + 2] == 1 ? 3 : 4;
            size_t nal = sc + scLen;
            if (nal >= size) return invalid();
            size_t next = spFindStartCodePos(data, size, nal);
            size_t end = next == SIZE_MAX ? size : next;
            // A HEVC NAL header is two bytes.  Treat a truncated header as
            // malformed instead of letting FFmpeg COMPLETE_FRAMES make the
            // access unit look semantically covered.
            const size_t headerBytes = hevc ? 2u : 1u;
            if (end - nal < headerBytes) return invalid();
            int type = spNALType(data[nal], hevc);
            // The normal case is AUD/SEI followed by a VCL NAL. Once VCL
            // begins, no parameter set later in that access unit can describe
            // the current picture; stop before scanning a large slice payload.
            bool vcl = spNALIsVCL(type, hevc);
            if (vcl && !spIsScanParameterSet(type, hevc)) break;
            if (end > nal) {
                if (spIsScanParameterSet(type, hevc)) {
                    while (end > nal && data[end - 1] == 0) end--;
                    spAppendScanParameterSet(out, data + nal, end - nal);
                }
            }
            if (next == SIZE_MAX) break;
            pos = next;
        }
        return result;
    }

    if (kind == SPScanDataKind::Extradata && data[0] == 1 &&
        !hevc && size >= 7) { // avcC
        size_t pos = 5;
        int spsCount = data[pos++] & 0x1f;
        for (int group = 0; group < 2; ++group) {
            if (group != 0 && pos >= size) return invalid();
            int count = group == 0 ? spsCount : data[pos++];
            for (int i = 0; i < count; ++i) {
                if (pos + 2 > size) return invalid();
                size_t len = ((size_t)data[pos] << 8) | data[pos + 1];
                pos += 2;
                if (len == 0 || pos + len > size) return invalid();
                spAppendScanParameterSet(out, data + pos, len);
                pos += len;
            }
        }
        return result;
    }
    if (kind == SPScanDataKind::Extradata && data[0] == 1 &&
        hevc && size >= 23) { // hvcC
        size_t pos = 22;
        int arrays = data[pos++];
        for (int a = 0; a < arrays; ++a) {
            if (pos + 3 > size) return invalid();
            int type = data[pos++] & 0x3f;
            int count = ((int)data[pos] << 8) | data[pos + 1];
            pos += 2;
            for (int i = 0; i < count; ++i) {
                if (pos + 2 > size) return invalid();
                size_t len = ((size_t)data[pos] << 8) | data[pos + 1];
                pos += 2;
                if (len == 0 || pos + len > size) return invalid();
                if (spIsScanParameterSet(type, true)) {
                    spAppendScanParameterSet(out, data + pos, len);
                }
                pos += len;
            }
        }
        if (pos != size) return invalid();
        return result;
    }

    if (kind == SPScanDataKind::Extradata) return invalid();

    if (nalLengthSize < 1 || nalLengthSize > 4) return invalid();
    size_t pos = 0;
    while (pos < size) {
        if (pos + (size_t)nalLengthSize > size) return invalid();
        size_t len = 0;
        for (int i = 0; i < nalLengthSize; ++i) {
            len = (len << 8) | data[pos + (size_t)i];
        }
        pos += (size_t)nalLengthSize;
        if (len == 0 || pos + len > size) return invalid();
        if (len < (hevc ? 2u : 1u)) return invalid();
        int type = spNALType(data[pos], hevc);
        bool vcl = spNALIsVCL(type, hevc);
        if (vcl && !spIsScanParameterSet(type, hevc)) break;
        if (spIsScanParameterSet(type, hevc)) {
            spAppendScanParameterSet(out, data + pos, len);
        }
        pos += len;
    }
    return result;
}

static uint64_t spBytesFp(const uint8_t *data, size_t size) {
    if (!data || size == 0) return 0;
    uint64_t fp = 1469598103934665603ull;
    for (size_t i = 0; i < size; ++i) {
        fp ^= data[i];
        fp *= 1099511628211ull;
    }
    return fp;
}

// Both inputs are normalized Annex B parameter sets. An AU may repeat only
// its PPS (common in P7 MEL); that is not a new configuration when every
// repeated NAL is byte-identical to one already retained by the parser.
static bool spScanParameterSetsRepeatSubset(const std::vector<uint8_t> &incoming,
                                            const std::vector<uint8_t> &known) {
    if (incoming.empty() || known.empty()) return false;
    size_t pos = 0;
    while (pos < incoming.size()) {
        const size_t start = spFindStartCodePos(incoming.data(), incoming.size(), pos);
        if (start == SIZE_MAX) return false;
        const size_t nal = start + (incoming[start + 2] == 1 ? 3 : 4);
        const size_t next = spFindStartCodePos(incoming.data(), incoming.size(), nal);
        size_t end = next == SIZE_MAX ? incoming.size() : next;
        while (end > nal && incoming[end - 1] == 0) --end;
        if (end <= nal) return false;
        bool found = false;
        size_t knownPos = 0;
        while (knownPos < known.size()) {
            const size_t ks = spFindStartCodePos(known.data(), known.size(), knownPos);
            if (ks == SIZE_MAX) break;
            const size_t kn = ks + (known[ks + 2] == 1 ? 3 : 4);
            const size_t kNext = spFindStartCodePos(known.data(), known.size(), kn);
            size_t ke = kNext == SIZE_MAX ? known.size() : kNext;
            while (ke > kn && known[ke - 1] == 0) --ke;
            if (ke - kn == end - nal &&
                memcmp(known.data() + kn, incoming.data() + nal, end - nal) == 0) {
                found = true;
                break;
            }
            if (kNext == SIZE_MAX) break;
            knownPos = kNext;
        }
        if (!found) return false;
        if (next == SIZE_MAX) break;
        pos = next;
    }
    return true;
}

// Fingerprint only the sequence parameter set(s). PPS/VPS order or subset
// differences may require a parser rebuild, but they do not by themselves
// prove that the coded scan type changed. Keeping this evidence separate avoids
// turning harmless parameter-set packaging differences into a permanent MEMC
// bypass.
static uint64_t spSPSFingerprint(const std::vector<uint8_t> &parameterSets,
                                 bool hevc) {
    const uint8_t *data = parameterSets.data();
    const size_t size = parameterSets.size();
    uint64_t fp = 0;
    size_t pos = 0;
    while (data && pos < size) {
        const size_t sc = spFindStartCodePos(data, size, pos);
        if (sc == SIZE_MAX) break;
        const size_t scLen = data[sc + 2] == 1 ? 3 : 4;
        const size_t nal = sc + scLen;
        const size_t next = spFindStartCodePos(data, size, nal);
        size_t end = next == SIZE_MAX ? size : next;
        if (end > nal) {
            const int type = spNALType(data[nal], hevc);
            if (type == (hevc ? 33 : 7)) {
                while (end > nal && data[end - 1] == 0) --end;
                if (!fp) fp = 1469598103934665603ull;
                for (size_t i = nal; i < end; ++i) {
                    fp ^= data[i];
                    fp *= 1099511628211ull;
                }
            }
        }
        if (next == SIZE_MAX) break;
        pos = next;
    }
    return fp;
}

enum class SPHEVCScanConfig {
    Unknown,
    Progressive,
    Interlaced,
};

// HEVC public parser output can remain UNKNOWN when picture-timing SEI is
// absent. The profile_tier_level source flags live near the start of the SPS
// and provide a configuration-level fail-closed gate even for that case.
static SPHEVCScanConfig spHEVCScanConfigFromParameterSets(
    const std::vector<uint8_t> &parameterSets) {
    const uint8_t *data = parameterSets.data();
    size_t size = parameterSets.size();
    size_t pos = 0;
    bool sawProgressive = false;
    bool sawUnknown = false;
    while (data && pos < size) {
        size_t sc = spFindStartCodePos(data, size, pos);
        if (sc == SIZE_MAX) break;
        size_t scLen = data[sc + 2] == 1 ? 3 : 4;
        size_t nal = sc + scLen;
        size_t next = spFindStartCodePos(data, size, nal);
        size_t end = next == SIZE_MAX ? size : next;
        if (end >= nal + 3 && ((data[nal] >> 1) & 0x3f) == 33) { // SPS
            std::vector<uint8_t> rbsp;
            rbsp.reserve(end - nal - 2);
            int zeros = 0;
            for (size_t i = nal + 2; i < end; ++i) { // skip HEVC NAL header
                uint8_t byte = data[i];
                if (zeros >= 2 && byte == 0x03) {
                    zeros = 0;
                    continue;
                }
                rbsp.push_back(byte);
                zeros = byte == 0 ? zeros + 1 : 0;
            }
            // SPS header 8 bits + general profile/tier/idc 8 bits + profile
            // compatibility flags 32 bits, then four source/constraint bits.
            // A complete general_profile_tier_level is substantially longer
            // than the four source flags we consume. Requiring its fixed
            // general portion prevents a truncated SPS from manufacturing a
            // seemingly safe progressive verdict out of the first few bytes.
            if (rbsp.size() < 13) {
                sawUnknown = true;
                if (next == SIZE_MAX) break;
                pos = next;
                continue;
            }
            size_t bit = 48;
            auto readBit = [&]() -> int {
                if (bit >= rbsp.size() * 8) return -1;
                int value = (rbsp[bit >> 3] >> (7 - (bit & 7))) & 1;
                ++bit;
                return value;
            };
            int progressive = readBit();
            int interlaced = readBit();
            (void)readBit(); // general_non_packed_constraint_flag
            int frameOnly = readBit();
            if (interlaced == 1) return SPHEVCScanConfig::Interlaced;
            if (progressive == 1 && interlaced == 0 && frameOnly == 1) {
                sawProgressive = true;
            } else {
                sawUnknown = true;
            }
        }
        if (next == SIZE_MAX) break;
        pos = next;
    }
    return sawProgressive && !sawUnknown ? SPHEVCScanConfig::Progressive
                                        : SPHEVCScanConfig::Unknown;
}

#pragma mark - Callbacks

struct SPPendingVTOutput {
    CVPixelBufferRef buffer = NULL;
    SPDecodedVideoScanVerdict scanVerdict = SPDecodedVideoScanVerdictUnknown;
    BOOL scanCovered = NO;
};

class SPVTReorderBuffer {
public:

    void configure(int depth, bool needReorder, unsigned logId) {
        std::lock_guard<std::mutex> lock(mu_);
        logId_ = logId;
        depth_ = depth;
        needReorder_ = needReorder;
        resetLocked();
    }

    void reset() {
        std::lock_guard<std::mutex> lock(mu_);
        resetLocked();
    }

    void noteReorderRequired() {
        std::lock_guard<std::mutex> lock(mu_);
        needReorder_ = true;
    }

    void noteCatchUpSubmitted() {
        std::lock_guard<std::mutex> lock(mu_);
        firstAfterFlush_ = false;
    }

    void invalidateScanSidecars() {
        std::lock_guard<std::mutex> lock(mu_);
        for (auto &entry : buf_) {
            entry.second.scanVerdict = SPDecodedVideoScanVerdictUnknown;
            entry.second.scanCovered = NO;
        }
        lastOutputScanCovered_ = false;
    }

    bool lastOutputScanCovered() {
        std::lock_guard<std::mutex> lock(mu_);
        return lastOutputScanCovered_;
    }

    SPDecodedVideoOutput accept(CVPixelBufferRef buf, int64_t ptsUs,
                                SPDecodedVideoScanVerdict scanVerdict,
                                BOOL scanCovered, bool stickyInterlaced) {
        std::lock_guard<std::mutex> lock(mu_);

        if (firstAfterFlush_) {
            firstAfterFlush_ = false;
            lastOutPts_ = ptsUs;
            lastOutputScanCovered_ = scanCovered;
            return SPDecodedVideoOutputMake(buf, ptsUs, scanVerdict, scanCovered);
        }
        if (!needReorder_) {

            if (lastOutPts_ >= 0 && ptsUs < lastOutPts_) needReorder_ = true;
        }
        if (!needReorder_) {
            lastOutPts_ = ptsUs;
            lastOutputScanCovered_ = scanCovered;
            return SPDecodedVideoOutputMake(buf, ptsUs, scanVerdict, scanCovered);
        }

        if (lastOutPts_ >= 0 && ptsUs < lastOutPts_ && depth_ < 16 &&
            lastOutPts_ != lastGrowOutPts_) {
            lastGrowOutPts_ = lastOutPts_;
            depth_++;
            if (spDebug()) NSLog(@"[c%u][VT] PTS 倒挂 %.3f < %.3f → 重排窗口扩至 %d",
                                  logId_, ptsUs / 1e6, lastOutPts_ / 1e6, depth_);
        }

        while (buf_.find(ptsUs) != buf_.end()) ++ptsUs;
        buf_[ptsUs] = {buf, scanVerdict, scanCovered};
        if ((int)buf_.size() > depth_) return emitFrontLocked(stickyInterlaced);
        return SPDecodedVideoOutputMake(NULL, ptsUs,
                                        SPDecodedVideoScanVerdictUnknown, NO);
    }

    SPDecodedVideoOutput popConfirmed(bool stickyInterlaced) {
        std::lock_guard<std::mutex> lock(mu_);
        if (!needReorder_ || (int)buf_.size() <= depth_) {
            return SPDecodedVideoOutputEmpty();
        }
        return emitFrontLocked(stickyInterlaced);
    }

    SPDecodedVideoOutput drainNext(bool stickyInterlaced) {
        std::lock_guard<std::mutex> lock(mu_);
        if (buf_.empty()) return SPDecodedVideoOutputEmpty();
        return emitFrontLocked(stickyInterlaced, /*advanceLastOut=*/false);
    }

private:

    SPDecodedVideoOutput emitFrontLocked(bool stickyInterlaced,
                                         bool advanceLastOut = true) {
        auto it = buf_.begin();
        SPPendingVTOutput pending = it->second;
        int64_t outPts = it->first;
        buf_.erase(it);
        if (stickyInterlaced) {
            // A negative coded-stream verdict is session-sticky. Surface it on
            // the next concrete output even when that output was already in
            // the reorder window; scanCovered remains exact-frame progressive
            // proof and therefore becomes false.
            pending.scanVerdict = SPDecodedVideoScanVerdictInterlaced;
            pending.scanCovered = NO;
        }
        lastOutputScanCovered_ = pending.scanCovered;
        if (advanceLastOut) lastOutPts_ = outPts;
        return SPDecodedVideoOutputMake(pending.buffer, outPts,
                                        pending.scanVerdict,
                                        pending.scanCovered);
    }

    void resetLocked() {
        for (auto &kv : buf_) CVPixelBufferRelease(kv.second.buffer);
        buf_.clear();
        lastOutputScanCovered_ = false;
        lastOutPts_ = -1;
        lastGrowOutPts_ = INT64_MIN;
        firstAfterFlush_ = true;
    }

    std::mutex mu_;
    // The buffer and its scan sidecar share one map value. This prevents PTS
    // reorder, EOF drain, or seek cleanup from separating metadata from the
    // concrete +1 surface it describes.
    std::map<int64_t, SPPendingVTOutput> buf_;
    bool needReorder_ = false;
    int64_t lastOutPts_ = -1;

    int depth_ = 4;
    unsigned logId_ = 0;
    int64_t lastGrowOutPts_ = INT64_MIN;
    bool firstAfterFlush_ = true;
    bool lastOutputScanCovered_ = false;
};

@interface SPVideoDecoder () {
    VTDecompressionSessionRef session_;
    CMVideoFormatDescriptionRef formatDesc_;
    int width_;
    int height_;
    int64_t tbNum_, tbDen_;
    bool annexBBitstream_;
    uint64_t paramSetFp_;

    SPVTReorderBuffer reorder_;
    int64_t synthNextPtsTicks_;

    std::mutex cbMu_;
    std::condition_variable cbCond_;

    int dbgCbLogs_;
    int dbgAttLogs_;
    int dbgDecodeErrLogs_;
    int dbgCbErrLogs_;
    OSStatus cbStatus_;
    std::atomic<int> lastError_;
    CVPixelBufferRef cbBuffer_;
    bool cbDone_;
    int64_t cbPtsUs_;

    std::atomic<int64_t> catchUpTargetUs_;
    bool asyncInFlight_;
    std::vector<uint8_t> annexBBuf_;
    std::vector<uint8_t> codedParameterSetsScratch_;
    uint64_t codedSPSFingerprint_;
    SPHEVCScanConfig codedHEVCConfig_;
    bool codedConfigTainted_;

    SPHEVCScanConfig codedBaselineHEVCConfig_;
    bool codedBaselineHadSets_;
    bool codedInterlacedSeen_;
    bool codedConfigCanChangeInBand_;
    int bitstreamNALLengthSize_;

    CMVideoCodecType codecType_;
    // VideoToolbox only applies temporal deinterlacing when decode submissions
    // opt into a delayed temporal pipeline. This decoder intentionally waits
    // synchronously for one output per packet, so use the frame-local vertical
    // filter and remember the best-effort property attempt per VT session.
    bool deinterlacePropertiesAttempted_;
    int hevcMaxTid_;
    int hevcTidPackets_;
    int64_t nrDropped_;

    AVCodecParserContext *interpolationScanParser_;
    AVCodecContext *interpolationScanContext_;
    AVCodecParameters *interpolationScanParameters_;
    uint64_t interpolationScanParameterSetFp_;
    uint64_t interpolationScanExtradataFp_;
    // Last AU parameter sets proven a byte-identical repeat (P7 MEL repeats
    // its PPS in every AU), keyed by both fingerprints: skips the re-proof.
    uint64_t scanRepeatPacketFp_, scanRepeatRetainedFp_;
    int interpolationScanNALLengthSize_;
    bool interpolationScanKnown_;
    bool interpolationScanInterlaced_;
    bool interpolationScanEnabled_;
    // Verdict for the compressed access unit submitted by the current
    // decodePacket call.  A previous progressive AU must never authorize a
    // later packet that the parser could not classify.
    bool interpolationCurrentPacketScanCovered_;
    bool interpolationScanAwaitingRandomAccess_;
    SPHEVCScanConfig interpolationScanHEVCConfig_;
    int64_t interpolationScanSafeFromPTSUs_;
}
@end

static constexpr int kTidLearnMin = 30;

static bool spReadNALLength(const uint8_t *data, size_t size, size_t offset,
                            int lengthSize, size_t *lengthOut) {
    if (!data || !lengthOut || lengthSize < 1 || lengthSize > 4 ||
        offset + (size_t)lengthSize > size) {
        return false;
    }
    size_t length = 0;
    for (int i = 0; i < lengthSize; ++i) {
        length = (length << 8) | data[offset + (size_t)i];
    }
    *lengthOut = length;
    return length > 0 && offset + (size_t)lengthSize + length <= size;
}

static bool spH264IsNonRef(const uint8_t *d, size_t n, int lengthSize) {
    size_t i = 0;
    bool sawVcl = false;
    while (i + (size_t)lengthSize <= n) {
        size_t len = 0;
        if (!spReadNALLength(d, n, i, lengthSize, &len)) break;
        i += (size_t)lengthSize;
        int type = d[i] & 0x1F;
        if (type >= 1 && type <= 5) { // VCL
            sawVcl = true;
            if (((d[i] >> 5) & 0x3) != 0) return false;
        }
        i += len;
    }
    return sawVcl;
}

static int spHevcNonRefTid(const uint8_t *d, size_t n, int lengthSize) {
    size_t i = 0;
    bool sawVcl = false;
    int tid = -1;
    while (i + (size_t)lengthSize <= n) {
        size_t len = 0;
        if (!spReadNALLength(d, n, i, lengthSize, &len) || len < 2) break;
        i += (size_t)lengthSize;
        int type = (d[i] >> 1) & 0x3F;
        if (type <= 31) { // VCL
            sawVcl = true;
            // TRAIL_N/TSA_N/STSA_N/RADL_N/RASL_N
            if (!(type == 0 || type == 2 || type == 4 || type == 6 || type == 8)) return -1;
            int t = (d[i + 1] & 0x7) - 1;
            if (t > tid) tid = t;
        }
        i += len;
    }
    return sawVcl ? tid : -1;
}

// Inspect the length-prefixed representation already consumed by VT. For HEVC
// this replaces the pre-existing temporal-id walk; when a format may update
// parameter sets in-band, the same walk also records the small pre-VCL config
// prefix. No second packet pass or parser is added to the Off path.
static void spInspectLengthPrefixedPacket(const uint8_t *d, size_t n,
                                          int lengthSize, bool hevc,
                                          std::vector<uint8_t> *parameterSets,
                                          int *maxTid, int *packets) {
    size_t i = 0;
    while (i + (size_t)lengthSize <= n) {
        size_t len = 0;
        if (!spReadNALLength(d, n, i, lengthSize, &len)) break;
        i += (size_t)lengthSize;
        if (len < (hevc ? 2u : 1u)) break;
        int type = spNALType(d[i], hevc);
        const bool vcl = spNALIsVCL(type, hevc);
        if (vcl) {
            if (hevc && maxTid && packets) {
                const int t = (d[i + 1] & 0x7) - 1;
                if (t > *maxTid) *maxTid = t;
                (*packets)++;
            }
            break;
        }
        if (parameterSets && spIsScanParameterSet(type, hevc)) {
            spAppendScanParameterSet(*parameterSets, d + i, len);
        }
        i += len;
    }
}

@implementation SPVideoDecoder

@synthesize spLogId = _spLogId;

- (instancetype)init {
    self = [super init];
    if (self) {
        session_ = NULL;
        formatDesc_ = NULL;
        width_ = height_ = 0;
        tbNum_ = 1; tbDen_ = 1;
        annexBBitstream_ = false;
        lastError_.store(0);

        synthNextPtsTicks_ = 0;
        catchUpTargetUs_.store(-1);
        asyncInFlight_ = false;
        codecType_ = 0;
        deinterlacePropertiesAttempted_ = false;
        hevcMaxTid_ = 0;
        hevcTidPackets_ = 0;
        nrDropped_ = 0;
        codedSPSFingerprint_ = 0;
        codedHEVCConfig_ = SPHEVCScanConfig::Unknown;
        codedConfigTainted_ = false;
        codedBaselineHEVCConfig_ = SPHEVCScanConfig::Unknown;
        codedBaselineHadSets_ = false;
        codedInterlacedSeen_ = false;
        codedConfigCanChangeInBand_ = false;
        bitstreamNALLengthSize_ = 4;
        interpolationScanParser_ = nullptr;
        interpolationScanContext_ = nullptr;
        interpolationScanParameters_ = nullptr;
        interpolationScanParameterSetFp_ = 0;
        interpolationScanExtradataFp_ = 0;
        interpolationScanNALLengthSize_ = 4;
        interpolationScanKnown_ = false;
        interpolationScanInterlaced_ = false;
        interpolationScanEnabled_ = false;
        interpolationCurrentPacketScanCovered_ = false;
        interpolationScanAwaitingRandomAccess_ = false;
        interpolationScanHEVCConfig_ = SPHEVCScanConfig::Unknown;
        interpolationScanSafeFromPTSUs_ = INT64_MAX;
    }
    return self;
}

- (void)requestFrameLocalDeinterlacingIfNeeded:(NSString *)reason {
    if (!session_ || deinterlacePropertiesAttempted_) return;
    deinterlacePropertiesAttempted_ = true;
    OSStatus fieldStatus = VTSessionSetProperty(
        session_, kVTDecompressionPropertyKey_FieldMode,
        kVTDecompressionProperty_FieldMode_DeinterlaceFields);
    OSStatus modeStatus = VTSessionSetProperty(
        session_, kVTDecompressionPropertyKey_DeinterlaceMode,
        kVTDecompressionProperty_DeinterlaceMode_VerticalFilter);
    if (spDebug()) {
        SPLOG(@"[VT] 动态隔行证据 %@ → 请求逐帧去隔行 field=%d mode=%d",
              reason ?: @"未知", (int)fieldStatus, (int)modeStatus);
    }
}

- (void)requestFrameLocalDeinterlacingForKnownCodedContent {
    codedInterlacedSeen_ = true;
    [self requestFrameLocalDeinterlacingIfNeeded:@"decoder replacement"];
}

- (void)observeCodedParameterSets:(const std::vector<uint8_t> &)parameterSets
                         baseline:(BOOL)baseline {
    const bool hevc = codecType_ == kCMVideoCodecType_HEVC;
    if (!hevc && codecType_ != kCMVideoCodecType_H264) return;
    const uint64_t spsFp = spSPSFingerprint(parameterSets, hevc);
    if (!spsFp) return;

    const SPHEVCScanConfig config = hevc
        ? spHEVCScanConfigFromParameterSets(parameterSets)
        : SPHEVCScanConfig::Unknown;
    if (hevc && config == SPHEVCScanConfig::Interlaced) {
        // Positive unsafe evidence is permanent for this decoder/media session.
        // It is safe to be conservative after a seek; it is never safe to let a
        // later dormant progressive SPS erase this fact.
        codedInterlacedSeen_ = true;
        [self requestFrameLocalDeinterlacingIfNeeded:@"HEVC SPS"];
    }

    if (baseline || codedSPSFingerprint_ == 0) {
        codedSPSFingerprint_ = spsFp;
        codedHEVCConfig_ = config;
        if (baseline) { codedBaselineHEVCConfig_ = config; codedBaselineHadSets_ = true; }
        if (hevc && config == SPHEVCScanConfig::Unknown) {
            codedConfigTainted_ = true;
        }
        return;
    }

    if (codedSPSFingerprint_ != spsFp) {
        // A config that changed while MEMC was Off cannot be reconstructed from
        // the prepare-era codecpar. Keep only negative evidence; On will remain
        // fail-closed until a current access unit proves its own scan type.
        codedConfigTainted_ = true;
        codedSPSFingerprint_ = spsFp;
        codedHEVCConfig_ = config;
    } else if (hevc && config == SPHEVCScanConfig::Interlaced) {
        codedHEVCConfig_ = config;
    }
}

static bool spCodecIsProgressiveOnlyForMEMC(AVCodecID codec) {
    // These codecs do not define interlaced pictures. Do not allocate a parser
    // merely to prove a property guaranteed by the bitstream specification.
    return codec == AV_CODEC_ID_AV1 || codec == AV_CODEC_ID_VP8 ||
           codec == AV_CODEC_ID_VP9;
}

- (BOOL)rebuildInterpolationScanParser {
    if (interpolationScanParser_) {
        av_parser_close(interpolationScanParser_);
        interpolationScanParser_ = nullptr;
    }
    if (interpolationScanContext_) {
        avcodec_free_context(&interpolationScanContext_);
    }
    if (!interpolationScanParameters_) return NO;
    interpolationScanParser_ = av_parser_init(interpolationScanParameters_->codec_id);
    interpolationScanContext_ = avcodec_alloc_context3(nullptr);
    if (!interpolationScanParser_ || !interpolationScanContext_ ||
        avcodec_parameters_to_context(interpolationScanContext_,
                                      interpolationScanParameters_) < 0) {
        if (interpolationScanParser_) {
            av_parser_close(interpolationScanParser_);
            interpolationScanParser_ = nullptr;
        }
        if (interpolationScanContext_) {
            avcodec_free_context(&interpolationScanContext_);
        }
        return NO;
    }
    interpolationScanParser_->flags |= PARSER_FLAG_COMPLETE_FRAMES;
    return YES;
}

- (void)setInterpolationScanEnabled:(BOOL)enabled
                    codecParameters:(const AVCodecParameters *)par {
    if (!enabled) {
        if (interpolationScanParser_) {
            av_parser_close(interpolationScanParser_);
            interpolationScanParser_ = nullptr;
        }
        if (interpolationScanContext_) {
            avcodec_free_context(&interpolationScanContext_);
        }
        if (interpolationScanParameters_) {
            avcodec_parameters_free(&interpolationScanParameters_);
        }
        interpolationScanParameterSetFp_ = 0;
        interpolationScanExtradataFp_ = 0;
        interpolationScanNALLengthSize_ = 4;
        interpolationScanEnabled_ = false;
        interpolationScanKnown_ = false;
        interpolationScanInterlaced_ = false;
        interpolationCurrentPacketScanCovered_ = false;
        interpolationScanAwaitingRandomAccess_ = false;
        interpolationScanHEVCConfig_ = SPHEVCScanConfig::Unknown;
        interpolationScanSafeFromPTSUs_ = INT64_MAX;
        reorder_.invalidateScanSidecars();
        return;
    }
    if (interpolationScanEnabled_) return;
    interpolationScanEnabled_ = true;
    interpolationScanKnown_ = false;
    interpolationScanInterlaced_ = false;
    interpolationCurrentPacketScanCovered_ = false;
    interpolationScanAwaitingRandomAccess_ = true;
    interpolationScanHEVCConfig_ = SPHEVCScanConfig::Unknown;
    interpolationScanSafeFromPTSUs_ = INT64_MAX;
    reorder_.invalidateScanSidecars();
    if (!par) return; // fail closed: Core treats unknown as unsafe

    AVCodecID codec = (AVCodecID)par->codec_id;
    if (par->extradata && par->extradata_size > 0) {
        interpolationScanExtradataFp_ = spBytesFp(
            par->extradata, (size_t)par->extradata_size);
        if (codec == AV_CODEC_ID_H264 && par->extradata_size >= 5 &&
            par->extradata[0] == 1) {
            interpolationScanNALLengthSize_ = (par->extradata[4] & 3) + 1;
        } else if (codec == AV_CODEC_ID_HEVC && par->extradata_size >= 22 &&
                   par->extradata[0] == 1) {
            interpolationScanNALLengthSize_ = (par->extradata[21] & 3) + 1;
        }
    }
    if (spCodecIsProgressiveOnlyForMEMC(codec)) {
        interpolationScanKnown_ = true;
        interpolationScanAwaitingRandomAccess_ = false;
        interpolationScanSafeFromPTSUs_ = INT64_MIN;
        return;
    }
    if (codedInterlacedSeen_ ||
        (par->field_order != AV_FIELD_UNKNOWN &&
         par->field_order != AV_FIELD_PROGRESSIVE)) {
        interpolationScanKnown_ = true;
        interpolationScanInterlaced_ = true;
        interpolationScanAwaitingRandomAccess_ = false;
        interpolationScanSafeFromPTSUs_ = INT64_MAX;
        return;
    }

    interpolationScanParameters_ = avcodec_parameters_alloc();
    if (interpolationScanParameters_ &&
        avcodec_parameters_copy(interpolationScanParameters_, par) >= 0) {
        [self reseedInterpolationScanConfigFingerprint];
        if (interpolationScanHEVCConfig_ == SPHEVCScanConfig::Interlaced) {
            interpolationScanKnown_ = true;
            interpolationScanInterlaced_ = true;
            interpolationScanAwaitingRandomAccess_ = false;
            interpolationScanSafeFromPTSUs_ = INT64_MAX;
        }
        (void)[self rebuildInterpolationScanParser];
    } else if (interpolationScanParameters_) {
        avcodec_parameters_free(&interpolationScanParameters_);
    }

}

- (void)reseedInterpolationScanConfigFingerprint {
    interpolationScanParameterSetFp_ = 0;
    if (!interpolationScanParameters_) return;
    AVCodecID codec = interpolationScanParameters_->codec_id;
    if (codec != AV_CODEC_ID_H264 && codec != AV_CODEC_ID_HEVC) return;
    SPNormalizedScanParameterSets normalized = spNormalizedScanParameterSets(
        interpolationScanParameters_->extradata,
        (size_t)MAX(interpolationScanParameters_->extradata_size, 0),
        codec == AV_CODEC_ID_HEVC, SPScanDataKind::Extradata,
        interpolationScanNALLengthSize_);
    const bool hevc = codec == AV_CODEC_ID_HEVC;
    const uint64_t spsFp = normalized.valid
        ? spSPSFingerprint(normalized.bytes, hevc) : 0;
    const bool trusted = normalized.valid && !codedConfigTainted_ &&
        (codedSPSFingerprint_ == 0 || codedSPSFingerprint_ == spsFp);
    interpolationScanParameterSetFp_ = trusted
        ? spBytesFp(normalized.bytes.data(), normalized.bytes.size()) : 0;
    if (hevc) {
        interpolationScanHEVCConfig_ = trusted ? codedHEVCConfig_
                                               : SPHEVCScanConfig::Unknown;
    }
}

- (void)inspectPacketForInterpolation:(const AVPacket *)pkt {
    // Per-AU, not sticky: an incomplete/unknown parser result must fail closed
    // even after earlier packets established a progressive stream-level state.
    interpolationCurrentPacketScanCovered_ = false;
    if (!interpolationScanEnabled_ || interpolationScanInterlaced_ ||
        !interpolationScanParser_ || !interpolationScanContext_ || !pkt ||
        !pkt->data || pkt->size <= 0) {
        return;
    }
    AVCodecID codec = interpolationScanParameters_
        ? interpolationScanParameters_->codec_id : AV_CODEC_ID_NONE;
    size_t sideDataSize = 0;
    uint8_t *sideData = av_packet_get_side_data(
        pkt, AV_PKT_DATA_NEW_EXTRADATA, &sideDataSize);
    bool configurationEvidenceValidForCurrentAU = true;
    uint64_t parameterSetFpToCommitAfterParse = 0;
    if (codec == AV_CODEC_ID_H264 || codec == AV_CODEC_ID_HEVC) {
        const bool hevc = codec == AV_CODEC_ID_HEVC;
        int candidateNALLengthSize = interpolationScanNALLengthSize_;
        if (sideData && sideDataSize > 0) {
            if (!hevc && sideDataSize >= 5 && sideData[0] == 1) {
                candidateNALLengthSize = (sideData[4] & 3) + 1;
            } else if (hevc && sideDataSize >= 22 && sideData[0] == 1) {
                candidateNALLengthSize = (sideData[21] & 3) + 1;
            }
        }

        // NEW_EXTRADATA and in-band parameter sets are independent evidence.
        // Never let a progressive container side record hide an interlaced SPS
        // carried by the very access unit being decoded.
        SPNormalizedScanParameterSets sideSets;
        if (sideData && sideDataSize > 0) {
            sideSets = spNormalizedScanParameterSets(
                sideData, sideDataSize, hevc, SPScanDataKind::Extradata,
                candidateNALLengthSize);
        }
        SPNormalizedScanParameterSets packetSets =
            spNormalizedScanParameterSets(
                pkt->data, (size_t)pkt->size, hevc,
                annexBBitstream_ ? SPScanDataKind::AnnexB
                                 : SPScanDataKind::LengthPrefixed,
                candidateNALLengthSize);
        uint64_t sideFp = sideSets.valid
            ? spBytesFp(sideSets.bytes.data(), sideSets.bytes.size()) : 0;
        uint64_t packetFp = packetSets.valid
            ? spBytesFp(packetSets.bytes.data(), packetSets.bytes.size()) : 0;
        uint64_t sideSPSFp = sideSets.valid
            ? spSPSFingerprint(sideSets.bytes, hevc) : 0;
        uint64_t packetSPSFp = packetSets.valid
            ? spSPSFingerprint(packetSets.bytes, hevc) : 0;
        SPHEVCScanConfig sideConfig = hevc && sideSets.valid
            ? spHEVCScanConfigFromParameterSets(sideSets.bytes)
            : SPHEVCScanConfig::Unknown;
        SPHEVCScanConfig packetConfig = hevc && packetSets.valid
            ? spHEVCScanConfigFromParameterSets(packetSets.bytes)
            : SPHEVCScanConfig::Unknown;
        if (hevc && (sideConfig == SPHEVCScanConfig::Interlaced ||
                     packetConfig == SPHEVCScanConfig::Interlaced)) {
            interpolationScanKnown_ = true;
            interpolationScanInterlaced_ = true;
            interpolationScanAwaitingRandomAccess_ = false;
            interpolationScanHEVCConfig_ = SPHEVCScanConfig::Interlaced;
            interpolationScanSafeFromPTSUs_ = INT64_MAX;
            [self requestFrameLocalDeinterlacingIfNeeded:@"HEVC access unit"];
            if (spDebug()) {
                SPLOG(@"[VT] MEMC coded-scan detected interlaced HEVC SPS");
            }
            return;
        }

        const bool malformedEvidence = !packetSets.valid ||
            ((sideData && sideDataSize > 0) && !sideSets.valid);
        // PPS/VPS order and subset differences are parser-packaging details.
        // Only conflicting SPS bytes imply contradictory scan configuration.
        const bool conflictingEvidence = sideSPSFp != 0 && packetSPSFp != 0 &&
                                         sideSPSFp != packetSPSFp;
        configurationEvidenceValidForCurrentAU =
            !malformedEvidence && !conflictingEvidence;
        if (!configurationEvidenceValidForCurrentAU) {
            interpolationScanKnown_ = false;
            interpolationScanAwaitingRandomAccess_ = true;
            interpolationScanSafeFromPTSUs_ = INT64_MAX;
            interpolationScanParameterSetFp_ = 0;
            if (hevc) interpolationScanHEVCConfig_ = SPHEVCScanConfig::Unknown;
            if (spDebug()) {
                SPLOG(@"[VT] MEMC coded-scan parameter evidence %@; fail closed",
                      malformedEvidence ? @"malformed" : @"conflicted");
            }
        }

        // In-band sets describe the compressed AU more directly. They may
        // always reject an interlaced stream, but a newly advertised HEVC SPS
        // alone is not enough to *authorize* progressive output: selecting the
        // active SPS requires following PPS/slice ids. Only a complete,
        // consistent sample-description update (or the already trusted setup
        // configuration) can promote HEVC back to Progressive.
        const std::vector<uint8_t> &parameterSets = packetFp != 0
            ? packetSets.bytes : sideSets.bytes;
        uint64_t fp = packetFp != 0 ? packetFp : sideFp;
        const uint64_t previousParameterSetFp = interpolationScanParameterSetFp_;
        uint64_t rawExtraFp = sideData && sideDataSize > 0
            ? spBytesFp(sideData, sideDataSize) : 0;
        bool parameterSetsChanged =
            fp != 0 && fp != previousParameterSetFp;
        bool rawExtradataChanged =
            rawExtraFp != 0 && rawExtraFp != interpolationScanExtradataFp_;
        if (hevc && parameterSetsChanged && !rawExtradataChanged &&
            configurationEvidenceValidForCurrentAU && !codedConfigTainted_ &&
            packetFp != 0 && packetSPSFp == 0) {
            const uint8_t *retainedData = interpolationScanParameters_->extradata;
            const size_t retainedSize = (size_t)MAX(interpolationScanParameters_->extradata_size, 0);
            const uint64_t retainedFp = spBytesFp(retainedData, retainedSize);
            if (packetFp == scanRepeatPacketFp_ && retainedFp == scanRepeatRetainedFp_) {
                parameterSetsChanged = false;
            } else {
                const auto retained = spNormalizedScanParameterSets(retainedData, retainedSize,
                    true, SPScanDataKind::Extradata, interpolationScanNALLengthSize_);
                if (retained.valid &&
                    spScanParameterSetsRepeatSubset(packetSets.bytes, retained.bytes)) {
                    parameterSetsChanged = false;
                    scanRepeatPacketFp_ = packetFp;
                    scanRepeatRetainedFp_ = retainedFp;
                }
            }
        }
        if (configurationEvidenceValidForCurrentAU &&
            (parameterSetsChanged || rawExtradataChanged)) {
            interpolationScanKnown_ = false;
            interpolationScanSafeFromPTSUs_ = INT64_MAX;
            interpolationScanAwaitingRandomAccess_ = true;
            if (hevc) {
                // A newly advertised SPS may be dormant: without following the
                // current slice PPS id back to its active SPS, seeing a
                // progressive PTL is not sufficient authorization. Preserve a
                // verdict only when both sources repeat the already trusted
                // setup parameter sets. A decoder rebuild will seed a genuinely
                // new sample description through setInterpolationScanEnabled.
                const uint64_t currentSPSFp = packetSPSFp != 0
                    ? packetSPSFp : sideSPSFp;
                const bool repeatsTrustedConfiguration =
                    !codedConfigTainted_ && codedSPSFingerprint_ != 0 &&
                    currentSPSFp == codedSPSFingerprint_ &&
                    (!sideSPSFp || !packetSPSFp ||
                     sideSPSFp == packetSPSFp);

                const bool inBandProgressiveAuthoritative =
                    codedConfigCanChangeInBand_ && packetSPSFp != 0 &&
                    packetConfig == SPHEVCScanConfig::Progressive &&
                    (!sideSPSFp || sideConfig == SPHEVCScanConfig::Progressive) &&
                    (!codedBaselineHadSets_ ||
                     codedBaselineHEVCConfig_ == SPHEVCScanConfig::Progressive);
                if (repeatsTrustedConfiguration) {
                    interpolationScanHEVCConfig_ = codedHEVCConfig_;
                } else if (inBandProgressiveAuthoritative) {
                    interpolationScanHEVCConfig_ = SPHEVCScanConfig::Progressive;
                    if (spDebug() && !codedConfigTainted_) {
                        SPLOG(@"[VT] MEMC coded-scan: in-band progressive SPS overrides sample description");
                    }
                } else {
                    interpolationScanHEVCConfig_ = SPHEVCScanConfig::Unknown;
                }
            }

            // Preserve the parser's framing contract. NEW_EXTRADATA is copied
            // verbatim (avcC/hvcC remains length-prefixed); Annex-B in-band
            // parameter sets use their normalized Annex-B representation.
            // A length-prefixed AU without NEW_EXTRADATA cannot be losslessly
            // rebuilt into avcC/hvcC here, so it stays fail-closed unless that
            // AU itself yields positive parser evidence.
            const uint8_t *replacement = nullptr;
            size_t replacementSize = 0;
            if (sideData && sideDataSize > 0) {
                replacement = sideData;
                replacementSize = sideDataSize;
            } else if (annexBBitstream_) {
                replacement = parameterSets.data();
                replacementSize = parameterSets.size();
            }
            if (replacement && replacementSize > 0) {
                uint8_t *newExtradata = (uint8_t *)av_mallocz(
                    replacementSize + AV_INPUT_BUFFER_PADDING_SIZE);
                if (!newExtradata) {
                    interpolationScanParameterSetFp_ = 0;
                    if (hevc) {
                        interpolationScanHEVCConfig_ = SPHEVCScanConfig::Unknown;
                    }
                    interpolationScanKnown_ = false;
                    interpolationScanAwaitingRandomAccess_ = true;
                    interpolationScanSafeFromPTSUs_ = INT64_MAX;
                    return;
                }
                memcpy(newExtradata, replacement, replacementSize);
                uint8_t *oldExtradata = interpolationScanParameters_->extradata;
                int oldExtradataSize = interpolationScanParameters_->extradata_size;
                interpolationScanParameters_->extradata = newExtradata;
                interpolationScanParameters_->extradata_size = (int)replacementSize;
                if (![self rebuildInterpolationScanParser]) {
                    interpolationScanParameters_->extradata = oldExtradata;
                    interpolationScanParameters_->extradata_size = oldExtradataSize;
                    av_free(newExtradata);
                    (void)[self rebuildInterpolationScanParser];
                    interpolationScanParameterSetFp_ = 0;
                    if (hevc) {
                        interpolationScanHEVCConfig_ = SPHEVCScanConfig::Unknown;
                    }
                    interpolationScanKnown_ = false;
                    interpolationScanAwaitingRandomAccess_ = true;
                    interpolationScanSafeFromPTSUs_ = INT64_MAX;
                    return;
                }
                av_free(oldExtradata);
                interpolationScanExtradataFp_ = rawExtraFp;
                interpolationScanNALLengthSize_ = candidateNALLengthSize;
                if (parameterSetsChanged) {
                    interpolationScanParameterSetFp_ = fp;
                }
            } else if (parameterSetsChanged) {
                // The current packet itself is the only parser update source.
                // Commit its authorization fingerprint only if this exact AU is
                // parsed successfully below; an old parser must never be paired
                // with a new non-zero proof after a failed update.
                parameterSetFpToCommitAfterParse = fp;
            }
        }
    }
    // Parser public outputs may retain the previous access unit when parsing
    // fails. Reset them so stale evidence never authorizes or rejects a frame.
    interpolationScanParser_->field_order = AV_FIELD_UNKNOWN;
    interpolationScanParser_->picture_structure = AV_PICTURE_STRUCTURE_UNKNOWN;
    uint8_t *parsed = nullptr;
    int parsedSize = 0;
    int consumed = av_parser_parse2(interpolationScanParser_, interpolationScanContext_,
                                    &parsed, &parsedSize, pkt->data, pkt->size,
                                    pkt->pts, pkt->dts, pkt->pos);
    const bool completeAccessUnit = consumed == pkt->size && parsedSize > 0;
    if (parameterSetFpToCommitAfterParse != 0) {
        if (completeAccessUnit) {
            interpolationScanParameterSetFp_ =
                parameterSetFpToCommitAfterParse;
        } else {
            interpolationScanParameterSetFp_ = 0;
            interpolationScanHEVCConfig_ = SPHEVCScanConfig::Unknown;
        }
    }
    AVFieldOrder field = interpolationScanParser_->field_order;
    AVPictureStructure picture = interpolationScanParser_->picture_structure;
    const bool fieldPicture = picture == AV_PICTURE_STRUCTURE_TOP_FIELD ||
                              picture == AV_PICTURE_STRUCTURE_BOTTOM_FIELD;
    // HEVC parser currently writes picture_struct values into field_order,
    // making TOP(1) indistinguishable from AV_FIELD_PROGRESSIVE. Its explicit
    // picture_structure is authoritative. H.264/MPEG parsers publish real
    // AVFieldOrder values (including MBAFF frame pictures).
    const bool fieldOrderInterlaced = codec != AV_CODEC_ID_HEVC &&
        field != AV_FIELD_UNKNOWN && field != AV_FIELD_PROGRESSIVE;
    if (fieldPicture || fieldOrderInterlaced) {
        interpolationScanKnown_ = true;
        interpolationScanInterlaced_ = true; // sticky for this decoder/session
        interpolationScanAwaitingRandomAccess_ = false;
        interpolationScanSafeFromPTSUs_ = INT64_MAX;
        [self requestFrameLocalDeinterlacingIfNeeded:@"coded picture"];
        if (spDebug()) {
            SPLOG(@"[VT] MEMC coded-scan detected interlaced field_order=%d picture=%d",
                  (int)field, (int)picture);
        }
    } else {
        const bool randomAccess = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
        if (configurationEvidenceValidForCurrentAU &&
            (!interpolationScanAwaitingRandomAccess_ || randomAccess) &&
            completeAccessUnit) {
            // FFmpeg's HEVC parser reports progressive pictures as UNKNOWN.
            // At a RAP, only a current SPS whose PTL explicitly promises
            // progressive+frame-only is accepted; unspecified configurations
            // remain fail-closed.
            bool progressiveEvidence =
                (codec != AV_CODEC_ID_HEVC &&
                 (codec != AV_CODEC_ID_H264 ||
                  interpolationScanParameterSetFp_ != 0) &&
                 field == AV_FIELD_PROGRESSIVE) ||
                (codec == AV_CODEC_ID_HEVC &&
                 interpolationScanHEVCConfig_ == SPHEVCScanConfig::Progressive);
            if (progressiveEvidence && pkt->pts != AV_NOPTS_VALUE) {
                interpolationScanKnown_ = true;
                interpolationScanAwaitingRandomAccess_ = false;
                interpolationCurrentPacketScanCovered_ = true;
                if (interpolationScanSafeFromPTSUs_ == INT64_MAX) {
                    interpolationScanSafeFromPTSUs_ = av_rescale_q(
                        pkt->pts, (AVRational){(int)tbNum_, (int)tbDen_},
                        AV_TIME_BASE_Q);
                }
            }
        }
    }
    if (spDebug() && (pkt->flags & AV_PKT_FLAG_KEY)) {
        SPLOG(@"[MEMCScan] RAP codec=%d complete=%d field=%d picture=%d "
               "config=%d codedConfig=%d tainted=%d fp=%llu codedFp=%llu "
               "known=%d covered=%d",
              (int)codec, completeAccessUnit, (int)field, (int)picture,
              (int)interpolationScanHEVCConfig_, (int)codedHEVCConfig_,
              codedConfigTainted_,
              (unsigned long long)interpolationScanParameterSetFp_,
              (unsigned long long)codedSPSFingerprint_,
              interpolationScanKnown_, interpolationCurrentPacketScanCovered_);
    }
}

- (void)setCatchUpTargetUs:(int64_t)targetUs {
    catchUpTargetUs_.store(targetUs);
}

- (void)waitAsyncIfNeeded {
    if (asyncInFlight_ && session_) {
        VTDecompressionSessionWaitForAsynchronousFrames(session_);
        asyncInFlight_ = false;
    }
}

- (void)dealloc {
    [self shutdown];
}

#pragma mark - Decoder callbacks

- (void)handleDecodedFrame:(CVImageBufferRef)imageBuffer
                    status:(OSStatus)status
                       pts:(int64_t)ptsUs {
    std::lock_guard<std::mutex> lock(cbMu_);
    if (spDebug()) {
        if (++dbgCbLogs_ <= 5) SPLOG(@"[VT] 回调 status=%d img=%p", (int)status, imageBuffer);
    }
    cbStatus_ = status;
    cbPtsUs_ = ptsUs;
    if (cbBuffer_) { CVPixelBufferRelease(cbBuffer_); cbBuffer_ = NULL; }
    if (imageBuffer) {
        cbBuffer_ = (CVPixelBufferRef)imageBuffer;
        CVPixelBufferRetain(cbBuffer_);
        if (spDebug()) {

            if (dbgAttLogs_ < 3) {
                dbgAttLogs_++;
                CFStringRef t = (CFStringRef)CVBufferGetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, NULL);
                CFStringRef p = (CFStringRef)CVBufferGetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, NULL);
                SPLOG(@"[VT] 帧附件 trc=%@ pri=%@", t ? t : CFSTR("无"), p ? p : CFSTR("无"));
            }
        }
    }
    cbDone_ = true;
    cbCond_.notify_all();
}

static void decoderOutputCallback(void *refCon, void *sourceFrameRefCon, OSStatus status,
                                  VTDecodeInfoFlags flags, CVImageBufferRef imageBuffer,
                                  CMTime pts, CMTime duration) {
    SPVideoDecoder *self = (__bridge SPVideoDecoder *)refCon;
    int64_t ptsUs = AV_NOPTS_VALUE;
    if (pts.flags & kCMTimeFlags_Valid) {
        ptsUs = av_rescale_q(pts.value, (AVRational){1, (int)pts.timescale}, AV_TIME_BASE_Q);
    }
    [self handleDecodedFrame:imageBuffer status:status pts:ptsUs];
}

#pragma mark - Background decoder prewarming

+ (void)warmUpDecoderForCodecID:(int)codecID {
#if !SP_APP_STORE
    if (getenv("SP_NO_WARMUP")) return;
#endif
    AVCodecParameters par = {};
    par.codec_id = (AVCodecID)codecID;
    par.width = 16;
    par.height = 16;

    static const uint8_t h264SPS[] = {0x67,0x42,0x00,0x0a,0xf8,0x41,0xa2};
    static const uint8_t h264PPS[] = {0x68,0xce,0x06,0xe2};
    uint8_t avcc[128];
    size_t n = 0;
    if (codecID == AV_CODEC_ID_H264) {
        avcc[n++] = 1; avcc[n++] = 0x42; avcc[n++] = 0; avcc[n++] = 0x0a; // version/profile/level
        avcc[n++] = 0xFC | 1;
        avcc[n++] = 0; avcc[n++] = (uint8_t)sizeof(h264SPS);
        memcpy(avcc + n, h264SPS, sizeof(h264SPS)); n += sizeof(h264SPS);
        avcc[n++] = 1;
        avcc[n++] = 0; avcc[n++] = (uint8_t)sizeof(h264PPS);
        memcpy(avcc + n, h264PPS, sizeof(h264PPS)); n += sizeof(h264PPS);
    } else if (codecID == AV_CODEC_ID_HEVC) {

        static const uint8_t kWarmHvcC[] = {
        0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x78, 0xf0, 0x00, 0xfc, 0xfd, 0xf8, 0xf8, 0x00, 0x00, 0x0f, 0x04, 0x20,
        0x00, 0x01, 0x00, 0x18, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x01, 0x60,
        0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
        0x78, 0x95, 0x98, 0x09, 0x21, 0x00, 0x01, 0x00, 0x2a, 0x42, 0x01, 0x01,
        0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00,
        0x03, 0x00, 0x78, 0xa0, 0x03, 0xc0, 0x80, 0x10, 0xe5, 0x96, 0x56, 0x69,
        0x24, 0xca, 0xf0, 0x16, 0x80, 0x80, 0x00, 0x00, 0x03, 0x00, 0x80, 0x00,
        0x00, 0x0c, 0x04, 0x22, 0x00, 0x01, 0x00, 0x07, 0x44, 0x01, 0xc1, 0x72,
        0xb4, 0x62, 0x40, 0x27, 0x00, 0x01, 0x09, 0x10, 0x4e, 0x01, 0x05, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0b, 0x2c, 0xa2, 0xde,
        0x09, 0xb5, 0x17, 0x47, 0xdb, 0xbb, 0x55, 0xa4, 0xfe, 0x7f, 0xc2, 0xfc,
        0x4e, 0x78, 0x32, 0x36, 0x35, 0x20, 0x28, 0x62, 0x75, 0x69, 0x6c, 0x64,
        0x20, 0x32, 0x31, 0x36, 0x29, 0x20, 0x2d, 0x20, 0x34, 0x2e, 0x32, 0x2b,
        0x31, 0x2d, 0x65, 0x34, 0x34, 0x34, 0x37, 0x34, 0x34, 0x3a, 0x5b, 0x4d,
        0x61, 0x63, 0x20, 0x4f, 0x53, 0x20, 0x58, 0x5d, 0x5b, 0x63, 0x6c, 0x61,
        0x6e, 0x67, 0x20, 0x32, 0x31, 0x2e, 0x30, 0x2e, 0x30, 0x5d, 0x5b, 0x36,
        0x34, 0x20, 0x62, 0x69, 0x74, 0x5d, 0x20, 0x38, 0x62, 0x69, 0x74, 0x2b,
        0x31, 0x30, 0x62, 0x69, 0x74, 0x2b, 0x31, 0x32, 0x62, 0x69, 0x74, 0x20,
        0x2d, 0x20, 0x48, 0x2e, 0x32, 0x36, 0x35, 0x2f, 0x48, 0x45, 0x56, 0x43,
        0x20, 0x63, 0x6f, 0x64, 0x65, 0x63, 0x20, 0x2d, 0x20, 0x43, 0x6f, 0x70,
        0x79, 0x72, 0x69, 0x67, 0x68, 0x74, 0x20, 0x32, 0x30, 0x31, 0x33, 0x2d,
        0x32, 0x30, 0x31, 0x38, 0x20, 0x28, 0x63, 0x29, 0x20, 0x4d, 0x75, 0x6c,
        0x74, 0x69, 0x63, 0x6f, 0x72, 0x65, 0x77, 0x61, 0x72, 0x65, 0x2c, 0x20,
        0x49, 0x6e, 0x63, 0x20, 0x2d, 0x20, 0x68, 0x74, 0x74, 0x70, 0x3a, 0x2f,
        0x2f, 0x78, 0x32, 0x36, 0x35, 0x2e, 0x6f, 0x72, 0x67, 0x20, 0x2d, 0x20,
        0x6f, 0x70, 0x74, 0x69, 0x6f, 0x6e, 0x73, 0x3a, 0x20, 0x63, 0x70, 0x75,
        0x69, 0x64, 0x3d, 0x33, 0x34, 0x20, 0x66, 0x72, 0x61, 0x6d, 0x65, 0x2d,
        0x74, 0x68, 0x72, 0x65, 0x61, 0x64, 0x73, 0x3d, 0x33, 0x20, 0x77, 0x70,
        0x70, 0x20, 0x6e, 0x6f, 0x2d, 0x70, 0x6d, 0x6f, 0x64, 0x65, 0x20, 0x6e,
        0x6f, 0x2d, 0x70, 0x6d, 0x65, 0x20, 0x6e, 0x6f, 0x2d, 0x70, 0x73, 0x6e,
        0x72, 0x20, 0x6e, 0x6f, 0x2d, 0x73, 0x73, 0x69, 0x6d, 0x20, 0x6c, 0x6f,
        0x67, 0x2d, 0x6c, 0x65, 0x76, 0x65, 0x6c, 0x3d, 0x30, 0x20, 0x62, 0x69,
        0x74, 0x64, 0x65, 0x70, 0x74, 0x68, 0x3d, 0x38, 0x20, 0x69, 0x6e, 0x70,
        0x75, 0x74, 0x2d, 0x63, 0x73, 0x70, 0x3d, 0x31, 0x20, 0x66, 0x70, 0x73,
        0x3d, 0x32, 0x34, 0x2f, 0x31, 0x20, 0x69, 0x6e, 0x70, 0x75, 0x74, 0x2d,
        0x72, 0x65, 0x73, 0x3d, 0x31, 0x39, 0x32, 0x30, 0x78, 0x31, 0x30, 0x38,
        0x30, 0x20, 0x69, 0x6e, 0x74, 0x65, 0x72, 0x6c, 0x61, 0x63, 0x65, 0x3d,
        0x30, 0x20, 0x74, 0x6f, 0x74, 0x61, 0x6c, 0x2d, 0x66, 0x72, 0x61, 0x6d,
        0x65, 0x73, 0x3d, 0x30, 0x20, 0x6c, 0x65, 0x76, 0x65, 0x6c, 0x2d, 0x69,
        0x64, 0x63, 0x3d, 0x30, 0x20, 0x68, 0x69, 0x67, 0x68, 0x2d, 0x74, 0x69,
        0x65, 0x72, 0x3d, 0x31, 0x20, 0x75, 0x68, 0x64, 0x2d, 0x62, 0x64, 0x3d,
        0x30, 0x20, 0x72, 0x65, 0x66, 0x3d, 0x33, 0x20, 0x6e, 0x6f, 0x2d, 0x61,
        0x6c, 0x6c, 0x6f, 0x77, 0x2d, 0x6e, 0x6f, 0x6e, 0x2d, 0x63, 0x6f, 0x6e,
        0x66, 0x6f, 0x72, 0x6d, 0x61, 0x6e, 0x63, 0x65, 0x20, 0x6e, 0x6f, 0x2d,
        0x72, 0x65, 0x70, 0x65, 0x61, 0x74, 0x2d, 0x68, 0x65, 0x61, 0x64, 0x65,
        0x72, 0x73, 0x20, 0x61, 0x6e, 0x6e, 0x65, 0x78, 0x62, 0x20, 0x6e, 0x6f,
        0x2d, 0x61, 0x75, 0x64, 0x20, 0x6e, 0x6f, 0x2d, 0x65, 0x6f, 0x62, 0x20,
        0x6e, 0x6f, 0x2d, 0x65, 0x6f, 0x73, 0x20, 0x6e, 0x6f, 0x2d, 0x68, 0x72,
        0x64, 0x20, 0x69, 0x6e, 0x66, 0x6f, 0x20, 0x68, 0x61, 0x73, 0x68, 0x3d,
        0x30, 0x20, 0x74, 0x65, 0x6d, 0x70, 0x6f, 0x72, 0x61, 0x6c, 0x2d, 0x6c,
        0x61, 0x79, 0x65, 0x72, 0x73, 0x3d, 0x30, 0x20, 0x6f, 0x70, 0x65, 0x6e,
        0x2d, 0x67, 0x6f, 0x70, 0x20, 0x6d, 0x69, 0x6e, 0x2d, 0x6b, 0x65, 0x79,
        0x69, 0x6e, 0x74, 0x3d, 0x32, 0x34, 0x20, 0x6b, 0x65, 0x79, 0x69, 0x6e,
        0x74, 0x3d, 0x32, 0x35, 0x30, 0x20, 0x67, 0x6f, 0x70, 0x2d, 0x6c, 0x6f,
        0x6f, 0x6b, 0x61, 0x68, 0x65, 0x61, 0x64, 0x3d, 0x30, 0x20, 0x62, 0x66,
        0x72, 0x61, 0x6d, 0x65, 0x73, 0x3d, 0x34, 0x20, 0x62, 0x2d, 0x61, 0x64,
        0x61, 0x70, 0x74, 0x3d, 0x30, 0x20, 0x62, 0x2d, 0x70, 0x79, 0x72, 0x61,
        0x6d, 0x69, 0x64, 0x20, 0x62, 0x66, 0x72, 0x61, 0x6d, 0x65, 0x2d, 0x62,
        0x69, 0x61, 0x73, 0x3d, 0x30, 0x20, 0x72, 0x63, 0x2d, 0x6c, 0x6f, 0x6f,
        0x6b, 0x61, 0x68, 0x65, 0x61, 0x64, 0x3d, 0x31, 0x35, 0x20, 0x6c, 0x6f,
        0x6f, 0x6b, 0x61, 0x68, 0x65, 0x61, 0x64, 0x2d, 0x73, 0x6c, 0x69, 0x63,
        0x65, 0x73, 0x3d, 0x36, 0x20, 0x73, 0x63, 0x65, 0x6e, 0x65, 0x63, 0x75,
        0x74, 0x3d, 0x34, 0x30, 0x20, 0x6e, 0x6f, 0x2d, 0x68, 0x69, 0x73, 0x74,
        0x2d, 0x73, 0x63, 0x65, 0x6e, 0x65, 0x63, 0x75, 0x74, 0x20, 0x72, 0x61,
        0x64, 0x6c, 0x3d, 0x30, 0x20, 0x6e, 0x6f, 0x2d, 0x73, 0x70, 0x6c, 0x69,
        0x63, 0x65, 0x20, 0x6e, 0x6f, 0x2d, 0x69, 0x6e, 0x74, 0x72, 0x61, 0x2d,
        0x72, 0x65, 0x66, 0x72, 0x65, 0x73, 0x68, 0x20, 0x63, 0x74, 0x75, 0x3d,
        0x36, 0x34, 0x20, 0x6d, 0x69, 0x6e, 0x2d, 0x63, 0x75, 0x2d, 0x73, 0x69,
        0x7a, 0x65, 0x3d, 0x38, 0x20, 0x6e, 0x6f, 0x2d, 0x72, 0x65, 0x63, 0x74,
        0x20, 0x6e, 0x6f, 0x2d, 0x61, 0x6d, 0x70, 0x20, 0x6d, 0x61, 0x78, 0x2d,
        0x74, 0x75, 0x2d, 0x73, 0x69, 0x7a, 0x65, 0x3d, 0x33, 0x32, 0x20, 0x74,
        0x75, 0x2d, 0x69, 0x6e, 0x74, 0x65, 0x72, 0x2d, 0x64, 0x65, 0x70, 0x74,
        0x68, 0x3d, 0x31, 0x20, 0x74, 0x75, 0x2d, 0x69, 0x6e, 0x74, 0x72, 0x61,
        0x2d, 0x64, 0x65, 0x70, 0x74, 0x68, 0x3d, 0x31, 0x20, 0x6c, 0x69, 0x6d,
        0x69, 0x74, 0x2d, 0x74, 0x75, 0x3d, 0x30, 0x20, 0x72, 0x64, 0x6f, 0x71,
        0x2d, 0x6c, 0x65, 0x76, 0x65, 0x6c, 0x3d, 0x30, 0x20, 0x64, 0x79, 0x6e,
        0x61, 0x6d, 0x69, 0x63, 0x2d, 0x72, 0x64, 0x3d, 0x30, 0x2e, 0x30, 0x30,
        0x20, 0x6e, 0x6f, 0x2d, 0x73, 0x73, 0x69, 0x6d, 0x2d, 0x72, 0x64, 0x20,
        0x73, 0x69, 0x67, 0x6e, 0x68, 0x69, 0x64, 0x65, 0x20, 0x6e, 0x6f, 0x2d,
        0x74, 0x73, 0x6b, 0x69, 0x70, 0x20, 0x6e, 0x72, 0x2d, 0x69, 0x6e, 0x74,
        0x72, 0x61, 0x3d, 0x30, 0x20, 0x6e, 0x72, 0x2d, 0x69, 0x6e, 0x74, 0x65,
        0x72, 0x3d, 0x30, 0x20, 0x6e, 0x6f, 0x2d, 0x63, 0x6f, 0x6e, 0x73, 0x74,
        0x72, 0x61, 0x69, 0x6e, 0x65, 0x64, 0x2d, 0x69, 0x6e, 0x74, 0x72, 0x61,
        0x20, 0x73, 0x74, 0x72, 0x6f, 0x6e, 0x67, 0x2d, 0x69, 0x6e, 0x74, 0x72,
        0x61, 0x2d, 0x73, 0x6d, 0x6f, 0x6f, 0x74, 0x68, 0x69, 0x6e, 0x67, 0x20,
        0x6d, 0x61, 0x78, 0x2d, 0x6d, 0x65, 0x72, 0x67, 0x65, 0x3d, 0x32, 0x20,
        0x6c, 0x69, 0x6d, 0x69, 0x74, 0x2d, 0x72, 0x65, 0x66, 0x73, 0x3d, 0x33,
        0x20, 0x6e, 0x6f, 0x2d, 0x6c, 0x69, 0x6d, 0x69, 0x74, 0x2d, 0x6d, 0x6f,
        0x64, 0x65, 0x73, 0x20, 0x6d, 0x65, 0x3d, 0x31, 0x20, 0x73, 0x75, 0x62,
        0x6d, 0x65, 0x3d, 0x32, 0x20, 0x6d, 0x65, 0x72, 0x61, 0x6e, 0x67, 0x65,
        0x3d, 0x35, 0x37, 0x20, 0x74, 0x65, 0x6d, 0x70, 0x6f, 0x72, 0x61, 0x6c,
        0x2d, 0x6d, 0x76, 0x70, 0x20, 0x6e, 0x6f, 0x2d, 0x66, 0x72, 0x61, 0x6d,
        0x65, 0x2d, 0x64, 0x75, 0x70, 0x20, 0x6e, 0x6f, 0x2d, 0x68, 0x6d, 0x65,
        0x20, 0x77, 0x65, 0x69, 0x67, 0x68, 0x74, 0x70, 0x20, 0x6e, 0x6f, 0x2d,
        0x77, 0x65, 0x69, 0x67, 0x68, 0x74, 0x62, 0x20, 0x6e, 0x6f, 0x2d, 0x61,
        0x6e, 0x61, 0x6c, 0x79, 0x7a, 0x65, 0x2d, 0x73, 0x72, 0x63, 0x2d, 0x70,
        0x69, 0x63, 0x73, 0x20, 0x64, 0x65, 0x62, 0x6c, 0x6f, 0x63, 0x6b, 0x3d,
        0x30, 0x3a, 0x30, 0x20, 0x73, 0x61, 0x6f, 0x20, 0x6e, 0x6f, 0x2d, 0x73,
        0x61, 0x6f, 0x2d, 0x6e, 0x6f, 0x6e, 0x2d, 0x64, 0x65, 0x62, 0x6c, 0x6f,
        0x63, 0x6b, 0x20, 0x72, 0x64, 0x3d, 0x32, 0x20, 0x73, 0x65, 0x6c, 0x65,
        0x63, 0x74, 0x69, 0x76, 0x65, 0x2d, 0x73, 0x61, 0x6f, 0x3d, 0x34, 0x20,
        0x6e, 0x6f, 0x2d, 0x65, 0x61, 0x72, 0x6c, 0x79, 0x2d, 0x73, 0x6b, 0x69,
        0x70, 0x20, 0x72, 0x73, 0x6b, 0x69, 0x70, 0x20, 0x66, 0x61, 0x73, 0x74,
        0x2d, 0x69, 0x6e, 0x74, 0x72, 0x61, 0x20, 0x6e, 0x6f, 0x2d, 0x74, 0x73,
        0x6b, 0x69, 0x70, 0x2d, 0x66, 0x61, 0x73, 0x74, 0x20, 0x6e, 0x6f, 0x2d,
        0x63, 0x75, 0x2d, 0x6c, 0x6f, 0x73, 0x73, 0x6c, 0x65, 0x73, 0x73, 0x20,
        0x6e, 0x6f, 0x2d, 0x62, 0x2d, 0x69, 0x6e, 0x74, 0x72, 0x61, 0x20, 0x6e,
        0x6f, 0x2d, 0x73, 0x70, 0x6c, 0x69, 0x74, 0x72, 0x64, 0x2d, 0x73, 0x6b,
        0x69, 0x70, 0x20, 0x72, 0x64, 0x70, 0x65, 0x6e, 0x61, 0x6c, 0x74, 0x79,
        0x3d, 0x30, 0x20, 0x70, 0x73, 0x79, 0x2d, 0x72, 0x64, 0x3d, 0x32, 0x2e,
        0x30, 0x30, 0x20, 0x70, 0x73, 0x79, 0x2d, 0x72, 0x64, 0x6f, 0x71, 0x3d,
        0x30, 0x2e, 0x30, 0x30, 0x20, 0x6e, 0x6f, 0x2d, 0x72, 0x64, 0x2d, 0x72,
        0x65, 0x66, 0x69, 0x6e, 0x65, 0x20, 0x6e, 0x6f, 0x2d, 0x6c, 0x6f, 0x73,
        0x73, 0x6c, 0x65, 0x73, 0x73, 0x20, 0x63, 0x62, 0x71, 0x70, 0x6f, 0x66,
        0x66, 0x73, 0x3d, 0x30, 0x20, 0x63, 0x72, 0x71, 0x70, 0x6f, 0x66, 0x66,
        0x73, 0x3d, 0x30, 0x20, 0x72, 0x63, 0x3d, 0x63, 0x72, 0x66, 0x20, 0x63,
        0x72, 0x66, 0x3d, 0x32, 0x32, 0x2e, 0x30, 0x20, 0x71, 0x63, 0x6f, 0x6d,
        0x70, 0x3d, 0x30, 0x2e, 0x36, 0x30, 0x20, 0x71, 0x70, 0x73, 0x74, 0x65,
        0x70, 0x3d, 0x34, 0x20, 0x73, 0x74, 0x61, 0x74, 0x73, 0x2d, 0x77, 0x72,
        0x69, 0x74, 0x65, 0x3d, 0x30, 0x20, 0x73, 0x74, 0x61, 0x74, 0x73, 0x2d,
        0x72, 0x65, 0x61, 0x64, 0x3d, 0x30, 0x20, 0x69, 0x70, 0x72, 0x61, 0x74,
        0x69, 0x6f, 0x3d, 0x31, 0x2e, 0x34, 0x30, 0x20, 0x70, 0x62, 0x72, 0x61,
        0x74, 0x69, 0x6f, 0x3d, 0x31, 0x2e, 0x33, 0x30, 0x20, 0x61, 0x71, 0x2d,
        0x6d, 0x6f, 0x64, 0x65, 0x3d, 0x32, 0x20, 0x61, 0x71, 0x2d, 0x73, 0x74,
        0x72, 0x65, 0x6e, 0x67, 0x74, 0x68, 0x3d, 0x31, 0x2e, 0x30, 0x30, 0x20,
        0x63, 0x75, 0x74, 0x72, 0x65, 0x65, 0x20, 0x7a, 0x6f, 0x6e, 0x65, 0x2d,
        0x63, 0x6f, 0x75, 0x6e, 0x74, 0x3d, 0x30, 0x20, 0x6e, 0x6f, 0x2d, 0x73,
        0x74, 0x72, 0x69, 0x63, 0x74, 0x2d, 0x63, 0x62, 0x72, 0x20, 0x71, 0x67,
        0x2d, 0x73, 0x69, 0x7a, 0x65, 0x3d, 0x33, 0x32, 0x20, 0x6e, 0x6f, 0x2d,
        0x72, 0x63, 0x2d, 0x67, 0x72, 0x61, 0x69, 0x6e, 0x20, 0x71, 0x70, 0x6d,
        0x61, 0x78, 0x3d, 0x36, 0x39, 0x20, 0x71, 0x70, 0x6d, 0x69, 0x6e, 0x3d,
        0x30, 0x20, 0x6e, 0x6f, 0x2d, 0x63, 0x6f, 0x6e, 0x73, 0x74, 0x2d, 0x76,
        0x62, 0x76, 0x20, 0x73, 0x61, 0x72, 0x3d, 0x31, 0x20, 0x6f, 0x76, 0x65,
        0x72, 0x73, 0x63, 0x61, 0x6e, 0x3d, 0x30, 0x20, 0x76, 0x69, 0x64, 0x65,
        0x6f, 0x66, 0x6f, 0x72, 0x6d, 0x61, 0x74, 0x3d, 0x35, 0x20, 0x72, 0x61,
        0x6e, 0x67, 0x65, 0x3d, 0x30, 0x20, 0x63, 0x6f, 0x6c, 0x6f, 0x72, 0x70,
        0x72, 0x69, 0x6d, 0x3d, 0x32, 0x20, 0x74, 0x72, 0x61, 0x6e, 0x73, 0x66,
        0x65, 0x72, 0x3d, 0x32, 0x20, 0x63, 0x6f, 0x6c, 0x6f, 0x72, 0x6d, 0x61,
        0x74, 0x72, 0x69, 0x78, 0x3d, 0x32, 0x20, 0x63, 0x68, 0x72, 0x6f, 0x6d,
        0x61, 0x6c, 0x6f, 0x63, 0x3d, 0x30, 0x20, 0x64, 0x69, 0x73, 0x70, 0x6c,
        0x61, 0x79, 0x2d, 0x77, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x3d, 0x30, 0x20,
        0x63, 0x6c, 0x6c, 0x3d, 0x30, 0x2c, 0x30, 0x20, 0x6d, 0x69, 0x6e, 0x2d,
        0x6c, 0x75, 0x6d, 0x61, 0x3d, 0x30, 0x20, 0x6d, 0x61, 0x78, 0x2d, 0x6c,
        0x75, 0x6d, 0x61, 0x3d, 0x32, 0x35, 0x35, 0x20, 0x6c, 0x6f, 0x67, 0x32,
        0x2d, 0x6d, 0x61, 0x78, 0x2d, 0x70, 0x6f, 0x63, 0x2d, 0x6c, 0x73, 0x62,
        0x3d, 0x38, 0x20, 0x76, 0x75, 0x69, 0x2d, 0x74, 0x69, 0x6d, 0x69, 0x6e,
        0x67, 0x2d, 0x69, 0x6e, 0x66, 0x6f, 0x20, 0x76, 0x75, 0x69, 0x2d, 0x68,
        0x72, 0x64, 0x2d, 0x69, 0x6e, 0x66, 0x6f, 0x20, 0x73, 0x6c, 0x69, 0x63,
        0x65, 0x73, 0x3d, 0x31, 0x20, 0x6e, 0x6f, 0x2d, 0x6f, 0x70, 0x74, 0x2d,
        0x71, 0x70, 0x2d, 0x70, 0x70, 0x73, 0x20, 0x6e, 0x6f, 0x2d, 0x6f, 0x70,
        0x74, 0x2d, 0x72, 0x65, 0x66, 0x2d, 0x6c, 0x69, 0x73, 0x74, 0x2d, 0x6c,
        0x65, 0x6e, 0x67, 0x74, 0x68, 0x2d, 0x70, 0x70, 0x73, 0x20, 0x6e, 0x6f,
        0x2d, 0x6d, 0x75, 0x6c, 0x74, 0x69, 0x2d, 0x70, 0x61, 0x73, 0x73, 0x2d,
        0x6f, 0x70, 0x74, 0x2d, 0x72, 0x70, 0x73, 0x20, 0x73, 0x63, 0x65, 0x6e,
        0x65, 0x63, 0x75, 0x74, 0x2d, 0x62, 0x69, 0x61, 0x73, 0x3d, 0x30, 0x2e,
        0x30, 0x35, 0x20, 0x6e, 0x6f, 0x2d, 0x6f, 0x70, 0x74, 0x2d, 0x63, 0x75,
        0x2d, 0x64, 0x65, 0x6c, 0x74, 0x61, 0x2d, 0x71, 0x70, 0x20, 0x6e, 0x6f,
        0x2d, 0x61, 0x71, 0x2d, 0x6d, 0x6f, 0x74, 0x69, 0x6f, 0x6e, 0x20, 0x6e,
        0x6f, 0x2d, 0x68, 0x64, 0x72, 0x31, 0x30, 0x20, 0x6e, 0x6f, 0x2d, 0x68,
        0x64, 0x72, 0x31, 0x30, 0x2d, 0x6f, 0x70, 0x74, 0x20, 0x6e, 0x6f, 0x2d,
        0x64, 0x68, 0x64, 0x72, 0x31, 0x30, 0x2d, 0x6f, 0x70, 0x74, 0x20, 0x6e,
        0x6f, 0x2d, 0x69, 0x64, 0x72, 0x2d, 0x72, 0x65, 0x63, 0x6f, 0x76, 0x65,
        0x72, 0x79, 0x2d, 0x73, 0x65, 0x69, 0x20, 0x61, 0x6e, 0x61, 0x6c, 0x79,
        0x73, 0x69, 0x73, 0x2d, 0x72, 0x65, 0x75, 0x73, 0x65, 0x2d, 0x6c, 0x65,
        0x76, 0x65, 0x6c, 0x3d, 0x30, 0x20, 0x61, 0x6e, 0x61, 0x6c, 0x79, 0x73,
        0x69, 0x73, 0x2d, 0x73, 0x61, 0x76, 0x65, 0x2d, 0x72, 0x65, 0x75, 0x73,
        0x65, 0x2d, 0x6c, 0x65, 0x76, 0x65, 0x6c, 0x3d, 0x30, 0x20, 0x61, 0x6e,
        0x61, 0x6c, 0x79, 0x73, 0x69, 0x73, 0x2d, 0x6c, 0x6f, 0x61, 0x64, 0x2d,
        0x72, 0x65, 0x75, 0x73, 0x65, 0x2d, 0x6c, 0x65, 0x76, 0x65, 0x6c, 0x3d,
        0x30, 0x20, 0x73, 0x63, 0x61, 0x6c, 0x65, 0x2d, 0x66, 0x61, 0x63, 0x74,
        0x6f, 0x72, 0x3d, 0x30, 0x20, 0x72, 0x65, 0x66, 0x69, 0x6e, 0x65, 0x2d,
        0x69, 0x6e, 0x74, 0x72, 0x61, 0x3d, 0x30, 0x20, 0x72, 0x65, 0x66, 0x69,
        0x6e, 0x65, 0x2d, 0x69, 0x6e, 0x74, 0x65, 0x72, 0x3d, 0x30, 0x20, 0x72,
        0x65, 0x66, 0x69, 0x6e, 0x65, 0x2d, 0x6d, 0x76, 0x3d, 0x31, 0x20, 0x72,
        0x65, 0x66, 0x69, 0x6e, 0x65, 0x2d, 0x63, 0x74, 0x75, 0x2d, 0x64, 0x69,
        0x73, 0x74, 0x6f, 0x72, 0x74, 0x69, 0x6f, 0x6e, 0x3d, 0x30, 0x20, 0x6e,
        0x6f, 0x2d, 0x6c, 0x69, 0x6d, 0x69, 0x74, 0x2d, 0x73, 0x61, 0x6f, 0x20,
        0x63, 0x74, 0x75, 0x2d, 0x69, 0x6e, 0x66, 0x6f, 0x3d, 0x30, 0x20, 0x6e,
        0x6f, 0x2d, 0x6c, 0x6f, 0x77, 0x70, 0x61, 0x73, 0x73, 0x2d, 0x64, 0x63,
        0x74, 0x20, 0x72, 0x65, 0x66, 0x69, 0x6e, 0x65, 0x2d, 0x61, 0x6e, 0x61,
        0x6c, 0x79, 0x73, 0x69, 0x73, 0x2d, 0x74, 0x79, 0x70, 0x65, 0x3d, 0x30,
        0x20, 0x63, 0x6f, 0x70, 0x79, 0x2d, 0x70, 0x69, 0x63, 0x3d, 0x31, 0x20,
        0x6d, 0x61, 0x78, 0x2d, 0x61, 0x75, 0x73, 0x69, 0x7a, 0x65, 0x2d, 0x66,
        0x61, 0x63, 0x74, 0x6f, 0x72, 0x3d, 0x31, 0x2e, 0x30, 0x20, 0x6e, 0x6f,
        0x2d, 0x64, 0x79, 0x6e, 0x61, 0x6d, 0x69, 0x63, 0x2d, 0x72, 0x65, 0x66,
        0x69, 0x6e, 0x65, 0x20, 0x6e, 0x6f, 0x2d, 0x73, 0x69, 0x6e, 0x67, 0x6c,
        0x65, 0x2d, 0x73, 0x65, 0x69, 0x20, 0x6e, 0x6f, 0x2d, 0x68, 0x65, 0x76,
        0x63, 0x2d, 0x61, 0x71, 0x20, 0x6e, 0x6f, 0x2d, 0x73, 0x76, 0x74, 0x20,
        0x6e, 0x6f, 0x2d, 0x66, 0x69, 0x65, 0x6c, 0x64, 0x20, 0x71, 0x70, 0x2d,
        0x61, 0x64, 0x61, 0x70, 0x74, 0x61, 0x74, 0x69, 0x6f, 0x6e, 0x2d, 0x72,
        0x61, 0x6e, 0x67, 0x65, 0x3d, 0x31, 0x2e, 0x30, 0x30, 0x20, 0x73, 0x63,
        0x65, 0x6e, 0x65, 0x63, 0x75, 0x74, 0x2d, 0x61, 0x77, 0x61, 0x72, 0x65,
        0x2d, 0x71, 0x70, 0x3d, 0x30, 0x63, 0x6f, 0x6e, 0x66, 0x6f, 0x72, 0x6d,
        0x61, 0x6e, 0x63, 0x65, 0x2d, 0x77, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x2d,
        0x6f, 0x66, 0x66, 0x73, 0x65, 0x74, 0x73, 0x20, 0x72, 0x69, 0x67, 0x68,
        0x74, 0x3d, 0x30, 0x20, 0x62, 0x6f, 0x74, 0x74, 0x6f, 0x6d, 0x3d, 0x30,
        0x20, 0x64, 0x65, 0x63, 0x6f, 0x64, 0x65, 0x72, 0x2d, 0x6d, 0x61, 0x78,
        0x2d, 0x72, 0x61, 0x74, 0x65, 0x3d, 0x30, 0x20, 0x6e, 0x6f, 0x2d, 0x76,
        0x62, 0x76, 0x2d, 0x6c, 0x69, 0x76, 0x65, 0x2d, 0x6d, 0x75, 0x6c, 0x74,
        0x69, 0x2d, 0x70, 0x61, 0x73, 0x73, 0x20, 0x6e, 0x6f, 0x2d, 0x6d, 0x63,
        0x73, 0x74, 0x66, 0x20, 0x6e, 0x6f, 0x2d, 0x73, 0x62, 0x72, 0x63, 0x20,
        0x6e, 0x6f, 0x2d, 0x66, 0x72, 0x61, 0x6d, 0x65, 0x2d, 0x72, 0x63, 0x80};
        par.width = 1920;
        par.height = 1080;
        par.extradata = (uint8_t *)kWarmHvcC;
        par.extradata_size = (int)sizeof(kWarmHvcC);
        SPVideoDecoder *vt = [[SPVideoDecoder alloc] init];
        [vt setupWithCodecParameters:&par timeBaseNumerator:1 timeBaseDenominator:1];
        [vt shutdown];
        return;
    } else {
        return;
    }
    par.extradata = avcc;
    par.extradata_size = (int)n;
    SPVideoDecoder *vt = [[SPVideoDecoder alloc] init];
    [vt setupWithCodecParameters:&par timeBaseNumerator:1 timeBaseDenominator:1];
    [vt shutdown];
}

#pragma mark - Session setup

- (int)setupWithCodecParameters:(const AVCodecParameters *)par
              timeBaseNumerator:(int64_t)tbNum
            timeBaseDenominator:(int64_t)tbDen {
    [self shutdown];

    tbNum_ = tbNum > 0 ? tbNum : 1;
    tbDen_ = tbDen > 0 ? tbDen : 1;
    width_ = par->width;
    height_ = par->height;

    CMVideoCodecType codecType = codecTypeForFFmpeg((AVCodecID)par->codec_id, par->profile);
    if (codecType == 0) return -1;
    codecType_ = codecType;
    deinterlacePropertiesAttempted_ = false;
    codedParameterSetsScratch_.clear();
    codedSPSFingerprint_ = 0;
    codedHEVCConfig_ = SPHEVCScanConfig::Unknown;
    codedConfigTainted_ = false;
    codedInterlacedSeen_ =
        par->field_order != AV_FIELD_UNKNOWN &&
        par->field_order != AV_FIELD_PROGRESSIVE;
    bitstreamNALLengthSize_ = 4;
    if (par->extradata && par->extradata_size > 0) {
        if (par->codec_id == AV_CODEC_ID_H264 && par->extradata_size >= 5 &&
            par->extradata[0] == 1) {
            bitstreamNALLengthSize_ = (par->extradata[4] & 3) + 1;
        } else if (par->codec_id == AV_CODEC_ID_HEVC &&
                   par->extradata_size >= 22 && par->extradata[0] == 1) {
            bitstreamNALLengthSize_ = (par->extradata[21] & 3) + 1;
        }
    }
    hevcMaxTid_ = 0;
    hevcTidPackets_ = 0;

    reorder_.configure(MAX(4, MIN(par->video_delay, 16)),
                       par->video_delay > 0, _spLogId);

    NSData *extradata = nil;
    if (par->extradata && par->extradata_size > 0) {
        extradata = [NSData dataWithBytes:par->extradata length:par->extradata_size];
    }
    NSMutableDictionary *atoms = [NSMutableDictionary dictionary];
    if (extradata.length) {
        switch (codecType) {
            case kCMVideoCodecType_H264: atoms[@"avcC"] = extradata; break;
            case kCMVideoCodecType_HEVC: atoms[@"hvcC"] = extradata; break;
            case spFourCC('m','p','4','v'): {
                NSData *esds = [self makeESDSWithExtradata:extradata];
                if (esds) atoms[@"esds"] = esds;
                break;
            }
            case spFourCC('a','v','0','1'):

                atoms[@"av1C"] = extradata;
                break;
            default: break;
        }
    }
    if (codecType == spFourCC('v','p','0','9')) {

        NSData *vpcc = [self makeVPCCWithParameters:par];
        if (vpcc) atoms[@"vpcC"] = vpcc;
    }
    NSDictionary *ext = nil;
    if (atoms.count) {
        ext = @{ (__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms : atoms };
    }
    CMVideoDimensions dims = {(int32_t)par->width, (int32_t)par->height};
    int64_t tFmt = spNowUs();

    OSStatus err = noErr;
    if (dims.width > 0 && dims.height > 0) {
        err = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codecType,
                                             dims.width, dims.height,
                                             (__bridge CFDictionaryRef)ext, &formatDesc_);
    }
    if (spDebug()) {
        SPLOG(@"[VT] formatDesc=%.1fms", (spNowUs() - tFmt) / 1000.0);
    }
    if (err != noErr) { formatDesc_ = NULL; }

    annexBBitstream_ = false;
    paramSetFp_ = 0;
    if ((codecType == kCMVideoCodecType_H264 || codecType == kCMVideoCodecType_HEVC) &&
        extradata.length >= 4) {
        const uint8_t *ed = (const uint8_t *)extradata.bytes;
        if ((ed[0] == 0 && ed[1] == 0 && ed[2] == 1) ||
            (ed[0] == 0 && ed[1] == 0 && ed[2] == 0 && ed[3] == 1)) {
            annexBBitstream_ = true;

            paramSetFp_ = spParamSetFpAnnexB(ed, extradata.length,
                                             codecType == kCMVideoCodecType_HEVC);
        }
    }
    if (codecType == kCMVideoCodecType_H264 || codecType == kCMVideoCodecType_HEVC) {
        const uint32_t stableTag = codecType == kCMVideoCodecType_H264
            ? spFFmpegCodecTag('a', 'v', 'c', '1')
            : spFFmpegCodecTag('h', 'v', 'c', '1');
        // avc1/hvc1 carry their active parameter sets in the sample description.
        // Annex-B, avc3/hev1, Matroska and unknown tags may update them in-band.
        codedConfigCanChangeInBand_ = annexBBitstream_ || par->codec_tag != stableTag;
        SPNormalizedScanParameterSets initialSets = spNormalizedScanParameterSets(
            par->extradata, (size_t)MAX(par->extradata_size, 0),
            codecType == kCMVideoCodecType_HEVC, SPScanDataKind::Extradata,
            bitstreamNALLengthSize_);
        if (initialSets.valid && !initialSets.bytes.empty()) {
            [self observeCodedParameterSets:initialSets.bytes baseline:YES];
        } else if (codecType == kCMVideoCodecType_HEVC &&
                   !codedConfigCanChangeInBand_) {
            // A valid hev1/Annex-B stream may intentionally carry no parameter
            // arrays in its setup record. With no prior proof to preserve, the
            // first in-band SPS is the current configuration rather than a
            // conflict. Stable hvc1 without parseable arrays remains tainted.
            codedConfigTainted_ = true;
        }
    } else {
        codedConfigCanChangeInBand_ = false;
    }

    if (!formatDesc_ && codecType == kCMVideoCodecType_H264) {
        formatDesc_ = [self makeFormatDescriptionFromAvcC:extradata];
    }
    if (!formatDesc_ && codecType == kCMVideoCodecType_HEVC) {

        formatDesc_ = [self makeFormatDescriptionFromHvcCParameterSets:extradata];
    }

    if (annexBBitstream_ && (codecType == kCMVideoCodecType_H264 || codecType == kCMVideoCodecType_HEVC)) {
        if (formatDesc_) { CFRelease(formatDesc_); formatDesc_ = NULL; }
        formatDesc_ = [self makeFormatDescriptionFromAnnexBWithCodec:codecType
                                                           extradata:extradata];
        if (spDebug()) {
            SPLOG(@"[VT] Annex-B 参数集建描述: %@", formatDesc_ ? @"成功" : @"失败");
        }
    }
    if (!formatDesc_) return -2;
    [self applyColorExtensionsWithParameters:par];

    if (__builtin_available(macOS 11.0, *)) {
        VTRegisterSupplementalVideoDecoderIfAvailable(codecType);
    }
    NSDictionary *decoderSpec = @{
        (__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder : @NO,
    };
    NSMutableDictionary *destAttrs = [@{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @[
            @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),   // P010（10-bit HDR）
            @(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),    // NV12（8-bit）
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        ],
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    } mutableCopy];

    if (self.outputWidthHint > 0 && self.outputHeightHint > 0) {

        destAttrs[(__bridge NSString *)kCVPixelBufferWidthKey] = @(self.outputWidthHint);
        destAttrs[(__bridge NSString *)kCVPixelBufferHeightKey] = @(self.outputHeightHint);
    } else if (width_ > 0 && height_ > 0) {
        destAttrs[(__bridge NSString *)kCVPixelBufferWidthKey] = @(width_);
        destAttrs[(__bridge NSString *)kCVPixelBufferHeightKey] = @(height_);
    }
    VTDecompressionOutputCallbackRecord cb = { decoderOutputCallback, (__bridge void *)self };

    std::unique_lock<std::mutex> firstSessionLock(gVtFirstSessionMtx, std::defer_lock);
    int64_t tLatchWait = 0;
    if (!gVtDriverLoaded.load(std::memory_order_acquire)) {
        int64_t tLatch = spNowUs();
        firstSessionLock.lock();
        tLatchWait = spNowUs() - tLatch;
    }
    int64_t tSess = spNowUs();
    err = VTDecompressionSessionCreate(kCFAllocatorDefault, formatDesc_,
                                       (__bridge CFDictionaryRef)decoderSpec,
                                       (__bridge CFDictionaryRef)destAttrs,
                                       &cb, &session_);
    if (spDebug()) {
        if (tLatchWait > 0) {
            SPLOG(@"[VT] sessionCreate=%.1fms err=%d 首建等锁=%.1fms",
                  (spNowUs() - tSess) / 1000.0, (int)err,
                  tLatchWait / 1000.0);
        } else {
            SPLOG(@"[VT] sessionCreate=%.1fms err=%d", (spNowUs() - tSess) / 1000.0, (int)err);
        }
    }
    if (err != noErr && codecType == kCMVideoCodecType_HEVC) {

        CMVideoFormatDescriptionRef clean =
            [self makeFormatDescriptionFromHvcCParameterSets:extradata];
        if (!clean && self.firstPacketHint) {
            clean = [self makeFormatDescriptionFromHEVCPacket:self.firstPacketHint];
        }
        if (clean) {
            CFRelease(formatDesc_);
            formatDesc_ = clean;
            session_ = NULL;
            err = VTDecompressionSessionCreate(kCFAllocatorDefault, formatDesc_,
                                               (__bridge CFDictionaryRef)decoderSpec,
                                               (__bridge CFDictionaryRef)destAttrs,
                                               &cb, &session_);
            if (spDebug()) SPLOG(@"[VT] 参数集重试 err=%d", (int)err);
        }
    }

    if (err == noErr) gVtDriverLoaded.store(true, std::memory_order_release);
    if (firstSessionLock.owns_lock()) firstSessionLock.unlock();
    if (err != noErr) { session_ = NULL; return -3; }

    if (codedInterlacedSeen_ ||
        (par->field_order != AV_FIELD_PROGRESSIVE &&
         par->field_order != AV_FIELD_UNKNOWN)) {
        [self requestFrameLocalDeinterlacingIfNeeded:@"stream setup"];
    }

    CFBooleanRef hw = NULL;
    if (VTSessionCopyProperty(session_,
                    kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                    kCFAllocatorDefault, &hw) == noErr) {
        _isHardwareDecoding = (hw == kCFBooleanTrue);
        if (hw) CFRelease(hw);
    } else {
        _isHardwareDecoding = YES;
    }
    return 0;
}

- (void)applyColorExtensionsWithParameters:(const AVCodecParameters *)par {
    CFStringRef pri = sp::spCVColorPrimaries(par->color_primaries);
    CFStringRef trc = sp::spCVTransferFunction(par->color_trc);
    CFStringRef mat = sp::spCVYCbCrMatrix(par->color_space);

    BOOL rangeDeclared = (par->color_range == AVCOL_RANGE_JPEG ||
                          par->color_range == AVCOL_RANGE_MPEG);
    BOOL fullRange = (par->color_range == AVCOL_RANGE_JPEG);
    if (!pri && !trc && !mat && !rangeDeclared) return;

    CFDictionaryRef oldExt = CMFormatDescriptionGetExtensions(formatDesc_);
    NSMutableDictionary *ext = oldExt ? [(__bridge NSDictionary *)oldExt mutableCopy]
                                      : [NSMutableDictionary dictionary];
    if (pri) ext[(__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries] = (__bridge id)pri;
    if (trc) ext[(__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction] = (__bridge id)trc;
    if (mat) ext[(__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix] = (__bridge id)mat;
    if (rangeDeclared) ext[(__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo] = @(fullRange);

    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(formatDesc_);
    CMVideoFormatDescriptionRef nd = NULL;
    OSStatus err = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codecType_,
                                                  dims.width, dims.height,
                                                  (__bridge CFDictionaryRef)ext, &nd);
    if (err == noErr && nd) {
        CFRelease(formatDesc_);
        formatDesc_ = nd;
        if (spDebug()) {
            SPLOG(@"[VT] 色彩扩展已写入 formatDesc: pri=%@ trc=%@ mat=%@ full=%d",
                  pri ? (__bridge NSString *)pri : @"(未声明)",
                  trc ? (__bridge NSString *)trc : @"(未声明)",
                  mat ? (__bridge NSString *)mat : @"(未声明)", (int)fullRange);
        }
    } else if (spDebug()) {
        SPLOG(@"[VT] 色彩扩展写入失败 err=%d（保留原描述）", (int)err);
    }
}

#pragma mark - Parameter sets

- (NSData *)makeVPCCWithParameters:(const AVCodecParameters *)par {
    uint8_t buf[12] = {0};
    int profile = par->profile >= 0 ? par->profile : 0;

    int bitDepth = 0;
    const AVPixFmtDescriptor *pd = av_pix_fmt_desc_get((AVPixelFormat)par->format);
    if (pd && pd->nb_components > 0) bitDepth = pd->comp[0].depth;
    if (bitDepth <= 0 && par->bits_per_raw_sample > 0) bitDepth = par->bits_per_raw_sample;
    if (bitDepth <= 0) bitDepth = (profile >= 2) ? 10 : 8;

    int subsampling = 1;
    if (pd) {
        if (pd->log2_chroma_w == 0 && pd->log2_chroma_h == 0) subsampling = 3;
        else if (pd->log2_chroma_w == 1 && pd->log2_chroma_h == 0) subsampling = 2;
    } else if (profile == 1 || profile == 3) {
        subsampling = 3;
    }
    buf[0] = 1;                                  // version
    buf[1] = buf[2] = buf[3] = 0;                // flags
    buf[4] = (uint8_t)profile;
    buf[5] = (uint8_t)(par->level > 0 ? par->level : 0);
    buf[6] = (uint8_t)((bitDepth << 4) | (subsampling << 1) |
                       (par->color_range == AVCOL_RANGE_JPEG));
    buf[7] = (uint8_t)(par->color_primaries > 0 ? par->color_primaries : 2);
    buf[8] = (uint8_t)(par->color_trc > 0 ? par->color_trc : 2);
    buf[9] = (uint8_t)(par->color_space > 0 ? par->color_space : 2);
    buf[10] = buf[11] = 0;                       // codecInitializationDataSize=0
    return [NSData dataWithBytes:buf length:sizeof(buf)];
}

- (NSData *)makeESDSWithExtradata:(NSData *)extradata {
    size_t exSize = extradata.length;
    if (exSize == 0 || exSize > 0xFFFFFF) return nil;
    int fullSize = (int)(3 + 5 + 13 + 5 + exSize + 3);
    int configSize = (int)(13 + 5 + exSize);
    std::vector<uint8_t> b;
    b.reserve(fullSize);
    b.push_back(0);                              // version
    b.push_back(0); b.push_back(0); b.push_back(0); // flags
    b.push_back(0x03);                           // ES_DescrTag
    spAppendDescrLength(b, fullSize);
    b.push_back(0); b.push_back(0);              // esid
    b.push_back(0);                              // stream priority
    b.push_back(0x04);                           // DecoderConfigDescrTag
    spAppendDescrLength(b, configSize);
    b.push_back(32);                             // object type: MPEG-4 Visual
    b.push_back(0x11);                           // stream type: video
    b.push_back(0); b.push_back(0); b.push_back(0); // buffer size 24bit
    b.push_back(0); b.push_back(0); b.push_back(0); b.push_back(0); // max bitrate
    b.push_back(0); b.push_back(0); b.push_back(0); b.push_back(0); // avg bitrate
    b.push_back(0x05);                           // DecSpecificInfoTag
    spAppendDescrLength(b, (int)exSize);
    const uint8_t *ex = (const uint8_t *)extradata.bytes;
    b.insert(b.end(), ex, ex + exSize);
    b.push_back(0x06);                           // SLConfigDescrTag
    b.push_back(0x01);                           // length
    b.push_back(0x02);
    return [NSData dataWithBytes:b.data() length:b.size()];
}

- (CMVideoFormatDescriptionRef)makeFormatDescriptionFromAvcC:(NSData *)extradata {
    if (!extradata || extradata.length < 8) return NULL;
    const uint8_t *p = (const uint8_t *)extradata.bytes;
    size_t n = extradata.length;

    // avcC: [0]=version [1]=profile [2]=compat [3]=level [4]=0xFC|lengthSizeMinusOne
    //       [5]=0xE0|numSPS, [len,sps]*, numPPS, [len,pps]*
    if (p[0] != 1) return NULL;
    if (n < 6) return NULL;

    int nalLenSize = (p[4] & 0x3) + 1;
    size_t i = 5;
    int numSPS = p[i++] & 0x1F;
    std::vector<const uint8_t *> spsPtrs; std::vector<size_t> spsSizes;
    for (int k = 0; k < numSPS && i + 2 <= n; k++) {
        size_t len = (p[i] << 8) | p[i+1]; i += 2;
        if (i + len > n) return NULL;
        spsPtrs.push_back(p + i); spsSizes.push_back(len);
        i += len;
    }
    if (i >= n) return NULL;
    int numPPS = p[i++];
    std::vector<const uint8_t *> ppsPtrs; std::vector<size_t> ppsSizes;
    for (int k = 0; k < numPPS && i + 2 <= n; k++) {
        size_t len = (p[i] << 8) | p[i+1]; i += 2;
        if (i + len > n) return NULL;
        ppsPtrs.push_back(p + i); ppsSizes.push_back(len);
        i += len;
    }

    std::vector<const uint8_t *> allPtrs = spsPtrs;
    std::vector<size_t> allSizes = spsSizes;
    allPtrs.insert(allPtrs.end(), ppsPtrs.begin(), ppsPtrs.end());
    allSizes.insert(allSizes.end(), ppsSizes.begin(), ppsSizes.end());
    if (allPtrs.empty()) return NULL;

    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus err = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, (int)allPtrs.size(), allPtrs.data(), allSizes.data(),
        nalLenSize, &desc);
    return (err == noErr) ? desc : NULL;
}

- (CMVideoFormatDescriptionRef)makeFormatDescriptionFromHEVCPacket:(NSData *)pkt {
    if (!pkt || pkt.length < 8) return NULL;
    const uint8_t *p = (const uint8_t *)pkt.bytes;
    size_t n = pkt.length;
    std::vector<const uint8_t *> ptrs;
    std::vector<size_t> sizes;

    const int lenSize = (bitstreamNALLengthSize_ >= 1 && bitstreamNALLengthSize_ <= 4)
                            ? bitstreamNALLengthSize_ : 4;
    size_t i = 0;
    for (;;) {
        size_t len = 0;
        if (!spReadNALLength(p, n, i, lenSize, &len)) break;
        i += (size_t)lenSize;
        int t = (p[i] >> 1) & 0x3F;
        if (t == 32 || t == 33 || t == 34) { // VPS/SPS/PPS
            ptrs.push_back(p + i);
            sizes.push_back(len);
        }
        i += len;
    }
    if (ptrs.empty()) return NULL;
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus err = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        kCFAllocatorDefault, (int)ptrs.size(), ptrs.data(), sizes.data(), lenSize, NULL, &desc);
    return (err == noErr) ? desc : NULL;
}

- (CMVideoFormatDescriptionRef)makeFormatDescriptionFromHvcCParameterSets:(NSData *)extradata {
    if (!extradata || extradata.length < 24) return NULL;
    const uint8_t *p = (const uint8_t *)extradata.bytes;
    size_t n = extradata.length;
    if (p[0] != 1) return NULL; // configurationVersion
    int nalLenSize = (p[21] & 0x3) + 1;
    size_t i = 22;
    int numArrays = p[i++];
    std::vector<const uint8_t *> ptrs;
    std::vector<size_t> sizes;
    for (int a = 0; a < numArrays && i + 3 <= n; a++) {
        int nalType = p[i] & 0x3F;
        i++;
        int numNalus = (p[i] << 8) | p[i + 1];
        i += 2;
        for (int k = 0; k < numNalus && i + 2 <= n; k++) {
            size_t len = (p[i] << 8) | p[i + 1];
            i += 2;
            if (i + len > n) return NULL;
            if (nalType == 32 || nalType == 33 || nalType == 34) {
                ptrs.push_back(p + i);
                sizes.push_back(len);
            }
            i += len;
        }
    }
    if (ptrs.empty()) return NULL;
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus err = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        kCFAllocatorDefault, (int)ptrs.size(), ptrs.data(), sizes.data(), nalLenSize, NULL, &desc);
    return (err == noErr) ? desc : NULL;
}

- (CMVideoFormatDescriptionRef)makeFormatDescriptionFromAnnexBWithCodec:(CMVideoCodecType)codec
                                                               extradata:(NSData *)extradata {
    if (!extradata || extradata.length < 8) return NULL;
    const uint8_t *p = (const uint8_t *)extradata.bytes;
    size_t n = extradata.length;
    bool hevc = (codec == kCMVideoCodecType_HEVC);
    std::vector<const uint8_t *> ptrs;
    std::vector<size_t> sizes;
    if (hevc) {
        spExtractAnnexBParams(p, n, 32, true, ptrs, sizes); // VPS
        spExtractAnnexBParams(p, n, 33, true, ptrs, sizes); // SPS
        spExtractAnnexBParams(p, n, 34, true, ptrs, sizes); // PPS
    } else {
        spExtractAnnexBParams(p, n, 7, false, ptrs, sizes);  // SPS
        spExtractAnnexBParams(p, n, 8, false, ptrs, sizes);  // PPS
    }
    if (ptrs.empty()) return NULL;
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus err;
    if (hevc) {
        err = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            kCFAllocatorDefault, (int)ptrs.size(), ptrs.data(), sizes.data(),
            4, NULL, &desc);
    } else {
        err = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault, (int)ptrs.size(), ptrs.data(), sizes.data(),
            4, &desc);
    }
    return (err == noErr) ? desc : NULL;
}

#pragma mark - Decoding

- (bool)stickyInterlacedVerdict {
    return interpolationScanEnabled_ && interpolationScanInterlaced_;
}

- (SPDecodedVideoOutput)decodePacketOutput:(const AVPacket *)pkt {
    lastError_.store(0);

    if (!pkt || pkt->size <= 0) {
        [self waitAsyncIfNeeded];
        return reorder_.drainNext([self stickyInterlacedVerdict]);
    }

    if (pkt->pts != AV_NOPTS_VALUE && pkt->dts != AV_NOPTS_VALUE && pkt->pts != pkt->dts) {
        reorder_.noteReorderRequired();
    }

    const uint8_t *pktData = pkt->data;
    size_t pktSize = (size_t)pkt->size;
    const bool h264 = codecType_ == kCMVideoCodecType_H264;
    const bool hevc = codecType_ == kCMVideoCodecType_HEVC;
    size_t codedExtraSize = 0;
    uint8_t *codedExtra = nullptr;
    int packetNALLengthSize = bitstreamNALLengthSize_;
    if ((h264 || hevc) && pkt->side_data_elems > 0) {
        codedExtra = av_packet_get_side_data(
            pkt, AV_PKT_DATA_NEW_EXTRADATA, &codedExtraSize);
        // The new sample description applies to this access unit.  Parse its
        // framing before walking the payload; using the previous length width
        // could miss the very SPS that invalidates an old progressive proof.
        if (codedExtra && h264 && codedExtraSize >= 5 && codedExtra[0] == 1) {
            packetNALLengthSize = (codedExtra[4] & 3) + 1;
        } else if (codedExtra && hevc && codedExtraSize >= 22 &&
                   codedExtra[0] == 1) {
            packetNALLengthSize = (codedExtra[21] & 3) + 1;
        }
    }
    codedParameterSetsScratch_.clear();
    if (annexBBitstream_) {
        annexBBuf_.clear();
        if (annexBBuf_.capacity() < pktSize + 64) annexBBuf_.reserve(pktSize + 64);
        spAnnexBToAVCC(pktData, pktSize, annexBBuf_,
                       hevc, (h264 || hevc) ? &codedParameterSetsScratch_ : nullptr);
        pktData = annexBBuf_.data();
        pktSize = annexBBuf_.size();
    } else if ((h264 || hevc) && codedConfigCanChangeInBand_) {
        // avc3/hev1/Matroska may carry a one-shot SPS while MEMC is Off. Walk
        // only the small pre-VCL prefix; most ordinary packets stop at their
        // first NAL, and HEVC already paid this walk to learn temporal_id.
        spInspectLengthPrefixedPacket(
            pktData, pktSize, packetNALLengthSize, hevc,
            &codedParameterSetsScratch_, hevc ? &hevcMaxTid_ : nullptr,
            hevc ? &hevcTidPackets_ : nullptr);
    }
    if (pktSize == 0) { lastError_.store(1); return SPDecodedVideoOutputEmpty(); }
    if (!formatDesc_) {
        if (spDebug()) SPLOG(@"[VT] formatDesc 为空");
        lastError_.store(3);
        return SPDecodedVideoOutputEmpty();
    }

    if (!codedParameterSetsScratch_.empty()) {
        [self observeCodedParameterSets:codedParameterSetsScratch_ baseline:NO];
    }
    if ((h264 || hevc) && codedExtra && codedExtraSize > 0) {
            SPNormalizedScanParameterSets extraSets =
                spNormalizedScanParameterSets(codedExtra, codedExtraSize, hevc,
                                                SPScanDataKind::Extradata,
                                                packetNALLengthSize);
            if (extraSets.valid) {
                // Empty parameter arrays are legal for avc3/hev1: the current
                // AU may carry the first in-band SPS. Preserve the new framing
                // width without tainting the proof the payload ledger just
                // established for this same access unit.
                bitstreamNALLengthSize_ = packetNALLengthSize;
                if (!extraSets.bytes.empty()) {
                    [self observeCodedParameterSets:extraSets.bytes baseline:NO];
                }
            } else {
                // A changed but malformed sample description cannot retain an
                // earlier positive progressive authorization.
                codedConfigTainted_ = true;
            }
    }

    // Parse the original compressed packet (Annex-B or length-prefixed) after
    // the mandatory coded-config ledger has observed this same AU. This order
    // matters for hev1/avc3 streams whose setup extradata contains no arrays:
    // the first in-band SPS is both the current configuration proof and the
    // first random-access picture, so scanning before observing it would leave
    // the entire stream permanently Unknown. The packet itself is unchanged by
    // the AVCC scratch conversion above. Parser resources remain absent in Off.
    if (interpolationScanEnabled_) {
        [self inspectPacketForInterpolation:pkt];
    }

    int64_t pts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
    if (pts == AV_NOPTS_VALUE) {

        pts = synthNextPtsTicks_;
    }
    {
        int64_t durTicks = pkt->duration > 0 ? pkt->duration
                                             : tbDen_ / (tbNum_ * 25);
        if (durTicks <= 0) durTicks = 1;
        synthNextPtsTicks_ = pts + durTicks;
    }
    int64_t ptsUsEarly = av_rescale_q(pts, (AVRational){(int)tbNum_, (int32_t)tbDen_}, AV_TIME_BASE_Q);

    if (hevc && hevcTidPackets_ < 1000000 &&
        (annexBBitstream_ || !codedConfigCanChangeInBand_)) {
        spInspectLengthPrefixedPacket(pktData, pktSize,
                                      annexBBitstream_ ? 4 : bitstreamNALLengthSize_,
                                      true, nullptr, &hevcMaxTid_, &hevcTidPackets_);
    }

    int64_t cuTarget = catchUpTargetUs_.load();
    bool catchUp = (cuTarget > 0 && ptsUsEarly + 80000 < cuTarget);

    if (catchUp && (pkt->flags & AV_PKT_FLAG_KEY)) {
        size_t nxs = 0;
        if (av_packet_get_side_data(pkt, AV_PKT_DATA_NEW_EXTRADATA, &nxs) && nxs > 0) {
            catchUp = false;
        } else if (annexBBitstream_ && paramSetFp_ != 0) {
            uint64_t fp = spParamSetFpAvcc(pktData, pktSize,
                                           codecType_ == kCMVideoCodecType_HEVC);
            if (fp != 0 && fp != paramSetFp_) {
                catchUp = false;
                if (spDebug()) SPLOG(@"[VT] 追赶区参数集切换 → 同步路径浮现错误");
            }
        }
    }
    if (catchUp) {

        reorder_.noteCatchUpSubmitted();

#if SP_APP_STORE
        static const bool noNrDrop = false;
#else
        static const bool noNrDrop = getenv("SP_NO_NRDROP") != nullptr;
#endif
        if (!noNrDrop) {
            bool drop = false;
            const int packetLengthSize = annexBBitstream_ ? 4 : bitstreamNALLengthSize_;
            if (codecType_ == kCMVideoCodecType_H264) {
                drop = spH264IsNonRef(pktData, pktSize, packetLengthSize);
            } else if (codecType_ == kCMVideoCodecType_HEVC && hevcTidPackets_ >= kTidLearnMin) {
                int t = spHevcNonRefTid(pktData, pktSize, packetLengthSize);
                drop = (t >= 0 && t >= hevcMaxTid_);
            }
            if (drop) {
                nrDropped_++;
                if (spDebug() && (nrDropped_ % 64 == 1)) {
                    SPLOG(@"[VT] 追赶丢弃非参考帧 累计=%lld", nrDropped_);
                }
                return SPDecodedVideoOutputEmpty();
            }
        }

        CMBlockBufferRef cblock = NULL;
        OSStatus cerr = kCMBlockBufferBadPointerParameterErr;
        if (pktData == pkt->data && pkt->buf) {
            if (AVBufferRef *ref = av_buffer_ref(pkt->buf)) {
                CMBlockBufferCustomBlockSource src = {};
                src.version = kCMBlockBufferCustomBlockSourceVersion;
                src.FreeBlock = spAVBufferBlockFree;
                src.refCon = ref;
                cerr = CMBlockBufferCreateWithMemoryBlock(
                    kCFAllocatorDefault, (void *)pktData, pktSize, kCFAllocatorNull,
                    &src, 0, pktSize, 0, &cblock);
                if (cerr != noErr) { av_buffer_unref(&ref); cblock = NULL; }
            }
        }
        if (cerr != noErr) {
            cerr = CMBlockBufferCreateWithMemoryBlock(
                kCFAllocatorDefault, NULL, pktSize, kCFAllocatorDefault,
                NULL, 0, pktSize, kCMBlockBufferAssureMemoryNowFlag, &cblock);
            if (cerr == noErr) cerr = CMBlockBufferReplaceDataBytes(pktData, cblock, 0, pktSize);
        }
        if (cerr == noErr) {

            CMSampleTimingInfo ctiming = {
                .duration = CMTimeMake(av_rescale_q(pkt->duration, (AVRational){(int)tbNum_, (int)tbDen_}, AV_TIME_BASE_Q), 1000000),
                .presentationTimeStamp = CMTimeMake(ptsUsEarly, 1000000),
                .decodeTimeStamp = kCMTimeInvalid,
            };
            CMSampleBufferRef csbuf = NULL;
            size_t csz = pktSize;
            cerr = CMSampleBufferCreate(kCFAllocatorDefault, cblock, true, NULL, NULL,
                                        formatDesc_, 1, 1, &ctiming, 1, &csz, &csbuf);
            if (cerr == noErr) {
                VTDecodeFrameFlags dflags = kVTDecodeFrame_DoNotOutputFrame |
                                            kVTDecodeFrame_EnableAsynchronousDecompression;
                if (VTDecompressionSessionDecodeFrame(session_, csbuf, dflags, NULL, NULL) == noErr) {
                    asyncInFlight_ = true;
                }
                CFRelease(csbuf);
            }
        }
        if (cblock) CFRelease(cblock);
        return SPDecodedVideoOutputEmpty();
    }
    [self waitAsyncIfNeeded];

    CMBlockBufferRef block = NULL;
    OSStatus err = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, (void *)pktData, pktSize, kCFAllocatorNull,
        NULL, 0, pktSize, 0, &block);
    if (err != noErr) { if (spDebug()) SPLOG(@"[VT] CMBlockBuffer 失败 %d", (int)err); lastError_.store(2); return SPDecodedVideoOutputEmpty(); }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(av_rescale_q(pkt->duration, (AVRational){(int)tbNum_, (int)tbDen_}, AV_TIME_BASE_Q), 1000000),
        .presentationTimeStamp = CMTimeMake(ptsUsEarly, 1000000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sbuf = NULL;
    size_t sampleSize = pktSize;
    err = CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL,
                               formatDesc_, 1, 1, &timing, 1, &sampleSize, &sbuf);
    CFRelease(block);
    if (err != noErr) { if (spDebug()) SPLOG(@"[VT] CMSampleBuffer 失败 %d", (int)err); lastError_.store(4); return SPDecodedVideoOutputEmpty(); }

    {
        std::lock_guard<std::mutex> lock(cbMu_);
        cbDone_ = false;
        cbStatus_ = noErr;
        if (cbBuffer_) { CVPixelBufferRelease(cbBuffer_); cbBuffer_ = NULL; }
    }

    VTDecodeInfoFlags flags = 0;
    // Keep this submission synchronous (all flags clear). VideoToolbox then
    // invokes the output callback before DecodeFrame returns, so the scan
    // verdict computed for this access unit is still the one associated with
    // its returned surface. If temporal processing or multiple in-flight
    // frames are introduced, sourceFrameRefCon must carry a per-submission
    // verdict instead of relying on this invariant.
    err = VTDecompressionSessionDecodeFrame(session_, sbuf, 0, NULL, &flags);
    CFRelease(sbuf);
    if (err != noErr) {
        if (spDebug()) {
            if (++dbgDecodeErrLogs_ <= 3) SPLOG(@"[VT] DecodeFrame 错误 %d (flags=%u)", (int)err, (unsigned)flags);
        }
        lastError_.store(err != 0 ? (int)err : 5);
        return SPDecodedVideoOutputEmpty();
    }

    CVPixelBufferRef out = NULL;
    int64_t callbackPtsUs = AV_NOPTS_VALUE;
    {
        std::unique_lock<std::mutex> lock(cbMu_);
        cbCond_.wait(lock, [&] { return cbDone_; });
        if (spDebug() && cbStatus_ != noErr) {
            if (++dbgCbErrLogs_ <= 3) SPLOG(@"[VT] 回调错误 status=%d", (int)cbStatus_);
        }
        if (cbStatus_ != noErr) {
            lastError_.store(cbStatus_ != 0 ? (int)cbStatus_ : 6);
        } else if (cbBuffer_) {
            out = cbBuffer_;
            cbBuffer_ = NULL;
        }

        callbackPtsUs = cbPtsUs_;
    }
    const int64_t fallbackPtsUs = ptsUsEarly;
    const int64_t outPtsUs = callbackPtsUs != AV_NOPTS_VALUE
        ? callbackPtsUs : fallbackPtsUs;
    const bool scanCovered = interpolationScanEnabled_ &&
        interpolationScanKnown_ && !interpolationScanInterlaced_ &&
        (interpolationScanSafeFromPTSUs_ == INT64_MIN ||
         interpolationCurrentPacketScanCovered_);
    SPDecodedVideoScanVerdict scanVerdict = SPDecodedVideoScanVerdictUnknown;
    if (interpolationScanEnabled_) {
        if (interpolationScanInterlaced_) {
            scanVerdict = SPDecodedVideoScanVerdictInterlaced;
        } else if (scanCovered) {
            scanVerdict = SPDecodedVideoScanVerdictProgressive;
        }
    }
    if (out) {

        return reorder_.accept(out, outPtsUs, scanVerdict, scanCovered,
                               [self stickyInterlacedVerdict]);
    }

    return reorder_.popConfirmed([self stickyInterlacedVerdict]);
}

- (void)flush {
    [self waitAsyncIfNeeded];

    if (interpolationScanEnabled_ && !interpolationScanInterlaced_ &&
        interpolationScanSafeFromPTSUs_ != INT64_MIN) {
        // A seek/discontinuity may land after an in-band parameter-set change.
        // Never inherit a previous progressive authorization across it.
        (void)[self rebuildInterpolationScanParser];
        interpolationScanKnown_ = false;
        interpolationScanAwaitingRandomAccess_ = true;
        interpolationScanSafeFromPTSUs_ = INT64_MAX;
        if (codedConfigCanChangeInBand_) {

            [self reseedInterpolationScanConfigFingerprint];
        }
    }

    {
        std::lock_guard<std::mutex> lock(cbMu_);
        cbDone_ = true;
        cbStatus_ = noErr;
        if (cbBuffer_) { CVPixelBufferRelease(cbBuffer_); cbBuffer_ = NULL; }
    }

    reorder_.reset();
    synthNextPtsTicks_ = 0;
}

- (void)shutdown {
    [self waitAsyncIfNeeded];
    [self setInterpolationScanEnabled:NO codecParameters:nullptr];
    if (session_) {
        VTDecompressionSessionInvalidate(session_);
        CFRelease(session_);
        session_ = NULL;
    }
    deinterlacePropertiesAttempted_ = false;
    if (formatDesc_) {
        CFRelease(formatDesc_);
        formatDesc_ = NULL;
    }
    {
        std::lock_guard<std::mutex> lock(cbMu_);
        if (cbBuffer_) { CVPixelBufferRelease(cbBuffer_); cbBuffer_ = NULL; }
    }

    reorder_.reset();
    synthNextPtsTicks_ = 0;
}

- (SPVideoDecodingBackend)decodingBackend {
    return SPVideoDecodingBackendVideoToolbox;
}
- (int)lastError { return lastError_.load(); }
- (NSString *)decoderName { return _isHardwareDecoding ? NSLocalizedString(@"renderer.decoder.vtHW", nil) : @"VideoToolbox"; }

@end
