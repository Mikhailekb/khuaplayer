// Independent windowed reading of embedded text subtitles.
#import "SPCaptionSubtitleReader.h"
#include <unistd.h>
#include "SPRuntimeGates.hpp"
#include "HTTPRangeIO.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <string>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/stat.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

@implementation SPCaptionSubtitleCue
@end

@interface SPCaptionSubtitleReader ()
- (BOOL)interrupted;
- (BOOL)permanentlyAborted;
- (BOOL)readAdmitted;
- (int)ioRead:(uint8_t *)buf size:(int)size;
- (int64_t)ioSeek:(int64_t)offset whence:(int)whence;
@end

@implementation SPCaptionSubtitleReader {
    NSString *_path;
    int _wantStream;
    std::atomic<bool> _abort;
    std::mutex _mtx;
    BOOL (^_pauseBlock)(void); // True pauses at read boundaries.
    AVFormatContext *_ctx;
    AVPacket *_pkt;
    int _stream;
    AVRational _tb;
    int64_t _originUs;
    enum AVCodecID _codec;
    bool _openFailed;
    bool _ioPolicyApplied;
    NSError *_openError;
    int _fd;
    std::unique_ptr<sp::HTTPRangeIO> _http;
    int64_t _fileSize;
    int64_t _ioPos;
    int64_t _fdPos;
    int _ioGranule;
    bool _cursorValid;
    bool _cursorEOF;
    double _cursorEnd;
    bool _hasLookahead;
    double _lookaheadStart;
    SPCaptionSubtitleCue *_lookaheadCue;
    double _lastStart;
    double _lastDuration;
    NSArray<SPCaptionSubtitleCue *> *_lastCues;
}

#define SPLOG(fmt, ...) NSLog(@"[c%u]" fmt, self->_spLogId, ##__VA_ARGS__)

// Match the demuxer timeline origin: signed container start, earliest declared
// stream start, or zero when no timestamp is available.
static int64_t spCapSubTimelineOrigin(AVFormatContext *c) {
    if (c->start_time != AV_NOPTS_VALUE) return c->start_time;
    int64_t mn = INT64_MAX;
    for (unsigned i = 0; i < c->nb_streams; ++i) {
        AVStream *s = c->streams[i];
        if (s->start_time == AV_NOPTS_VALUE) continue;
        int64_t us = av_rescale_q(s->start_time, s->time_base, AV_TIME_BASE_Q);
        if (us < mn) mn = us;
    }
    return mn != INT64_MAX ? mn : 0;
}

static int spCapSubInterruptCb(void *opaque) {
    SPCaptionSubtitleReader *r = (__bridge SPCaptionSubtitleReader *)opaque;
    return [r interrupted] ? 1 : 0;
}
static int spCapSubRead(void *opaque, uint8_t *buf, int size) {
    return [(__bridge SPCaptionSubtitleReader *)opaque ioRead:buf size:size];
}
static int64_t spCapSubSeek(void *opaque, int64_t offset, int whence) {
    return [(__bridge SPCaptionSubtitleReader *)opaque ioSeek:offset whence:whence];
}

- (instancetype)initWithPath:(NSString *)path subtitleStreamIndex:(int)streamIndex {
    self = [super init];
    if (self) {
        _path = [path copy];
        _wantStream = streamIndex;
        _abort.store(false);
        _ctx = nullptr; _pkt = nullptr; _stream = -1; _tb = {1, 1}; _originUs = 0;
        _timelineOriginUs = INT64_MIN; // Unset: derive the timeline origin.
        _expectedSourceLength = -1;
        _codec = AV_CODEC_ID_NONE; _openFailed = false; _ioPolicyApplied = false;
        _fd = -1;
    }
    return self;
}

- (void)dealloc {
    [self teardown];
}

- (void)teardown {
    if (_pkt) av_packet_free(&_pkt);
    if (_ctx && _ctx->pb) {
        AVIOContext *pb = _ctx->pb; _ctx->pb = nullptr;
        av_freep(&pb->buffer); avio_context_free(&pb);
    }
    if (_ctx) avformat_close_input(&_ctx);
    if (_fd >= 0) { ::close(_fd); _fd = -1; }
    _http.reset();
}

- (void)abort { _abort.store(true); }
- (BOOL)permanentlyAborted { return _abort.load(); }
- (BOOL)readAdmitted {
    return !_abort.load() && (!_pauseBlock || !_pauseBlock());
}

- (BOOL)open { return [self openWithShouldPause:nil]; }

- (BOOL)openWithShouldPause:(BOOL (^)(void))shouldPause {
    std::lock_guard<std::mutex> lk(_mtx);
    _lastError = nil;
    _pauseBlock = shouldPause;
    BOOL result = [self ensureOpen];
    _pauseBlock = nil;
    return result;
}

- (void)recordError:(int)code {
    if (_abort.load()) return;
    char detail[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(code, detail, sizeof(detail));
    _lastError = [NSError errorWithDomain:@"SPCaptionSubtitleReader" code:code
                                userInfo:@{NSLocalizedDescriptionKey: @(detail)}];
}

- (void)recordOpenError:(int)code {
    [self recordError:code];
    if (!_abort.load()) { _openFailed = true; _openError = _lastError; }
}

// Pause in place at open and custom AVIO block reads. Interleaved subtitle
// streams still traverse video bytes and must yield like the audio reader.
- (BOOL)interrupted {
    while (!_abort.load() && _pauseBlock && _pauseBlock()) usleep(100 * 1000);
    return _abort.load();
}

// Protocol interrupts alone do not guarantee a check before every local read.
// Custom AVIO checks before each local or remote block, including open and probing.
- (int)ioRead:(uint8_t *)buf size:(int)size {
    if ([self interrupted]) return AVERROR_EXIT;
    if (_http) {
        int n = _http->read(buf, MIN(size, _ioGranule));
        if (n > 0) _ioPos += n;
        return n;
    }
    if (_fd < 0) return AVERROR(EIO);
    size = MIN(size, _ioGranule);
    if (_fdPos != _ioPos) {
        if (lseek(_fd, _ioPos, SEEK_SET) < 0) return AVERROR(errno);
        _fdPos = _ioPos;
    }
    ssize_t n;
    do { n = read(_fd, buf, (size_t)size); } while (n < 0 && errno == EINTR && ![self interrupted]);
    if (n < 0) return AVERROR(errno);
    if (n == 0) return _ioPos < _fileSize ? AVERROR(EIO) : AVERROR_EOF;
    _ioPos += n; _fdPos += n;
    return (int)n;
}

- (int64_t)ioSeek:(int64_t)offset whence:(int)whence {
    if ([self interrupted]) return AVERROR_EXIT;
    if (whence == AVSEEK_SIZE) return _fileSize;
    if (_http) {
        int64_t position = _http->seek(offset, whence);
        if (position >= 0) _ioPos = position;
        return position;
    }
    int64_t base;
    switch (whence & ~AVSEEK_FORCE) {
        case SEEK_SET: base = 0; break;
        case SEEK_CUR: base = _ioPos; break;
        case SEEK_END: base = _fileSize; break;
        default: return AVERROR(EINVAL);
    }
    if ((offset > 0 && base > INT64_MAX - offset) || (offset < 0 && offset < -base)) return AVERROR(EINVAL);
    _ioPos = base + offset;
    return _ioPos;
}

- (BOOL)ensureOpen {
    if ([self interrupted]) return NO;
    if (_ctx) return YES;
    if (_openFailed) { _lastError = _openError; return NO; }
    if (!_ioPolicyApplied) {
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE);
        _ioPolicyApplied = true;
    }
    bool remote = false;
    if (sp::HTTPRangeIO::supportsURL(_path.UTF8String ?: "")) {
        __weak SPCaptionSubtitleReader *weakReader = self;
        _http = std::make_unique<sp::HTTPRangeIO>(_path.UTF8String ?: "", [weakReader] {
            SPCaptionSubtitleReader *reader = weakReader;
            return !reader || [reader permanentlyAborted];
        });
        // Subtitle samples can contain only a handful of bytes. A small local
        // range avoids fetching256KiB of unrelated movie data per sparse cue.
        _http->setReadBlockSize(32 * 1024);
        _http->setReadAdmission([weakReader] {
            SPCaptionSubtitleReader *reader = weakReader;
            return reader && [reader readAdmitted];
        });
        int result = _http->open();
        if (result < 0) { [self recordOpenError:result]; [self teardown]; return NO; }
        _fileSize = _http->size(); _ioPos = 0; _fdPos = -1;
    } else {
        _fd = ::open(_path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        if (_fd < 0) { [self recordOpenError:AVERROR(errno)]; return NO; }
        struct stat sb {};
        if ([self interrupted]) { [self teardown]; return NO; }
        if (fstat(_fd, &sb) != 0) {
            [self recordOpenError:AVERROR(errno)]; [self teardown]; return NO;
        }
        _fileSize = sb.st_size; _ioPos = 0; _fdPos = 0;
        struct statfs sfs {};
        if ([self interrupted]) { [self teardown]; return NO; }
        remote = fstatfs(_fd, &sfs) == 0 &&
            (!strcmp(sfs.f_fstypename, "smbfs") || !strcmp(sfs.f_fstypename, "afpfs") ||
             !strcmp(sfs.f_fstypename, "nfs") || !strcmp(sfs.f_fstypename, "webdav"));
    }
    if (_expectedSourceLength >= 0 && _fileSize != _expectedSourceLength) {
        [self recordOpenError:AVERROR_INVALIDDATA]; [self teardown]; return NO;
    }
    const int granule = remote ? (1 << 20) : (256 << 10);
    _ioGranule = granule;
    uint8_t *iobuf = (uint8_t *)av_malloc(granule);
    AVIOContext *pb = iobuf ? avio_alloc_context(iobuf, granule, 0, (__bridge void *)self,
                                                spCapSubRead, nullptr, spCapSubSeek) : nullptr;
    if (!pb) {
        av_free(iobuf); [self recordOpenError:AVERROR(ENOMEM)]; [self teardown]; return NO;
    }
    AVFormatContext *c = avformat_alloc_context();
    if (!c) {
        av_freep(&pb->buffer); avio_context_free(&pb);
        [self recordOpenError:AVERROR(ENOMEM)]; [self teardown]; return NO;
    }
    c->pb = pb; c->flags |= AVFMT_FLAG_CUSTOM_IO;
    c->interrupt_callback = { spCapSubInterruptCb, (__bridge void *)self };
    AVDictionary *opts = nullptr;
    av_dict_set(&opts, "scan_all_pmts", "0", 0);
    int ret = avformat_open_input(&c, _path.fileSystemRepresentation, nullptr, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        av_freep(&pb->buffer); avio_context_free(&pb);
        [self recordOpenError:ret]; [self teardown]; return NO;
    }
    _ctx = c;
    if (pb->error < 0 && pb->error != AVERROR_EOF) {
        [self recordOpenError:pb->error]; [self teardown]; return NO;
    }
    if (_wantStream < 0 || (unsigned)_wantStream >= c->nb_streams ||
        c->streams[_wantStream]->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) {
        [self recordOpenError:AVERROR_STREAM_NOT_FOUND]; [self teardown];
        return NO;
    }
    for (unsigned i = 0; i < c->nb_streams; ++i) {
        if ((int)i != _wantStream) c->streams[i]->discard = AVDISCARD_ALL;
    }
    _ctx = c;
    _stream = _wantStream;
    _tb = c->streams[_stream]->time_base;
    _codec = c->streams[_stream]->codecpar->codec_id;
    _originUs = _timelineOriginUs != INT64_MIN ? _timelineOriginUs : spCapSubTimelineOrigin(c);
    _pkt = av_packet_alloc();
    if (!_pkt) { [self recordOpenError:AVERROR(ENOMEM)]; [self teardown]; return NO; }
    // The freshly opened demuxer already starts at the beginning; a linear job
    // does not need an initial seek/index scan before consuming its first packet.
    _cursorValid = true; _cursorEnd = 0;
    return YES;
}

// Convert Matroska ASS payload fields to plain text. SRT and WebVTT use
// packet text directly; mov_text first removes its two-byte length prefix.
static NSString *spCapSubPlainText(enum AVCodecID codec, const uint8_t *data, int size) {
    if (size <= 0) return nil;
    if (codec == AV_CODEC_ID_MOV_TEXT) {
        if (size < 2) return nil;
        int tlen = (data[0] << 8) | data[1];
        data += 2; size -= 2;
        if (tlen < size) size = tlen;
        if (size <= 0) return nil;
    }
    // Stop at the first trailing NUL so punctuation detection and translation
    // cache keys receive only subtitle text.
    int realLen = 0;
    while (realLen < size && data[realLen] != 0) realLen++;
    if (realLen <= 0) return nil;
    NSString *s = [[NSString alloc] initWithBytes:data length:(NSUInteger)realLen encoding:NSUTF8StringEncoding];
    if (!s) return nil;
    if (codec == AV_CODEC_ID_ASS || codec == AV_CODEC_ID_SSA) {
        // ASS text begins after the ninth comma.
        NSUInteger commas = 0, i = 0;
        for (; i < s.length && commas < 8; ++i) if ([s characterAtIndex:i] == ',') commas++;
        if (commas < 8) return nil;
        s = [s substringFromIndex:i];
    }
    // Remove ASS and HTML tags, then expand escaped line breaks.
    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"\\N" withString:@"\n" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\\n" withString:@"\n" options:0 range:NSMakeRange(0, m.length)];
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"\\{[^}]*\\}|<[^>]+>" options:0 error:nil];
    [tags replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@""];
    NSString *trimmed = [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : nil;
}

static NSString *spWholeSubtitleTime(int64_t us, bool ass, bool roundUp) {
    const int64_t quantum = ass ? 10000 : 1000;
    int64_t ticks = us / quantum;
    if (roundUp && us % quantum) ++ticks;
    const int64_t rate = ass ? 100 : 1000;
    const int64_t seconds = ticks / rate;
    return ass
        ? [NSString stringWithFormat:@"%lld:%02lld:%02lld.%02lld",
           seconds / 3600, (seconds / 60) % 60, seconds % 60, ticks % rate]
        : [NSString stringWithFormat:@"%02lld:%02lld:%02lld,%03lld",
           seconds / 3600, (seconds / 60) % 60, seconds % 60, ticks % rate];
}

// Unlike the translation reader, persistent playback keeps text formatting.
// This matches the main player's MOV_TEXT prefix handling; styling boxes that
// the existing renderer does not interpret remain outside the displayed text.
static bool spWholeSubtitleText(enum AVCodecID codec, const AVPacket *packet, NSString **out) {
    *out = nil;
    const uint8_t *data = packet->data;
    int size = packet->size;
    if (size < 0 || size > 1024 * 1024 || (size > 0 && !data)) return false;
    if (codec == AV_CODEC_ID_MOV_TEXT) {
        if (size < 2) return false;
        const int declared = (data[0] << 8) | data[1];
        data += 2; size -= 2;
        if (declared > size) return false;
        size = declared;
    }
    if (size == 0) return true;
    while (size > 0 && data[size - 1] == 0) --size;
    if (size == 0) return true;
    NSString *text = [[NSString alloc] initWithBytes:data length:(NSUInteger)size encoding:NSUTF8StringEncoding];
    if (!text || [text rangeOfString:@"\0"].location != NSNotFound) return false;
    *out = text;
    return true;
}

- (nullable NSString *)exportWholeTrackWithShouldPause:(nullable BOOL (^)(void))shouldPause {
    std::lock_guard<std::mutex> lock(_mtx);
    _lastError = nil;
    _pauseBlock = shouldPause;
    auto finish = [&](NSString *text) -> NSString * {
        _pauseBlock = nil;
        return text;
    };
    auto fail = [&](int code) -> NSString * {
        _cursorValid = false;
        [self recordError:code];
        return finish(nil);
    };
    if (![self ensureOpen]) return finish(nil);
    const bool indexedMov = _ctx->iformat && _ctx->iformat->name &&
        (strstr(_ctx->iformat->name, "mov") || strstr(_ctx->iformat->name, "mp4"));
    // A generic network MKV/TS traversal can require the entire video payload.
    // Keep those inputs on the auxiliary rolling-cache fallback.
    if (_http && !indexedMov) return fail(AVERROR(ENOSYS));
    const bool ass = _codec == AV_CODEC_ID_ASS || _codec == AV_CODEC_ID_SSA;
    if (!ass && _codec != AV_CODEC_ID_SUBRIP && _codec != AV_CODEC_ID_MOV_TEXT &&
        _codec != AV_CODEC_ID_WEBVTT) return fail(AVERROR(ENOSYS));
    if (_tb.num <= 0 || _tb.den <= 0) return fail(AVERROR_INVALIDDATA);
    if (!_cursorValid || _cursorEnd != 0 || _hasLookahead) {
        AVStream *stream = _ctx->streams[_stream];
        const int64_t beginning = stream->start_time != AV_NOPTS_VALUE ? stream->start_time : 0;
        if (av_seek_frame(_ctx, _stream, beginning, AVSEEK_FLAG_BACKWARD) < 0)
            return fail(AVERROR(EIO));
    }
    constexpr NSUInteger outputCap = 8 * 1024 * 1024;
    constexpr NSUInteger eventCap = 100000;
    constexpr NSUInteger packetCap = 1000000;
    NSMutableString *output = [NSMutableString string];
    NSUInteger bytes = 0, events = 0, packets = 0;
    if (ass) {
        AVCodecParameters *parameters = _ctx->streams[_stream]->codecpar;
        if (parameters->extradata_size <= 0 || parameters->extradata_size > 1024 * 1024)
            return fail(AVERROR_INVALIDDATA);
        NSString *header = [[NSString alloc] initWithBytes:parameters->extradata
            length:(NSUInteger)parameters->extradata_size encoding:NSUTF8StringEncoding];
        if (!header) return fail(AVERROR_INVALIDDATA);
        // Codec private data may carry terminating C NULs. Interior NULs are
        // malformed; silently dropping them could change the authored script.
        while (header.length && [header characterAtIndex:header.length - 1] == 0)
            header = [header substringToIndex:header.length - 1];
        if ([header rangeOfString:@"\0"].location != NSNotFound) return fail(AVERROR_INVALIDDATA);
        [output appendString:header];
        if (![header hasSuffix:@"\n"]) [output appendString:@"\n"];
        if ([header rangeOfString:@"[Events]" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            [output appendString:@"[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"];
        }
        bytes = [output lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    }
    for (;;) {
        @autoreleasepool {
            if ([self interrupted]) return finish(nil);
            const int result = av_read_frame(_ctx, _pkt);
            const int ioError = _ctx->pb ? _ctx->pb->error : 0;
            if (ioError < 0 && ioError != AVERROR_EOF) {
                av_packet_unref(_pkt);
                return fail(ioError);
            }
            if (result == AVERROR_EOF) {
                av_packet_unref(_pkt);
                _cursorEOF = true; _cursorValid = false;
                // An empty complete track is intentionally different from a
                // failed extraction, even if its ASS header contained styles.
                return finish(events ? [output copy] : @"");
            }
            if (result < 0) { av_packet_unref(_pkt); return fail(result); }
            if (++packets > packetCap) { av_packet_unref(_pkt); return fail(AVERROR(EFBIG)); }
            if (_pkt->stream_index != _stream) { av_packet_unref(_pkt); continue; }
            NSString *text = nil;
            if ((_pkt->flags & AV_PKT_FLAG_CORRUPT) || !spWholeSubtitleText(_codec, _pkt, &text)) {
                av_packet_unref(_pkt); return fail(AVERROR_INVALIDDATA);
            }
            if (!ass && text.length) {
                // Match the streaming renderer's whitespace/blank-line rules,
                // and keep a blank paragraph from terminating an SRT cue early.
                NSMutableArray<NSString *> *lines = [NSMutableArray array];
                NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
                for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
                    NSString *trimmed = [line stringByTrimmingCharactersInSet:whitespace];
                    if (trimmed.length) [lines addObject:trimmed];
                }
                text = [lines componentsJoinedByString:@"\n"];
            }
            if (!text.length) { av_packet_unref(_pkt); continue; }
            const int64_t timestamp = _pkt->pts != AV_NOPTS_VALUE ? _pkt->pts : _pkt->dts;
            if (timestamp == AV_NOPTS_VALUE) { av_packet_unref(_pkt); return fail(AVERROR_INVALIDDATA); }
            const int64_t absoluteUs = av_rescale_q(timestamp, _tb, AV_TIME_BASE_Q);
            const int64_t durationUs = _pkt->duration > 0
                ? av_rescale_q(_pkt->duration, _tb, AV_TIME_BASE_Q) : 0;
            const __int128 startWide = (__int128)absoluteUs - _originUs;
            const __int128 endWide = startWide + durationUs;
            if (durationUs <= 0 || startWide < INT64_MIN || startWide > INT64_MAX || endWide > INT64_MAX) {
                av_packet_unref(_pkt); return fail(AVERROR_INVALIDDATA);
            }
            if (endWide <= 0) { av_packet_unref(_pkt); continue; }
            const int64_t startUs = std::max<int64_t>(0, (int64_t)startWide);
            const int64_t endUs = (int64_t)endWide;
            NSString *entry = nil;
            if (ass) {
                // Matroska ASS chunks: ReadOrder,Layer,Style,Name,MarginL,
                // MarginR,MarginV,Effect,Text. The file owns Start/End columns.
                NSUInteger cursor = 0;
                NSRange first = NSMakeRange(NSNotFound, 0), layer = first;
                bool valid = true;
                for (int column = 0; column < 8; ++column) {
                    NSRange comma = [text rangeOfString:@"," options:0
                        range:NSMakeRange(cursor, text.length - cursor)];
                    if (comma.location == NSNotFound) { valid = false; break; }
                    if (column == 0) first = comma;
                    if (column == 1) layer = comma;
                    cursor = comma.location + 1;
                }
                if (!valid) { av_packet_unref(_pkt); return fail(AVERROR_INVALIDDATA); }
                NSString *layerValue = [text substringWithRange:
                    NSMakeRange(first.location + 1, layer.location - first.location - 1)];
                NSString *tail = [text substringFromIndex:layer.location + 1];
                entry = [NSString stringWithFormat:@"Dialogue: %@,%@,%@,%@\n", layerValue,
                    spWholeSubtitleTime(startUs, true, false), spWholeSubtitleTime(endUs, true, true), tail];
            } else {
                // SRT parsing retains the same inline HTML styling already
                // handled by SPSubtitleInlineTagsToASS in the renderer.
                entry = [NSString stringWithFormat:@"%lu\n%@ --> %@\n%@\n\n",
                    (unsigned long)(events + 1), spWholeSubtitleTime(startUs, false, false),
                    spWholeSubtitleTime(endUs, false, true), text];
            }
            av_packet_unref(_pkt);
            const NSUInteger entryBytes = [entry lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (++events > eventCap || entryBytes > outputCap || bytes > outputCap - entryBytes)
                return fail(AVERROR(EFBIG));
            bytes += entryBytes;
            [output appendString:entry];
        }
    }
}

- (nullable NSArray<SPCaptionSubtitleCue *> *)readCuesFromSeconds:(double)start
                                                  durationSeconds:(double)duration {
    return [self readCuesFromSeconds:start durationSeconds:duration shouldPause:nil];
}

- (nullable NSArray<SPCaptionSubtitleCue *> *)readCuesFromSeconds:(double)start
                                                  durationSeconds:(double)duration
                                                      shouldPause:(nullable BOOL (^)(void))shouldPause {
    std::lock_guard<std::mutex> lk(_mtx);
    _lastError = nil;
    if (!std::isfinite(start) || !std::isfinite(duration) || start < 0 || duration <= 0 ||
        start > (double)(INT64_MAX / AV_TIME_BASE) - duration) {
        [self recordError:AVERROR(EINVAL)]; return nil;
    }
    _pauseBlock = shouldPause;
    NSArray<SPCaptionSubtitleCue *> *out = [self ensureOpen]
        ? [self readCuesLockedFromSeconds:start durationSeconds:duration] : nil;
    _pauseBlock = nil;
    return out;
}

- (nullable NSArray<SPCaptionSubtitleCue *> *)readCuesLockedFromSeconds:(double)start
                                                        durationSeconds:(double)duration {
    NSMutableArray<SPCaptionSubtitleCue *> *out = [NSMutableArray array];
    const double endSec = start + duration;
    int demuxErrors = 0;
    // Retain just the last window and one lookahead cue: empty windows do not seek
    // back across the same high-bitrate packets, and an exact retry is idempotent.
    if (_lastCues && start == _lastStart && duration == _lastDuration) return _lastCues;
    bool sequential = _cursorValid && start == _cursorEnd;
    if (!sequential) {
        _cursorValid = false; _cursorEOF = false; _hasLookahead = false;
        _lookaheadCue = nil; _lastCues = nil;
        const int64_t seekUs = (int64_t)(MAX(0.0, start - 5.0) * AV_TIME_BASE) + _originUs;
        int ret = avformat_seek_file(_ctx, -1, INT64_MIN, seekUs, seekUs, 0);
        if (ret < 0) ret = av_seek_frame(_ctx, -1, seekUs, AVSEEK_FLAG_BACKWARD);
        if (ret < 0) { [self recordError:ret]; return nil; }
    }
    if (_hasLookahead && _lookaheadStart < endSec) {
        if (_lookaheadStart >= start && _lookaheadCue) [out addObject:_lookaheadCue];
        _hasLookahead = false; _lookaheadCue = nil;
    }
    while (!_cursorEOF && !_hasLookahead) {
        if ([self interrupted]) { _cursorValid = false; return nil; }
        int r = av_read_frame(_ctx, _pkt);
        int ioError = _ctx->pb ? _ctx->pb->error : 0;
        if (ioError < 0 && ioError != AVERROR_EOF) {
            av_packet_unref(_pkt); _cursorValid = false; [self recordError:ioError]; return nil;
        }
        if (r < 0) {
            av_packet_unref(_pkt);
            if (r == AVERROR_INVALIDDATA && ++demuxErrors < 256) continue;
            if (r != AVERROR_EOF) { _cursorValid = false; [self recordError:r]; return nil; }
            _cursorEOF = true; break;
        }
        demuxErrors = 0;
        if (_pkt->stream_index != _stream) { av_packet_unref(_pkt); continue; }
        bool corrupt = (_pkt->flags & AV_PKT_FLAG_CORRUPT) != 0;
        int64_t pts = _pkt->pts != AV_NOPTS_VALUE ? _pkt->pts : _pkt->dts;
        if (pts == AV_NOPTS_VALUE) { av_packet_unref(_pkt); continue; }
        double s = (double)(av_rescale_q(pts, _tb, AV_TIME_BASE_Q) - _originUs) / 1e6;
        double d = _pkt->duration > 0 ? (double)av_rescale_q(_pkt->duration, _tb, AV_TIME_BASE_Q) / 1e6 : 2.0;
        if (s >= start) {
            NSString *text = corrupt ? nil : spCapSubPlainText(_codec, _pkt->data, _pkt->size);
            SPCaptionSubtitleCue *c = nil;
            if (text) {
                c = [SPCaptionSubtitleCue new];
                c.start = s;
                c.end = s + d;
                c.text = text;
            }
            if (s >= endSec) {
                _hasLookahead = true; _lookaheadStart = s; _lookaheadCue = c;
            } else if (c) [out addObject:c];
        }
        av_packet_unref(_pkt);
    }
    [out sortUsingComparator:^NSComparisonResult(SPCaptionSubtitleCue *a, SPCaptionSubtitleCue *b) {
        return a.start < b.start ? NSOrderedAscending : (a.start > b.start ? NSOrderedDescending : NSOrderedSame);
    }];
    if (_abort.load()) { _cursorValid = false; return nil; }
    // Sparse subtitles may have just one cue in a window. Losing that cue
    // must not fail the whole translation or force a rewind of the demuxer.
    _cursorValid = true; _cursorEnd = endSec;
    _lastStart = start; _lastDuration = duration; _lastCues = [out copy];
    return _lastCues;
}

@end
