#import "SPDoviDecoder.h"
#import "SPDoviFrame.h"
#import "SPVideoDecoder.h"
#import "SPFFmpegDecoder.h"
#import <VideoToolbox/VTErrors.h>
#import <CoreMedia/CMFormatDescription.h>
#include "SPDoviRPU.hpp"
#include "SPDoviAV1Replay.hpp"
#include "../Core/SPDoviConfig.hpp"
#include "../Core/SPDoviPacket.hpp"
#include "SPRuntimeGates.hpp"
#include <map>
#include <set>
#include <deque>
#include <memory>
#include <vector>
#include <array>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mathematics.h>
}

namespace {
constexpr size_t kMaxEnhancementBytes = 64 * 1024 * 1024;
constexpr size_t kMaxBaseBytes = 256 * 1024 * 1024;
constexpr size_t kMaxPendingFrames = 16;
using ParameterSets = sp::DoviParameterSets;
using MetadataBytes = SPDoviMetadataBytes;
struct EnhancementPicture {
    bool hasVcl = false;
    bool key = false;
};
size_t frameBytes(CVPixelBufferRef b) {
    size_t sum = 0;
    for (size_t p = 0; p < CVPixelBufferGetPlaneCount(b); ++p)
        sum += CVPixelBufferGetBytesPerRowOfPlane(b,p) * CVPixelBufferGetHeightOfPlane(b,p);
    return sum;
}
void appendAnnexBNal(std::vector<uint8_t>& bytes, const uint8_t *nal, size_t size) {
    bytes.insert(bytes.end(), {0,0,0,1});
    bytes.insert(bytes.end(), nal, nal + size);
}
const AVDOVIDecoderConfigurationRecord *doviConfig(const AVCodecParameters *par) {
    if (!par || (par->codec_id != AV_CODEC_ID_HEVC && par->codec_id != AV_CODEC_ID_AV1 &&
                 par->codec_id != AV_CODEC_ID_H264)) return nullptr;
    return sp::doviConfig(par);
}
bool applyEnhancementPacketConfig(const AVPacket *packet, sp::DoviParameterBank& bank) {
    size_t size = 0;
    const auto *extra = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &size);
    if (!extra) return true;
    sp::DoviParameterBank next;
    const bool valid = sp::doviReadHEVCConfig(extra, size, next);
    // Configuration is independent of this packet's picture payload. Even a
    // damaged update invalidates the old bank; later slices cannot borrow it.
    bank = std::move(next);
    return valid;
}
bool extractEnhancement(const std::vector<sp::DoviNal>& nals, sp::DoviParameterBank& bank,
                        ParameterSets& sets,
                        std::vector<uint8_t>& bytes, bool& vcl, bool& key, bool direct) {
    unsigned activePPS = 64;
    for (const auto& nal : nals) {
        const int outerType = (nal.data[0] >> 1) & 63;
        const size_t skip = outerType == 63 ? 2 : 0;
        if ((!direct && !skip) || outerType == 62 || nal.size < skip + 2) continue;
        const uint8_t *data = nal.data + skip;
        const size_t size = nal.size - skip;
        const int type = (data[0] >> 1) & 63;
        if ((data[0] & 0x80) || !(data[1] & 7) || type >= 62) continue;
        if (type <= 31) {
            unsigned pps;
            if (!sp::doviSlicePPS({data, size}, pps) || (activePPS != 64 && activePPS != pps)) return false;
            activePPS = pps;
            vcl = true;
        }
        key |= type >= 16 && type <= 23;
        if (type >= 32 && type <= 34) {
            if (!bank.add({data, size})) return false;
            continue;
        }
        appendAnnexBNal(bytes, data, size);
    }
    if (!vcl) return true;
    if (!bank.select(activePPS, sets)) return false;
    if (key) {
        // The packet hint must describe the referenced chain, not whichever
        // parameter set happened to be last in the configuration record.
        std::vector<uint8_t> prefix;
        for (const auto& set : sets) appendAnnexBNal(prefix, set.data(), set.size());
        bytes.insert(bytes.begin(), prefix.begin(), prefix.end());
    }
    return true;
}
// EL dimensions from its own parameter sets. VT reads them from the packet
// hint, but the software decoder builds its output pool at setup and refuses
// unknown (0x0) dimensions; the EL is not required to match the BL size.
void fillEnhancementDimensions(AVCodecParameters *par, const ParameterSets& sets) {
    const uint8_t *ptrs[3]; size_t sizes[3]; size_t count = 0;
    for (const auto& set : sets) {
        if (set.empty()) continue;
        ptrs[count] = set.data(); sizes[count] = set.size(); ++count;
    }
    if (count < 2) return;
    CMFormatDescriptionRef desc = nullptr;
    if (CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, count,
            ptrs, sizes, 4, nullptr, &desc) != noErr || !desc) return;
    const CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(desc);
    CFRelease(desc);
    if (dims.width > 0 && dims.height > 0) { par->width = dims.width; par->height = dims.height; }
}
// Legacy P2/P3 carry an 8-bit EL; every later dual-layer profile is 10-bit.
int enhancementBitDepth(int profile) { return profile == 2 || profile == 3 ? 8 : 10; }
id<SPVideoDecoding> makeEnhancementDecoder(int videoDelay, AVRational tb,
    const ParameterSets& parameterSets, const std::vector<uint8_t>& firstPacket,
    unsigned logId, bool preferSoftware, bool singleFrame, int outputWidth, int outputHeight,
    int bitDepth) {
    // EL carries its own VPS/SPS/PPS. BL hvcC has the wrong dimensions and DPB.
    AVCodecParameters *par = avcodec_parameters_alloc();
    if (!par) return nil;
    par->codec_type = AVMEDIA_TYPE_VIDEO;
    par->codec_id = AV_CODEC_ID_HEVC;
    par->format = bitDepth == 8 ? AV_PIX_FMT_YUV420P : AV_PIX_FMT_YUV420P10LE;
    par->color_range = AVCOL_RANGE_MPEG;
    par->video_delay = videoDelay;
    fillEnhancementDimensions(par, parameterSets);
    std::vector<uint8_t> sets;
    for (const auto& set : parameterSets)
        if (!set.empty()) appendAnnexBNal(sets, set.data(), set.size());
    if (!sets.empty()) {
        par->extradata = (uint8_t *)av_mallocz(sets.size() + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!par->extradata) { avcodec_parameters_free(&par); return nil; }
        memcpy(par->extradata, sets.data(), sets.size());
        par->extradata_size = (int)sets.size();
    }
    id<SPVideoDecoding> decoder = nil;
    if (!preferSoftware) {
        SPVideoDecoder *vt = [SPVideoDecoder new]; vt.spLogId = logId;
        vt.outputWidthHint = outputWidth; vt.outputHeightHint = outputHeight;
        vt.firstPacketHint = [NSData dataWithBytes:firstPacket.data() length:firstPacket.size()];
        if ([vt setupWithCodecParameters:par timeBaseNumerator:tb.num
                    timeBaseDenominator:tb.den] == 0) decoder = vt;
        else [vt shutdown];
        vt.firstPacketHint = nil;
    }
    if (!decoder) {
        SPFFmpegDecoder *sw = [SPFFmpegDecoder new]; sw.spLogId = logId;
        sw.preserveChromaLocation = YES;
        sw.outputWidthHint = outputWidth; sw.outputHeightHint = outputHeight;
        sw.singleFrameMode = singleFrame; // race: slice threads, no frame delay
        const int ret = [sw setupWithCodecParameters:par timeBaseNumerator:tb.num
                                 timeBaseDenominator:tb.den];
        if (ret == 0) decoder = sw;
        else {
            [sw shutdown];
            if (spDebug()) NSLog(@"[c%u][DoVi] software EL setup failed ret=%d %dx%d",
                                 logId, ret, par->width, par->height);
        }
    }
    avcodec_parameters_free(&par);
    if (spDebug()) NSLog(@"[c%u][DoVi] enhancement decoder=%@", logId,
        decoder ? decoder.decoderName : @"unavailable; compatible BL");
    return decoder;
}
}

@interface SPDoviEnhancementPreparation : NSObject {
@public
    id<SPVideoDecoding> decoder;
    ParameterSets sets;
    sp::DoviParameterBank bank;
}
@end
@implementation SPDoviEnhancementPreparation
- (void)dealloc { [decoder shutdown]; }
@end

@interface SPDoviDecoder : NSObject <SPVideoDecoding>
@property (nonatomic) int previewWidth;
@property (nonatomic) int previewHeight;
@property (nonatomic) BOOL previewMode;
@property (nonatomic) BOOL backendChanged;
- (instancetype)initWithBase:(id<SPVideoDecoding>)base
                  parameters:(const AVCodecParameters *)par
                          tb:(AVRational)tb
                      config:(AVDOVIDecoderConfigurationRecord)config
                    prepared:(SPDoviEnhancementPreparation *)prepared
                 speculative:(BOOL)speculative;
@end

@implementation SPDoviDecoder {
    id<SPVideoDecoding> _base;
    // A failed session is closed immediately. Nil is the single authority for
    // needing a new EL session at a suitable random-access picture.
    id<SPVideoDecoding> _enhancement;
    int _videoDelay;
    AVRational _tb;
    int _nalLengthSize;
    int _profile;
    bool _dualLayer;
    AVCodecID _codec;
    uint64_t _association;
    unsigned _spLogId;
    int64_t _catchUp;
    bool _elPreferSoftware;
    bool _elSpeculative; // first-frame race: EL after BL, same EL policy, no BL-only fallback
    unsigned _elErrorStreak;
    bool _elDrained;
    bool _rejectUnsupportedRPU, _requiresMetadata, _metadataUnsupported;
    int _loggedMode;
    std::unique_ptr<sp::DoviParser> _parser;
    std::map<int64_t, MetadataBytes> _metadata;
    std::set<int64_t> _previousAssociationPts;
    std::set<int64_t> _ambiguousAssociationPts;
    bool _associationMetadataOverflow;
    MetadataBytes _lastMetadata;
    std::map<int64_t, CVPixelBufferRef> _elFrames;
    // BL pictures already inside the BL decoder when the current EL session
    // began: their EL was never fed, so waiting for it would only hold surfaces.
    std::set<int64_t> _elUnreachablePts;
    std::deque<SPDecodedVideoOutput> _baseFrames;
    size_t _pendingBaseBytes, _pendingEnhancementBytes;
    std::vector<sp::DoviNal> _nals;
    std::vector<uint8_t> _elBytes;
    ParameterSets _elSets;
    sp::DoviParameterBank _elBank;
    AVPacket *_elPacket;
    std::unique_ptr<sp::DoviAV1Replay> _av1Replay;
    int _pictureActivationFailures; // transient P10 handoff failures (bounded retries)
    int64_t _replayDiscardThrough;
}
- (instancetype)initWithBase:(id<SPVideoDecoding>)base
                  parameters:(const AVCodecParameters *)par
                          tb:(AVRational)tb
                      config:(AVDOVIDecoderConfigurationRecord)cfg
                    prepared:(SPDoviEnhancementPreparation *)prepared
                 speculative:(BOOL)speculative {
    if (!(self = [super init])) return nil;
    _tb = tb; _profile = cfg.dv_profile; _codec = par->codec_id; _catchUp = -1; _loggedMode = -1;
    _dualLayer = sp::doviHEVCDualLayerSupported(par);
    _elSpeculative = speculative;
    const auto metadataPolicy = sp::doviMetadataPolicy(&cfg);
    _rejectUnsupportedRPU = metadataPolicy.rejectUnsupportedRPU;
    _requiresMetadata = metadataPolicy.requireFrameMetadata;
    _spLogId = base.spLogId;
    _nalLengthSize = sp::doviNalLengthSize(par);
    _videoDelay = par->video_delay;
    sp::doviReadEnhancementConfig(par, _elBank);
    _parser = std::make_unique<sp::DoviParser>(cfg.dv_profile,
        cfg.dv_bl_signal_compatibility_id, cfg.dv_md_compression);
    if (_profile == 10) _parser->setAV1Config(par->extradata, std::max(par->extradata_size,0));
    _elPacket = av_packet_alloc();
    if (!_elPacket) return nil;
    _replayDiscardThrough = INT64_MIN;
    if (_profile == 10 && base.decodingBackend == SPVideoDecodingBackendVideoToolbox) {
        auto replay = std::make_unique<sp::DoviAV1Replay>(par);
        if (replay->parameters()) _av1Replay = std::move(replay);
    }
    // Take ownership only after fallible allocation, so returning the already
    // configured base on allocation failure cannot return a shut-down decoder.
    _base = base;
    if (prepared && prepared->decoder) {
        _enhancement = prepared->decoder;
        prepared->decoder = nil; // transfer, including cancellation ownership
        _elSets = std::move(prepared->sets);
        _elBank = std::move(prepared->bank);
    }
    return self;
}
- (void)dealloc {
    [self shutdown];
    av_packet_free(&_elPacket);
}
- (int)setupWithCodecParameters:(const AVCodecParameters *)par
              timeBaseNumerator:(int64_t)n timeBaseDenominator:(int64_t)d {
    return [_base setupWithCodecParameters:par timeBaseNumerator:n timeBaseDenominator:d];
}
- (void)clearPairs {
    for (auto f : _baseFrames) CVPixelBufferRelease(f.pixelBuffer);
    for (auto entry : _elFrames) CVPixelBufferRelease(entry.second);
    _baseFrames.clear(); _elFrames.clear(); _metadata.clear(); _lastMetadata.reset();
    _elUnreachablePts.clear();
    _previousAssociationPts.clear(); _ambiguousAssociationPts.clear();
    _associationMetadataOverflow = false;
    _pendingBaseBytes = _pendingEnhancementBytes = 0;
}
- (void)flush {
    [_base flush]; [_enhancement flush]; _parser->reset();
    [self clearPairs];
    _elDrained = false;
    _metadataUnsupported = false;
    _elErrorStreak = 0;
    if (_av1Replay) _av1Replay->resetForSeek();
    _replayDiscardThrough = INT64_MIN;
    // A missing EL after a seek must never reuse one from the previous GOP.
}
- (void)shutdown {
    [_base shutdown]; [self closeEnhancement];
    [self clearPairs];
    if (_parser) _parser->reset();
    _av1Replay.reset();
}
- (void)setCatchUpTargetUs:(int64_t)us {
    _catchUp = us; [_base setCatchUpTargetUs:us]; [_enhancement setCatchUpTargetUs:us];
}
- (void)setInterpolationScanEnabled:(BOOL)enabled codecParameters:(const AVCodecParameters *)par {
    // The frame generator also requires identical, valid single-layer metadata.
    [_base setInterpolationScanEnabled:enabled codecParameters:par];
}
- (BOOL)isHardwareDecoding { return _base.isHardwareDecoding; }
- (SPVideoDecodingBackend)decodingBackend { return _base.decodingBackend; }
- (NSString *)decoderName { return _base.decoderName; }
- (int)lastError {
    if (_metadataUnsupported) return kSPDoviMetadataUnsupportedError;
    return _av1Replay && _av1Replay->required ? 0 : _base.lastError;
}
- (unsigned)spLogId { return _spLogId; }
- (void)setSpLogId:(unsigned)n { _spLogId=n; _base.spLogId=n; _enhancement.spLogId=n; }

- (void)storeBase:(SPDecodedVideoOutput)out {
    if (!out.pixelBuffer) return;
    // Reordered software output can arrive after the initial replay call.
    // Keep the old presentation frontier until seek, not just during replay.
    if (_replayDiscardThrough != INT64_MIN && out.ptsUs <= _replayDiscardThrough) {
        CVPixelBufferRelease(out.pixelBuffer); return;
    }
    _pendingBaseBytes += frameBytes(out.pixelBuffer);
    _baseFrames.push_back(out);
}

// The handoff failed. Retry a transient failure on a later GOP a few times;
// then, or at once for a permanent one, keep VideoToolbox: its pictures show
// without picture-associated metadata rather than not at all.
- (BOOL)pictureDecoderUnavailable:(BOOL)permanent {
    _av1Replay->clear();
    if (!permanent && ++_pictureActivationFailures < 3) return NO;
    _av1Replay.reset();
    if (spDebug()) NSLog(@"[c%u][DoVi] P10 picture association unavailable; keeping VideoToolbox", _spLogId);
    return NO;
}

- (BOOL)activatePictureDecoder {
    if (!_av1Replay || !_av1Replay->ready()) return NO;
    SPFFmpegDecoder *candidate = [SPFFmpegDecoder new];
    candidate.spLogId = _spLogId;
    candidate.planarOutputEnabled = YES; // direct dav1d: picture-owned T.35
    if ([candidate setupWithCodecParameters:_av1Replay->parameters()
            timeBaseNumerator:_tb.num timeBaseDenominator:_tb.den] != 0) {
        [candidate shutdown]; // a later configuration update may still succeed
        return [self pictureDecoderUnavailable:NO];
    }
    const int64_t frontier = _av1Replay->returnedThrough;
    [candidate setCatchUpTargetUs:std::max(_catchUp, frontier)];
    std::vector<SPDecodedVideoOutput> ready;
    size_t bytes = 0;
    bool ok = true;
    for (const auto& packet : _av1Replay->packets()) {
        const auto out = [candidate decodePacketOutput:packet.get()];
        if (out.pixelBuffer) {
            if (frontier != INT64_MIN && out.ptsUs <= frontier) CVPixelBufferRelease(out.pixelBuffer);
            else { ready.push_back(out); bytes += frameBytes(out.pixelBuffer); }
        }
        if (candidate.lastError || ready.size() > kMaxPendingFrames || bytes > kMaxBaseBytes) { ok = false; break; }
    }
    if (!ok || !candidate.doviPictureMetadataActive) {
        for (auto out : ready) CVPixelBufferRelease(out.pixelBuffer);
        // Without picture metadata dav1d fell back to avcodec: that will not
        // change on a later GOP. A damaged GOP or budget overrun might.
        const bool permanent = ok;
        [candidate shutdown];
        return [self pictureDecoderUnavailable:permanent];
    }
    // Preserve the core's clocks, seek generation and packet queue. Capability
    // fallback stays on software across seeks, without the damaged-VT retry loop.
    [_base shutdown]; [self clearPairs];
    _base = candidate; _backendChanged = YES;
    _replayDiscardThrough = frontier;
    _av1Replay.reset(); _parser->reset();
    [_base setCatchUpTargetUs:_catchUp];
    for (auto out : ready) [self storeBase:out];
    if (spDebug()) NSLog(@"[c%u][DoVi] P10 picture association switched to dav1d", _spLogId);
    return YES;
}

- (void)storeEnhancement:(SPDecodedVideoOutput)out {
    if (!out.pixelBuffer) return;
    if (out.ptsUs == INT64_MIN) { CVPixelBufferRelease(out.pixelBuffer); return; }
    auto old = _elFrames.find(out.ptsUs);
    if (old != _elFrames.end()) {
        _pendingEnhancementBytes -= frameBytes(old->second);
        CVPixelBufferRelease(old->second);
        _elFrames.erase(old);
    }
    _pendingEnhancementBytes += frameBytes(out.pixelBuffer);
    _elFrames.emplace(out.ptsUs, out.pixelBuffer);
    // Also bound EL if a damaged BL produces no outputs for an entire GOP.
    while (_elFrames.size() > kMaxPendingFrames ||
           (_pendingEnhancementBytes > kMaxEnhancementBytes && !_elFrames.empty())) {
        auto it = _elFrames.begin();
        _pendingEnhancementBytes -= frameBytes(it->second);
        CVPixelBufferRelease(it->second); _elFrames.erase(it);
    }
}
- (void)drainEnhancement {
    if (!_enhancement) return;
    for (int i = 0; i < 64; ++i) {
        auto out = [_enhancement decodePacketOutput:nullptr];
        if (!out.pixelBuffer) break;
        [self storeEnhancement:out];
    }
}
- (void)closeEnhancement {
    [_enhancement shutdown]; _enhancement = nil;
    _elErrorStreak = 0; _elDrained = false;
    // Keep the software preference and already decoded EL pictures. Closing
    // a session cannot invalidate earlier outputs waiting for their BL.
}
- (void)retireEnhancement {
    [self drainEnhancement];
    [self closeEnhancement];
}
// `_nals` already holds this packet's NAL units (empty when it did not split).
- (EnhancementPicture)prepareEnhancementPacket:(const AVPacket *)packet separate:(BOOL)separate {
    _elBytes.clear();
    if (separate && !applyEnhancementPacketConfig(packet, _elBank))
        [self retireEnhancement];
    if (_nals.empty()) return {};
    ParameterSets selected;
    EnhancementPicture picture;
    if (!extractEnhancement(_nals, _elBank, selected, _elBytes, picture.hasVcl, picture.key, separate)) {
        [self retireEnhancement];
        _elBytes.clear();
        return {};
    }
    if (picture.hasVcl && selected != _elSets) {
        [self retireEnhancement];
        _elSets = std::move(selected);
    }
    return picture;
}
- (SPDecodedVideoOutput)takeReady:(BOOL)draining {
    // Walk only the frames already queued; missing metadata is not EOF, and
    // discarding consecutive heads must not recurse through the decoder.
    while (!_baseFrames.empty()) {
        const auto out = _baseFrames.front();
        auto meta = _metadata.find(out.ptsUs);
        const bool fromPicture = _profile == 10 &&
            CVBufferGetAttachment(out.pixelBuffer, kSPDoviPictureMetadata, nullptr);
        const MetadataBytes pictureMetadata = fromPicture
            ? MetadataBytes::fromFrame(out.pixelBuffer) : MetadataBytes{};
        // Two pictures may share a packet PTS. Decoder-owned metadata must travel
        // with its surface, never through a PTS-keyed map that can overwrite it.
        const CFDataRef data = fromPicture ? pictureMetadata.get() :
            meta != _metadata.end() ? meta->second.get() : nullptr;
        bool valid = data != nullptr;
        const auto *gpu = valid ? reinterpret_cast<const SPDoviUniforms *>(
            CFDataGetBytePtr(data)) : nullptr;
        const bool fel = gpu && gpu->values[sp::dovi_gpu::NeedsEnhancement] > 0.5f;
        auto el = _elFrames.find(out.ptsUs);
        const bool elReachable = !_elUnreachablePts.erase(out.ptsUs);
        if (fel && el == _elFrames.end() && _enhancement && elReachable && !draining &&
            _pendingBaseBytes < kMaxBaseBytes && _baseFrames.size() < kMaxPendingFrames &&
            (_elFrames.empty() || _elFrames.rbegin()->first < out.ptsUs))
            return SPDecodedVideoOutputEmpty();
        // Consuming the queue head always retires its byte charge and PTS entry;
        // the caller either transfers the surface to its output or releases it.
        const auto consumeBase = [&] {
            _pendingBaseBytes -= frameBytes(out.pixelBuffer);
            _baseFrames.pop_front();
            if (meta != _metadata.end()) _metadata.erase(meta);
        };
        const bool missingRequiredMetadata = _requiresMetadata && !valid;
        const bool missingRequiredResidual = fel && el == _elFrames.end() &&
                                             (_elSpeculative || _requiresMetadata);
        if (missingRequiredMetadata || missingRequiredResidual) {
            // P3/compressed P20.0 need independently valid metadata (and their
            // residual when specified). A speculative FEL cannot expose bare BL.
            consumeBase();
            CVPixelBufferRelease(out.pixelBuffer);
            if (_requiresMetadata) continue;
            return SPDecodedVideoOutputEmpty();
        }
        // Missing/corrupt EL: show the compatible SDR/HDR10 base layer. Never apply a
        // FEL reshape/L1 describing BL+EL to BL alone (brightness would be wrong).
        valid = valid && (!fel || el != _elFrames.end());
        const int mode = valid ? (fel ? 2 : 1) : 0;
        if (mode != _loggedMode) {
            if (spDebug()) NSLog(@"[c%u][DoVi] P%d mode=%s pts=%.6f pairMiB=%.2f",
                _spLogId, _profile, mode == 2 ? "BL+EL+RPU" : mode == 1 ? "BL+RPU" : "base-fallback",
                out.ptsUs / 1e6, (_pendingBaseBytes + _pendingEnhancementBytes) / 1048576.0);
            _loggedMode = mode;
        }
        CVBufferRemoveAttachment(out.pixelBuffer, kSPDoviFrameMetadata);
        CVBufferRemoveAttachment(out.pixelBuffer, kSPDoviEnhancementFrame);
        CVBufferRemoveAttachment(out.pixelBuffer, kSPDoviMissingEnhancement);
        CVBufferRemoveAttachment(out.pixelBuffer, kSPDoviReconstructedFrame);
        CVBufferRemoveAttachment(out.pixelBuffer, kSPDoviPictureMetadata);
        if (fel && !valid)
            CVBufferSetAttachment(out.pixelBuffer, kSPDoviMissingEnhancement, kCFBooleanTrue,
                                  kCVAttachmentMode_ShouldNotPropagate);
        if (valid) {
            CVBufferSetAttachment(out.pixelBuffer, kSPDoviFrameMetadata, data,
                                  kCVAttachmentMode_ShouldNotPropagate);
            if (fel) CVBufferSetAttachment(out.pixelBuffer, kSPDoviEnhancementFrame,
                                          el->second, kCVAttachmentMode_ShouldNotPropagate);
        }
        consumeBase();
        // Decoded outputs are in display order. Drop older EL pictures, including
        // catch-up pictures with no matching BL; retain no surface twice.
        for (auto it = _elFrames.begin(); it != _elFrames.end() && it->first <= out.ptsUs;) {
            _pendingEnhancementBytes -= frameBytes(it->second);
            CVPixelBufferRelease(it->second);
            it = _elFrames.erase(it);
        }
        if (_av1Replay) {
            // Without a presentation timestamp the old/new output frontier cannot
            // be compared. A later handoff must begin at the next key instead.
            if (out.ptsUs == INT64_MIN) _av1Replay->clear();
            else _av1Replay->returnedThrough = std::max(_av1Replay->returnedThrough, out.ptsUs);
        }
        return out;
    }
    return SPDecodedVideoOutputEmpty();
}

- (SPDecodedVideoOutput)decodePacketOutput:(const AVPacket *)packet {
    if (_metadataUnsupported) return SPDecodedVideoOutputEmpty();
    sp::DoviReshape metadata;
    EnhancementPicture enhancementPicture;
    if (packet && packet->size > 0) {
        if (_av1Replay) {
            _av1Replay->remember(packet);
            if (_av1Replay->required) {
                [self activatePictureDecoder];
                return [self takeReady:NO];
            }
        }
        const auto *context = _dualLayer ? sp::doviPacketContext(packet) : nullptr;
        if (context) {
            if (_association && context->association && context->association != _association) {
                // A collision removes its metadata entry, but its old BL can
                // still be reordered inside the decoder at the next PMT.
                _previousAssociationPts = _ambiguousAssociationPts;
                for (const auto& entry : _metadata) _previousAssociationPts.insert(entry.first);
                [self retireEnhancement];
                _elBank = {}; _elSets = {}; _parser->reset();
            }
            if (context->association) _association = context->association;
        }
        _elDrained = false;
        size_t extraSize = 0;
        const uint8_t *extra = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &extraSize);
        if (extra) {
            _nalLengthSize = sp::doviNalLengthSize(_codec, extra, extraSize);
            _parser->reset();
            if (_profile == 10) _parser->setAV1Config(extra,extraSize);
        }
        const auto *paired = sp::doviPacketEnhancement(packet);
        if (paired) {
            size_t size = 0;
            if (av_packet_get_side_data(paired->packet, AV_PKT_DATA_NEW_EXTRADATA, &size))
                _parser->reset();
        }
        const AVPacket *metadataPacket = paired ? paired->packet : packet;
        const int metadataLength = paired ? paired->nalLengthSize : _nalLengthSize;
        if (_profile == 10) {
            const bool fromPicture = [_base isKindOfClass:SPFFmpegDecoder.class] &&
                                     ((SPFFmpegDecoder *)_base).doviPictureMetadataActive;
            if (!fromPicture) {
                const auto parsed = _parser->parseAV1(packet->data, packet->size, metadata);
                if (parsed == sp::DoviParser::Result::NeedsPictureDecoder && _av1Replay) {
                    _av1Replay->required = true;
                    if (![self activatePictureDecoder]) {
                        [_base flush]; [self clearPairs];
                    }
                    return [self takeReady:NO];
                }
            }
        }
        else {
            // One split serves both the RPU parser and EL extraction.
            const bool split = sp::doviSplitNals(metadataPacket->data, metadataPacket->size,
                                                 metadataLength, _nals, _profile == 9);
            if (!split) _parser->reset();
            const auto parsed = split ? _parser->parse(_nals, metadata) : sp::DoviParser::Result::Invalid;
            if (_rejectUnsupportedRPU && parsed == sp::DoviParser::Result::Unsupported) {
                _metadataUnsupported = true;
                [self clearPairs];
                return SPDecodedVideoOutputEmpty();
            }
        }
        if (packet->pts != AV_NOPTS_VALUE)
            [self recordMetadata:metadata ptsUs:av_rescale_q(packet->pts, _tb, AV_TIME_BASE_Q)];
        if (_dualLayer)
            enhancementPicture = [self prepareEnhancementPacket:metadataPacket separate:paired != nullptr];
        // The race decodes BL first: its EL prefers VideoToolbox like the
        // formal path (identical acceptance of damaged slices; software HEVC
        // conceals a truncated slice without any error flag), and that session
        // waits behind the BL session's first-create latch. Decoding the BL
        // meanwhile keeps the race ahead of the formal first frame.
        if (!_elSpeculative)
            [self feedEnhancementFor:packet metadata:metadata picture:enhancementPicture];
    } else if (!packet && _enhancement && !_elDrained) {
        // EL and BL can have different reorder depths. Collect the delayed EL
        // outputs before deciding whether the earliest waiting BL is missing it.
        [self drainEnhancement];
        _elDrained = true;
    }
    // The BL decoders accept the original AU (including NAL 62/63). Preserve
    // packet identity/side data and avoid a full BL assembly + packet copy.
    if (_av1Replay && _av1Replay->required) return SPDecodedVideoOutputEmpty();
    [self storeBase:[_base decodePacketOutput:packet]];
    if (_elSpeculative && packet && packet->size > 0)
        [self feedEnhancementFor:packet metadata:metadata picture:enhancementPicture];
    auto ready = [self takeReady:packet == nullptr];
    if (!packet && _requiresMetadata) {
        // A discarded tail picture is not EOF: the BL reorder buffer may
        // still contain independently mapped pictures. Keep the drain bounded.
        for (int i = 0; !ready.pixelBuffer && i < 64; ++i) {
            const auto next = [_base decodePacketOutput:nullptr];
            if (!next.pixelBuffer) break;
            [self storeBase:next];
            ready = [self takeReady:YES];
        }
    }
    return ready;
}

// The packet's RPU verdict for its picture, matched to BL output by PTS.
- (void)recordMetadata:(const sp::DoviReshape&)metadata ptsUs:(int64_t)pts {
    _metadata.erase(pts); // a repeated PTS with absent/invalid RPU clears it
    // Even an old picture without RPU must not receive a later
    // association's metadata while it is still reordered in BL.
    if (_dualLayer) _metadata.emplace(pts, MetadataBytes{});
    // Reused timestamps across a PMT cannot identify which of the
    // BL decoder's reordered pictures is old. Both use compatible BL.
    const bool ambiguous = _previousAssociationPts.count(pts);
    if (ambiguous && !_ambiguousAssociationPts.count(pts)) {
        // Retain collision tombstones until seek, with bounded memory.
        // Pathological repeated timeline resets use BL until flush.
        if (_ambiguousAssociationPts.size() < 256) _ambiguousAssociationPts.insert(pts);
        else _associationMetadataOverflow = true;
    }
    if (metadata.valid && !ambiguous && !_associationMetadataOverflow) {
        SPDoviUniforms gpu;
        sp::doviToGpuFloats(metadata, gpu.values);
        _lastMetadata.update(gpu);
        if (_lastMetadata) _metadata[pts] = _lastMetadata;
    }
    while (_metadata.size() > 256) _metadata.erase(_metadata.begin());
}

- (void)feedEnhancementFor:(const AVPacket *)packet metadata:(const sp::DoviReshape&)metadata
                  picture:(EnhancementPicture)picture {
    if (picture.hasVcl && picture.key && metadata.needsEnhancement && !_enhancement) {
        _enhancement = makeEnhancementDecoder(_videoDelay, _tb, _elSets,
            _elBytes, _spLogId, _elPreferSoftware, _elSpeculative || _previewMode,
            _previewWidth, _previewHeight, enhancementBitDepth(_profile));
        _elErrorStreak = 0;
        [_enhancement setCatchUpTargetUs:_catchUp];
        // Pictures fed to BL before this RAP never reach the new EL. Holding
        // them until a later EL output would keep that backlog until seek.
        const int64_t current = packet->pts != AV_NOPTS_VALUE
            ? av_rescale_q(packet->pts, _tb, AV_TIME_BASE_Q) : INT64_MIN;
        _elUnreachablePts.clear();
        for (const auto& entry : _metadata)
            if (entry.first != current) _elUnreachablePts.insert(entry.first);
    }
    if (!_enhancement || _elBytes.empty() ||
        av_new_packet(_elPacket, (int)_elBytes.size()) != 0) return;
    memcpy(_elPacket->data, _elBytes.data(), _elBytes.size());
    // BL NEW_EXTRADATA side data must not be copied to the EL decoder.
    _elPacket->pts = packet->pts; _elPacket->dts = packet->dts;
    _elPacket->duration = packet->duration; _elPacket->flags = packet->flags;
    [self storeEnhancement:[_enhancement decodePacketOutput:_elPacket]];
    const int error = _enhancement.lastError;
    if (!error) _elErrorStreak = 0;
    else if (error != kVTVideoDecoderReferenceMissingErr) ++_elErrorStreak;
    if (error == kVTInvalidSessionErr || error == kVTVideoDecoderMalfunctionErr ||
        _elErrorStreak >= 8) {
        _elPreferSoftware = true;
        [self closeEnhancement];
        // Keep already decoded pictures: a later decode failure cannot
        // invalidate an earlier, correctly paired BL/EL output.
    } else if (error && spDebug()) {
        // A CRA seek can encounter leading RASL pictures whose refs
        // precede the seek. Drop only that output and let the same
        // session decode subsequent pictures from the valid CRA.
        NSLog(@"[c%u][DoVi] enhancement picture unavailable err=%d", _spLogId,error);
    }
    av_packet_unref(_elPacket);
}
@end

SPDoviEnhancementPreparation *SPPrepareDoviEnhancement(const AVCodecParameters *par,
    const AVPacket *packet, int64_t n, int64_t d, unsigned logId) {
    const auto *cfg = doviConfig(par);
    if (!sp::doviHEVCDualLayerSupported(par) || !packet || packet->size <= 0) return nil;
    const CFAbsoluteTime start = spDebug() ? CFAbsoluteTimeGetCurrent() : 0;
    int ls = sp::doviNalLengthSize(par);
    size_t extraSize = 0;
    if (const auto *extra = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &extraSize))
        ls = sp::doviNalLengthSize(AV_CODEC_ID_HEVC, extra, extraSize);
    const auto *paired = sp::doviPacketEnhancement(packet);
    if (paired) { packet = paired->packet; ls = paired->nalLengthSize; }
    sp::DoviParser parser(cfg->dv_profile, cfg->dv_bl_signal_compatibility_id, cfg->dv_md_compression);
    sp::DoviReshape metadata;
    std::vector<sp::DoviNal> nals;
    if (!sp::doviSplitNals(packet->data, packet->size, ls, nals) ||
        parser.parse(nals, metadata) != sp::DoviParser::Result::Valid ||
        !metadata.needsEnhancement) return nil;
    auto *prepared = [SPDoviEnhancementPreparation new];
    sp::doviReadEnhancementConfig(par, prepared->bank);
    // An invalid update clears the inherited bank. Like formal decoding,
    // preparation can still recover from complete in-band sets on this RAP.
    if (paired) applyEnhancementPacketConfig(packet, prepared->bank);
    std::vector<uint8_t> bytes;
    bool vcl = false, key = false;
    if (!extractEnhancement(nals, prepared->bank, prepared->sets, bytes, vcl, key, paired != nullptr)) return nil;
    if (!vcl || !key) return nil;
    prepared->decoder = makeEnhancementDecoder(par->video_delay, {(int)n,(int)d},
                                               prepared->sets, bytes, logId, false, false,
                                               0, 0, enhancementBitDepth(cfg->dv_profile));
    if (spDebug()) NSLog(@"[c%u][DoVi] EL prepare %.3fms ready=%d", logId,
        (CFAbsoluteTimeGetCurrent() - start) * 1000, prepared->decoder != nil);
    return prepared->decoder ? prepared : nil;
}

static id<SPVideoDecoding> wrapDovi(id<SPVideoDecoding> base, const AVCodecParameters *par,
    int64_t n, int64_t d, SPDoviEnhancementPreparation *prepared, BOOL speculative) {
    const auto *config = doviConfig(par);
    if (!base || !config) return base;
    if (!sp::doviMappingSupported(par)) return config->dv_profile == 3 ? nil : base;
    const auto cfg = *config;
    return [[SPDoviDecoder alloc] initWithBase:base parameters:par
        tb:AVRational{(int)n,(int)d} config:cfg prepared:prepared speculative:speculative] ?:
        (cfg.dv_profile == 3 ? nil : base);
}

id<SPVideoDecoding> SPWrapDoviDecoder(id<SPVideoDecoding> base,
    const AVCodecParameters *par, int64_t n, int64_t d, SPDoviEnhancementPreparation *prepared) {
    return wrapDovi(base, par, n, d, prepared, NO);
}

bool SPConsumeDoviDecoderChange(id<SPVideoDecoding> decoder) {
    if (![decoder isKindOfClass:SPDoviDecoder.class]) return false;
    auto *dovi = (SPDoviDecoder *)decoder;
    const bool changed = dovi.backendChanged;
    dovi.backendChanged = NO;
    return changed;
}

id<SPVideoDecoding> SPWrapDoviSpeculativeDecoder(id<SPVideoDecoding> base,
    const AVCodecParameters *par, int64_t n, int64_t d) {
    return wrapDovi(base, par, n, d, nil, YES);
}

id<SPVideoDecoding> SPWrapDoviThumbnailDecoder(id<SPVideoDecoding> base,
    const AVCodecParameters *par, int64_t n, int64_t d, int width, int height) {
    if (sp::doviRequiresUnsupportedMetadata(par)) return nil;
    if (!sp::doviHEVCDualLayerSupported(par) || width < 0 || height < 0) {
        const auto *cfg = doviConfig(par);
        return cfg && cfg->dv_profile == 3 ? nil : base;
    }
    id<SPVideoDecoding> result = wrapDovi(base, par, n, d, nil, NO);
    if (result && result != base) {
        ((SPDoviDecoder *)result).previewWidth = width;
        ((SPDoviDecoder *)result).previewHeight = height;
        ((SPDoviDecoder *)result).previewMode = YES;
    }
    return result;
}
