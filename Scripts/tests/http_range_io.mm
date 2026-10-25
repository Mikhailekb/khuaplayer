#import <Foundation/Foundation.h>

#include "HTTPRangeIO.hpp"

extern "C" {
#include <libavformat/avio.h>
#include <libavutil/error.h>
}

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr int64_t fixtureSize = 2 * 1024 * 1024 + 17;
constexpr int maximumRead = 256 * 1024;
int checks = 0;

void expect(bool passed, const std::string& description) {
    ++checks;
    if (!passed) {
        std::cerr << "HTTP range check failed: " << description << std::endl;
        std::exit(1);
    }
}

void expectBytes(const uint8_t* bytes, int count, int64_t offset, const std::string& description) {
    bool correct = count >= 0;
    for (int index = 0; correct && index < count; ++index) {
        correct = bytes[index] == static_cast<uint8_t>(((offset + index) * 37 + 11) % 256);
    }
    expect(correct, description);
}

bool balancedWaiting(const std::vector<bool>& transitions) {
    if (transitions.size() % 2 != 0) return false;
    for (size_t index = 0; index < transitions.size(); ++index) {
        if (transitions[index] != (index % 2 == 0)) return false;
    }
    return true;
}

void normalReadChecks(const std::string& base) {
    std::vector<bool> waitingTransitions;
    sp::HTTPRangeIO io(base + "/ok?key=a%2Bb%26c", [] { return false; }, 120.0,
                      [&](bool waiting) { waitingTransitions.push_back(waiting); });
    expect(io.open() >= 0, "open a ranged HTTP resource with an encoded query");
    expect(waitingTransitions.empty(), "a fast opening HTTP probe does not announce buffering");
    expect(io.size() == fixtureSize, "the probe establishes the full resource size");
    expect(io.seek(0, AVSEEK_SIZE) == fixtureSize, "AVSEEK_SIZE reports the full size");
    std::vector<uint8_t> bytes(maximumRead + 1024);
    int read = io.read(bytes.data(), static_cast<int>(bytes.size()));
    expect(read > 0 && read <= maximumRead, "a read is bounded to 256 KiB");
    expectBytes(bytes.data(), read, 0, "the first read starts at byte zero");
    expect(waitingTransitions.empty(),
           "a cached probe byte does not publish another network waiting interval");
    const int firstCount = read;
    read = io.read(bytes.data(), 127);
    expect(read > 0 && read <= 127, "the next read respects the caller's buffer size");
    expectBytes(bytes.data(), read, firstCount, "sequential reads advance without gaps");
    expect(waitingTransitions.empty(), "a fast uncached read does not announce buffering");
    expect(io.seek(400000, SEEK_SET) == 400000, "select an uncached offset for a large read");
    read = io.read(bytes.data(), static_cast<int>(bytes.size()));
    expect(read == maximumRead, "a large uncached read stops at the 256 KiB request bound");
    expectBytes(bytes.data(), read, 400000, "a bounded large read preserves every requested byte");

    expect(io.seek(12345, SEEK_SET) == 12345, "SEEK_SET selects an absolute byte offset");
    expect(io.seek(32, SEEK_CUR) == 12377, "SEEK_CUR advances from the current byte offset");
    read = io.read(bytes.data(), 63);
    expect(read > 0 && read <= 63, "a read after a seek succeeds");
    expectBytes(bytes.data(), read, 12377, "a read after a seek uses the selected range");
    expect(io.seek(-17, SEEK_END) == fixtureSize - 17, "SEEK_END can select the final bytes");
    read = io.read(bytes.data(), 64);
    expect(read == 17, "the final read returns only the remaining bytes");
    expectBytes(bytes.data(), read, fixtureSize - 17, "the final bytes are not truncated or repeated");
    expect(io.read(bytes.data(), 64) == AVERROR_EOF, "a read at exact EOF returns AVERROR_EOF");
    expect(io.seek(fixtureSize, SEEK_SET) == fixtureSize, "seeking to exact EOF is allowed");
    expect(io.read(bytes.data(), 64) == AVERROR_EOF, "a seek to EOF does not issue an invalid range");
    expect(io.seek(fixtureSize + 100, SEEK_SET) == fixtureSize + 100,
           "seeking beyond EOF is allowed");
    expect(io.read(bytes.data(), 64) == AVERROR_EOF, "a read beyond EOF returns AVERROR_EOF");
    expect(io.seek(0, SEEK_SET) == 0, "seeking back from EOF resets the read position");
    read = io.read(bytes.data(), 31);
    expect(read > 0, "reading resumes after a backward seek");
    expectBytes(bytes.data(), read, 0, "a backward seek does not reuse stale cached offsets");
    expect(waitingTransitions.empty(), "normal fast HTTP fetches never flash a waiting marker");
}

void seekFailureChecks(const std::string& base) {
    sp::HTTPRangeIO io(base + "/ok", [] { return false; });
    expect(io.open() >= 0, "open resource for seek error checks");
    expect(io.seek(-1, SEEK_SET) < 0, "negative absolute seeks fail");
    expect(io.seek(-fixtureSize - 1, SEEK_END) < 0, "negative final byte offsets fail");
    expect(io.seek(INT64_MAX, SEEK_END) < 0, "SEEK_END rejects signed overflow");
    expect(io.seek(INT64_MAX, SEEK_SET) == INT64_MAX, "a large nonnegative absolute offset is valid");
    expect(io.seek(1, SEEK_CUR) < 0, "SEEK_CUR rejects signed overflow");
    expect(io.seek(INT64_MIN, SEEK_CUR) < 0, "SEEK_CUR rejects a negative resulting offset");
    expect(io.seek(0, 0x12345) < 0, "unsupported seek modes fail");
    expect(io.seek(0, SEEK_SET) == 0, "a failed seek does not break later valid seeks");
}

void protocolChecks() {
    expect(sp::HTTPRangeIO::supportsURL("http://127.0.0.1/video.mkv"), "HTTP URLs are supported");
    expect(sp::HTTPRangeIO::supportsURL("https://example.invalid/video.mkv"), "HTTPS URLs are supported");
    expect(!sp::HTTPRangeIO::supportsURL("file:///tmp/video.mkv"), "file URLs remain on local IO");
    expect(!sp::HTTPRangeIO::supportsURL("ftp://example.invalid/video.mkv"), "unimplemented schemes are rejected");
    expect(!sp::HTTPRangeIO::supportsURL("httpx://example.invalid/video.mkv"), "scheme prefixes are not accepted as HTTP");
    expect(!sp::HTTPRangeIO::supportsURL(""), "an empty URL is rejected");
}

void responseValidationChecks(const std::string& base) {
    sp::HTTPRangeIO noHead(base + "/head405", [] { return false; });
    expect(noHead.open() >= 0, "a server that refuses HEAD still opens through a range probe");
    expect(noHead.size() == fixtureSize, "GET range metadata determines size without HEAD");
    uint8_t bytes[64]{};
    expect(noHead.read(bytes, sizeof(bytes)) > 0, "a HEAD-refusing server remains readable");

    sp::HTTPRangeIO empty(base + "/empty", [] { return false; });
    expect(empty.open() >= 0, "an empty resource opens from a valid 416 bytes */0 probe");
    expect(empty.size() == 0, "an empty resource reports zero size");
    expect(empty.read(bytes, sizeof(bytes)) == AVERROR_EOF, "an empty resource immediately reports EOF");

    sp::HTTPRangeIO shortRange(base + "/short-valid", [] { return false; });
    expect(shortRange.open() >= 0, "a valid server with shortened range responses opens");
    expect(shortRange.seek(16, SEEK_SET) == 16, "leave the probe cache before testing a short response");
    const int shortRead = shortRange.read(bytes, sizeof(bytes));
    expect(shortRead > 0 && shortRead <= 11, "a valid short 206 response is accepted");
    expectBytes(bytes, shortRead, 16, "a short 206 response returns the requested starting bytes");

    for (const std::string path : {"/bad-origin", "/bad-total", "/bad-length", "/truncated", "/ignore-range"}) {
        std::vector<bool> waitingTransitions;
        sp::HTTPRangeIO malformed(base + path, [] { return false; }, 2.0,
                                 [&](bool waiting) { waitingTransitions.push_back(waiting); });
        expect(malformed.open() < 0, "reject malformed or unbounded probe response at " + path);
        expect(waitingTransitions.empty(), "a fast invalid response does not flash a waiting marker at " + path);
    }
}

void interruptionChecks(const std::string& base) {
    std::vector<bool> beforeOpenTransitions;
    sp::HTTPRangeIO cancelledBeforeOpen(base + "/ok", [] { return true; }, 120.0,
                                      [&](bool waiting) { beforeOpenTransitions.push_back(waiting); });
    expect(cancelledBeforeOpen.open() == AVERROR_EXIT, "an already interrupted open returns AVERROR_EXIT");
    expect(beforeOpenTransitions.empty(), "an already interrupted open never announces an HTTP fetch");

    std::atomic<bool> interrupted{false};
    std::atomic<bool> waiting{false};
    std::atomic<bool> observedWaiting{false};
    std::vector<bool> stalledTransitions;
    sp::HTTPRangeIO stalled(base + "/stall", [&] { return interrupted.load(); }, 120.0,
                           [&](bool value) { stalledTransitions.push_back(value); waiting.store(value); });
    expect(stalled.open() >= 0, "open a resource before its later response stalls");
    expect(stalled.seek(16, SEEK_SET) == 16, "select a range outside the one-byte probe");
    uint8_t bytes[64]{};
    const auto started = std::chrono::steady_clock::now();
    std::thread cancel([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(350));
        observedWaiting.store(waiting.load());
        interrupted.store(true);
    });
    const int result = stalled.read(bytes, sizeof(bytes));
    const auto elapsed = std::chrono::steady_clock::now() - started;
    cancel.join();
    expect(result == AVERROR_EXIT, "interrupting a stalled body returns AVERROR_EXIT");
    expect(elapsed < std::chrono::seconds(1), "cancellation releases a stalled read within one second");
    expect(observedWaiting.load(), "the waiting marker stays active while a body is stalled");
    expect(!waiting.load(), "cancellation clears the waiting marker before read returns");
    expect(balancedWaiting(stalledTransitions), "cancelled fetches publish balanced waiting transitions");

    waiting.store(false);
    observedWaiting.store(false);
    std::vector<bool> timeoutTransitions;
    sp::HTTPRangeIO timedOut(base + "/timeout", [] { return false; }, 0.4,
                            [&](bool value) { timeoutTransitions.push_back(value); waiting.store(value); });
    expect(timedOut.open() >= 0, "a short explicit timeout still allows the immediate probe");
    expect(timedOut.seek(16, SEEK_SET) == 16, "select a stalled range for timeout checks");
    const auto timeoutStarted = std::chrono::steady_clock::now();
    std::thread observeTimeout([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        observedWaiting.store(waiting.load());
    });
    expect(timedOut.read(bytes, sizeof(bytes)) < 0, "a stalled response eventually returns a timeout error");
    observeTimeout.join();
    expect(std::chrono::steady_clock::now() - timeoutStarted < std::chrono::seconds(3),
           "an explicit request timeout bounds a stalled body");
    expect(observedWaiting.load(), "a timed HTTP body remains marked as waiting until timeout");
    expect(!waiting.load(), "timeout clears the waiting marker before read returns");
    expect(balancedWaiting(timeoutTransitions), "timed-out fetches publish balanced waiting transitions");
}

void authenticationChecks(const std::string& base) {
    sp::HTTPRangeIO unauthorized(base + "/auth", [] { return false; });
    expect(unauthorized.open() == AVERROR(EACCES), "a protected resource reports access denied without credentials");
    std::string authenticated = base;
    authenticated.insert(authenticated.find("://") + 3, "user%20name:p%3Aass%20word@");
    sp::HTTPRangeIO authorized(authenticated + "/auth", [] { return false; });
    expect(authorized.open() >= 0, "percent-encoded URL credentials produce a valid Basic authorization header");
    expect(authorized.seek(16, SEEK_SET) == 16, "leave the authorized probe cache");
    uint8_t bytes[64]{};
    const int read = authorized.read(bytes, sizeof(bytes));
    expect(read > 0 && read <= static_cast<int>(sizeof(bytes)), "subsequent ranged requests retain authorization");
    expectBytes(bytes, read, 16, "authorized ranged bytes preserve the resource contents");
}

void transientRetryChecks(const std::string& base) {
    for (const std::string path : {"/retry-once", "/retry-twice", "/retry-reset"}) {
        sp::HTTPRangeIO io(base + path, [] { return false; }, 2.0);
        expect(io.open() >= 0, "open transient retry fixture " + path);
        expect(io.seek(16, SEEK_SET) == 16, "leave transient retry probe cache");
        uint8_t bytes[64]{};
        const int read = io.read(bytes, sizeof(bytes));
        expect(read == sizeof(bytes), "recover a complete range before returning it to AVIO " + path);
        expectBytes(bytes, read, 16, "retries never duplicate or skip returned bytes " + path);
        expect(io.seek(0, SEEK_CUR) == 16 + sizeof(bytes), "advance only once after recovered range");
    }
    for (const std::string path : {"/retry-persistent", "/retry-reset-changed", "/retry-total-changed",
                                   "/changed-etag", "/invalid-body"}) {
        sp::HTTPRangeIO io(base + path, [] { return false; }, 2.0);
        expect(io.open() >= 0, "open terminal retry fixture " + path);
        expect(io.seek(16, SEEK_SET) == 16, "select terminal range");
        uint8_t bytes[64];
        std::fill(std::begin(bytes), std::end(bytes), 0xCC);
        const int result = io.read(bytes, sizeof(bytes));
        expect(result == (path == "/retry-persistent" ? AVERROR(EIO) : AVERROR_INVALIDDATA),
               "return the terminal transport or validation error " + path);
        expect(io.seek(0, SEEK_CUR) == 16, "failed retries do not advance position " + path);
        expect(std::all_of(std::begin(bytes), std::end(bytes), [](uint8_t b) { return b == 0xCC; }),
               "partial or invalid response bytes never reach caller " + path);
    }
    for (const std::string path : {"/not-found", "/forbidden"}) {
        sp::HTTPRangeIO io(base + path, [] { return false; });
        expect(io.open() == AVERROR(path == "/not-found" ? ENOENT : EACCES),
               "permanent HTTP status is not retried " + path);
    }
    std::atomic<bool> cancelled{false};
    std::atomic<bool> retryBackoffEntered{false};
    auto* retryEntered = &retryBackoffEntered;
    id cancellationObserver = [NSNotificationCenter.defaultCenter addObserverForName:@"KinoletHTTPRangeDiagnostic"
        object:nil queue:nil usingBlock:^(NSNotification* notification) {
            if ([notification.userInfo[@"phase"] intValue] == 3) retryEntered->store(true);
        }];
    sp::HTTPRangeIO cancellation(base + "/retry-cancel", [&] { return cancelled.load(); }, 2.0);
    expect(cancellation.open() >= 0, "open backoff cancellation fixture");
    expect(cancellation.seek(16, SEEK_SET) == 16, "leave cancellation probe cache");
    uint8_t bytes[64]{};
    const auto cancelStart = std::chrono::steady_clock::now();
    std::thread cancel([&] {
        const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        while (!retryBackoffEntered.load() && std::chrono::steady_clock::now() < until)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        cancelled.store(true);
    });
    const int cancelledResult = cancellation.read(bytes, sizeof(bytes));
    const auto cancelElapsed = std::chrono::steady_clock::now() - cancelStart;
    cancel.join();
    [NSNotificationCenter.defaultCenter removeObserver:cancellationObserver];
    expect(retryBackoffEntered.load(), "cancellation fixture actually enters retry backoff");
    expect(cancelledResult == AVERROR_EXIT, "cancellation interrupts transient retry backoff");
    expect(cancelElapsed < std::chrono::milliseconds(200), "retry cancellation is promptly polled");

    std::vector<bool> deadlineWaiting;
    sp::HTTPRangeIO deadline(base + "/retry-deadline", [] { return false; }, 0.18,
                            [&](bool value) { deadlineWaiting.push_back(value); });
    expect(deadline.open() >= 0, "open logical deadline fixture");
    expect(deadline.seek(16, SEEK_SET) == 16, "leave deadline probe cache");
    const auto deadlineStart = std::chrono::steady_clock::now();
    expect(deadline.read(bytes, sizeof(bytes)) == AVERROR(ETIMEDOUT), "retries share one original deadline");
    expect(std::chrono::steady_clock::now() - deadlineStart < std::chrono::milliseconds(350),
           "retry attempts do not multiply the request timeout");
    expect(balancedWaiting(deadlineWaiting), "logical deadline leaves balanced waiting state");

    std::vector<bool> slowWaiting;
    NSMutableArray<NSDictionary*>* events = [NSMutableArray array];
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:@"KinoletHTTPRangeDiagnostic"
        object:nil queue:nil usingBlock:^(NSNotification* notification) { [events addObject:notification.userInfo]; }];
    sp::HTTPRangeIO slow(base + "/retry-slow", [] { return false; }, 3.0,
                        [&](bool value) { slowWaiting.push_back(value); });
    expect(slow.open() >= 0, "open waiting-across-retries fixture");
    expect(slow.seek(16, SEEK_SET) == 16, "leave slow probe cache");
    expect(slow.read(bytes, sizeof(bytes)) == sizeof(bytes), "a slower retried body completes");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    expect(slowWaiting == std::vector<bool>({true, false}), "one balanced waiting interval spans all attempts");
    int phases[4]{};
    bool numericOnly = true;
    const int64_t reader = [events.firstObject[@"reader"] longLongValue];
    for (NSDictionary* event in events) {
        numericOnly &= event.count == 7 && [event[@"reader"] longLongValue] == reader && reader > 0;
        for (NSString* key in event) {
            id value = event[key];
            numericOnly &= [value isKindOfClass:NSNumber.class] && strcmp([value objCType], @encode(double)) != 0;
        }
        const int phase = [event[@"phase"] intValue];
        if (phase >= 1 && phase <= 3) phases[phase]++;
    }
    expect(numericOnly, "persistent range diagnostics contain only seven numeric fields and stable reader ID");
    expect(phases[1] == 1 && phases[2] == 1 && phases[3] == 2,
           "slow logical fetch emits one waiting, one completion, and two bounded retry diagnostics");
}

void cacheWindowChecks(const std::string& base) {
    auto readAt = [](sp::HTTPRangeIO& io, int64_t offset) {
        expect(io.seek(offset, SEEK_SET) == offset, "select an interleaved cache region");
        uint8_t bytes[1024]{};
        const int received = io.read(bytes, sizeof(bytes));
        expect(received == sizeof(bytes), "interleaved cache reads preserve the requested count");
        bool valid = true;
        for (int i = 0; valid && i < received; ++i) {
            const int64_t p = offset + i;
            valid = bytes[i] == uint8_t(((p * 37 + 11) ^ (p >> 8) ^ ((p >> 16) * 13)) & 255);
        }
        expect(valid, "cached bytes match their physical region including high offset bits");
    };
    sp::HTTPRangeIO interleaved(base + "/cache-interleaved", [] { return false; });
    expect(interleaved.open() >= 0, "open interleaved stream fixture");
    for (int i = 0; i < 24; ++i) {
        readAt(interleaved, 128 * 1024 + 17 + i * 32);
        readAt(interleaved, 1024 * 1024 + 93 + i * 32);
    }
    sp::HTTPRangeIO eviction(base + "/cache-lru", [] { return false; });
    expect(eviction.open() >= 0, "open bounded LRU fixture");
    for (int i = 0; i < 8; ++i) readAt(eviction, int64_t(i) * 512 * 1024 + 64);
    readAt(eviction, 64); // Most recently used window must survive the next insertion.
    readAt(eviction, 8 * 512 * 1024 + 64);
    readAt(eviction, 64);
    readAt(eviction, 512 * 1024 + 64); // The oldest of the other eight was evicted.
}
}

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc != 2) {
            std::cerr << "Usage: http-range-io-checks BASE_URL" << std::endl;
            return 2;
        }
        const std::string base = argv[1];
        protocolChecks();
        normalReadChecks(base);
        seekFailureChecks(base);
        responseValidationChecks(base);
        interruptionChecks(base);
        authenticationChecks(base);
        cacheWindowChecks(base);
        transientRetryChecks(base);
        std::cout << "HTTP range IO checks passed (" << checks << " assertions)." << std::endl;
    }
}
