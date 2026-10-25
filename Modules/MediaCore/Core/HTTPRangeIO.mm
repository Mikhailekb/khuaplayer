#include "HTTPRangeIO.hpp"
#import <Foundation/Foundation.h>

extern "C" {
#include <libavformat/avio.h>
#include <libavutil/error.h>
}

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <string_view>
#include <thread>
#include <vector>

namespace {
constexpr int64_t kRangeBytes = 256 * 1024;
constexpr size_t kCacheWindows = 8;
std::atomic<int64_t> nextReader{1};

struct ContentRange {
    int64_t first = -1, last = -1, total = -1;
    bool empty = false;
};

bool parseNumber(std::string_view text, int64_t& value) {
    if (text.empty()) return false;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), value);
    return result.ec == std::errc{} && result.ptr == text.data() + text.size() && value >= 0;
}

bool parseContentRange(NSString* header, ContentRange& range) {
    if (!header) return false;
    const char* raw = header.UTF8String;
    if (!raw) return false;
    std::string_view text(raw);
    if (text.size() < 8 || [header rangeOfString:@"bytes " options:NSCaseInsensitiveSearch].location != 0)
        return false;
    text.remove_prefix(6);
    if (text == "*/0") { range.total = 0; range.empty = true; return true; }
    const auto dash = text.find('-'), slash = text.find('/');
    if (dash == text.npos || slash == text.npos || dash >= slash) return false;
    return parseNumber(text.substr(0, dash), range.first) &&
           parseNumber(text.substr(dash + 1, slash - dash - 1), range.last) &&
           parseNumber(text.substr(slash + 1), range.total) &&
           range.first <= range.last && range.last < range.total;
}

NSURLComponents* urlComponents(const std::string& text) {
    NSString* string = [[NSString alloc] initWithBytes:text.data() length:text.size()
                                            encoding:NSUTF8StringEncoding];
    if (!string) return nil;
    NSURLComponents* components = [NSURLComponents componentsWithString:string];
    NSString* scheme = components.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ||
        components.host.length == 0 || !components.URL) return nil;
    return components;
}
} // namespace

// Session callbacks never retain the C++ input or its interrupt callback. A
// cancelled request may finish after its demux owner has already been released.
@interface SPHTTPRangeRequest : NSObject {
@public
    int64_t first, last, knownTotal, total, expectedLength;
    int result;
    NSInteger httpStatus;
    BOOL headersValidated, acceptedEmpty, retryable, cancelledResult;
    NSString* expectedValidator;
    NSString* validator;
    NSMutableData* body;
    dispatch_semaphore_t completed;
}
@end
@implementation SPHTTPRangeRequest
- (instancetype)init {
    if ((self = [super init])) {
        first = last = knownTotal = total = expectedLength = -1;
        body = [NSMutableData data];
        completed = dispatch_semaphore_create(0);
    }
    return self;
}
@end

@interface SPHTTPRangeTransport : NSObject <NSURLSessionDataDelegate> {
    NSLock* _lock;
    NSMutableDictionary<NSNumber*, SPHTTPRangeRequest*>* _requests;
}
- (void)addRequest:(SPHTTPRangeRequest*)request task:(NSURLSessionTask*)task;
@end

@implementation SPHTTPRangeTransport
- (instancetype)init {
    if ((self = [super init])) { _lock = [NSLock new]; _requests = [NSMutableDictionary dictionary]; }
    return self;
}
- (void)addRequest:(SPHTTPRangeRequest*)request task:(NSURLSessionTask*)task {
    [_lock lock]; _requests[@(task.taskIdentifier)] = request; [_lock unlock];
}
- (SPHTTPRangeRequest*)requestForTask:(NSURLSessionTask*)task remove:(BOOL)remove {
    [_lock lock];
    SPHTTPRangeRequest* request = _requests[@(task.taskIdentifier)];
    if (remove) [_requests removeObjectForKey:@(task.taskIdentifier)];
    [_lock unlock];
    return request;
}
- (void)URLSession:(NSURLSession*)session dataTask:(NSURLSessionDataTask*)task
 didReceiveResponse:(NSURLResponse*)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    SPHTTPRangeRequest* state = [self requestForTask:task remove:NO];
    if (!state) { completionHandler(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse* http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
    state->httpStatus = http.statusCode;
    ContentRange range;
    const BOOL validRange = parseContentRange([http valueForHTTPHeaderField:@"Content-Range"], range);
    if (http.statusCode == 416 && validRange && range.empty && state->knownTotal < 0) {
        state->total = 0; state->acceptedEmpty = YES;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (http.statusCode != 206) {
        state->retryable = http.statusCode == 500 || http.statusCode == 502 ||
                           http.statusCode == 503 || http.statusCode == 504;
        state->result = AVERROR(http.statusCode == 401 || http.statusCode == 403 ? EACCES :
                                http.statusCode == 404 ? ENOENT : EIO);
        completionHandler(NSURLSessionResponseCancel); // Never collect a server's full-file 200 body.
        return;
    }
    NSString* encoding = [http valueForHTTPHeaderField:@"Content-Encoding"];
    NSString* entity = [http valueForHTTPHeaderField:@"ETag"];
    if (!entity.length) entity = [http valueForHTTPHeaderField:@"Last-Modified"];
    const BOOL changed = state->expectedValidator.length && entity.length &&
                         ![state->expectedValidator isEqualToString:entity];
    if (!validRange || range.empty || range.first != state->first || range.last > state->last ||
        (state->knownTotal >= 0 && range.total != state->knownTotal) || changed ||
        (encoding.length && ![encoding.lowercaseString isEqualToString:@"identity"])) {
        state->result = AVERROR_INVALIDDATA;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    const int64_t length = range.last - range.first + 1;
    NSString* declared = [http valueForHTTPHeaderField:@"Content-Length"];
    int64_t declaredLength = 0;
    if (length > kRangeBytes || (declared &&
        (!parseNumber(declared.UTF8String ?: "", declaredLength) || declaredLength != length))) {
        state->result = AVERROR_INVALIDDATA;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    state->total = range.total;
    state->expectedLength = length;
    state->validator = entity;
    state->headersValidated = YES;
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession*)session dataTask:(NSURLSessionDataTask*)task didReceiveData:(NSData*)data {
    SPHTTPRangeRequest* state = [self requestForTask:task remove:NO];
    if (!state || state->result < 0) return;
    if (!state->headersValidated || data.length > (NSUInteger)state->expectedLength ||
        state->body.length > (NSUInteger)state->expectedLength - data.length) {
        state->result = AVERROR_INVALIDDATA;
        [task cancel];
        return;
    }
    [state->body appendData:data];
}
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error {
    SPHTTPRangeRequest* state = [self requestForTask:task remove:YES];
    if (!state) return;
    if (state->acceptedEmpty) state->result = 0;
    else if (state->result >= 0) {
        if (error) {
            state->result = AVERROR(error.code == NSURLErrorTimedOut ? ETIMEDOUT : EIO);
            state->cancelledResult = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
            state->retryable = [error.domain isEqualToString:NSURLErrorDomain] &&
                (error.code == NSURLErrorNetworkConnectionLost || error.code == NSURLErrorTimedOut ||
                 error.code == NSURLErrorCannotConnectToHost || error.code == NSURLErrorNotConnectedToInternet);
        } else if (!state->headersValidated || state->body.length != (NSUInteger)state->expectedLength)
            state->result = AVERROR_INVALIDDATA;
    }
    dispatch_semaphore_signal(state->completed);
}
@end

namespace sp {
struct HTTPRangeIO::Impl {
    std::function<bool()> interrupted;
    std::function<void(bool)> waitingChanged;
    std::function<bool()> readAdmission;
    double timeout;
    NSURL* url = nil;
    NSString* authorization = nil;
    NSString* validator = nil;
    SPHTTPRangeTransport* transport = nil;
    NSURLSession* session = nil;
    int64_t length = -1, position = 0;
    int64_t readBlockBytes = kRangeBytes;
    struct CacheWindow {
        int64_t first;
        uint64_t access;
        std::vector<uint8_t> bytes;
    };
    std::vector<CacheWindow> cache;
    uint64_t cacheAccess = 0;
    const int64_t reader = nextReader.fetch_add(1, std::memory_order_relaxed);

    void diagnose(int64_t start, int64_t count, int64_t waitMs, int phase, int result, int attempt) {
        NSLog(@"[KinoletRange] reader=%lld start=%lld count=%lld wait_ms=%lld phase=%d result=%d attempt=%d",
              (long long)reader, (long long)start, (long long)count, (long long)waitMs, phase, result, attempt);
        // A private bounded consumer can retain diagnostics even when launchd
        // redirects stderr. This contains no URL, path, headers or credentials.
        [NSNotificationCenter.defaultCenter postNotificationName:@"KinoletHTTPRangeDiagnostic" object:nil
            userInfo:@{@"reader": @(reader), @"start": @(start), @"count": @(count),
                       @"waitMs": @(waitMs), @"phase": @(phase), @"result": @(result), @"attempt": @(attempt)}];
    }

    CacheWindow* cachedAt(int64_t offset) {
        for (auto& window : cache) {
            if (offset >= window.first && offset - window.first < (int64_t)window.bytes.size()) {
                window.access = ++cacheAccess;
                return &window;
            }
        }
        return nullptr;
    }
    void cacheBytes(int64_t first, std::vector<uint8_t> bytes) {
        if (bytes.empty()) return;
        // A demuxer alternates between nearby audio/video/index regions. Retain
        // a few validated windows rather than downloading each again on a seek.
        // Windows retain their exact response origins, including short206s.
        for (auto& window : cache) {
            if (window.first == first) {
                window = {first, ++cacheAccess, std::move(bytes)};
                return;
            }
        }
        if (cache.size() < kCacheWindows) {
            cache.push_back({first, ++cacheAccess, std::move(bytes)});
        } else {
            auto oldest = std::min_element(cache.begin(), cache.end(),
                [](const auto& a, const auto& b) { return a.access < b.access; });
            *oldest = {first, ++cacheAccess, std::move(bytes)};
        }
    }

    Impl(const std::string& text, std::function<bool()> stop, double seconds,
         std::function<void(bool)> waiting)
        : interrupted(std::move(stop)), waitingChanged(std::move(waiting)),
          timeout(std::isfinite(seconds) && seconds > 0 ? seconds : 120.0) {
        @autoreleasepool {
            NSURLComponents* components = urlComponents(text);
            if (!components) return;
            if (components.user != nil) {
                NSString* credentials = [NSString stringWithFormat:@"%@:%@", components.user, components.password ?: @""];
                authorization = [@"Basic " stringByAppendingString:
                    [[credentials dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
            }
            components.user = nil; components.password = nil; components.fragment = nil;
            url = components.URL;
            NSURLSessionConfiguration* configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            configuration.URLCache = nil;
            configuration.HTTPCookieStorage = nil;
            configuration.URLCredentialStorage = nil;
            configuration.HTTPShouldSetCookies = NO;
            configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
            configuration.timeoutIntervalForRequest = timeout;
            configuration.timeoutIntervalForResource = timeout;
            configuration.HTTPMaximumConnectionsPerHost = 1;
            transport = [SPHTTPRangeTransport new];
            NSOperationQueue* callbacks = [NSOperationQueue new];
            callbacks.maxConcurrentOperationCount = 1;
            callbacks.qualityOfService = NSQualityOfServiceUserInitiated;
            session = [NSURLSession sessionWithConfiguration:configuration delegate:transport delegateQueue:callbacks];
        }
    }
    ~Impl() { [session invalidateAndCancel]; }
    bool cancelled() const { return interrupted && interrupted(); }
    int fetch(int64_t start, int64_t count, std::vector<uint8_t>& output, int64_t& receivedTotal) {
        @autoreleasepool {
            const auto started = std::chrono::steady_clock::now();
            int currentAttempt = 0;
            bool retryAnnounced = false;
            auto elapsedMs = [&] {
                return std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - started).count();
            };
            auto finish = [&](int result) {
                const int64_t milliseconds = elapsedMs();
                // Persistent diagnostics contain numeric positions/results only.
                // A demux yield is expected cancellation, not a transport failure.
                if (retryAnnounced || milliseconds >= 500 || (result < 0 && result != AVERROR_EXIT))
                    diagnose(start, count, milliseconds, 2, result, currentAttempt);
                return result;
            };
            if (cancelled()) return finish(AVERROR_EXIT);
            if (!url || !session || start < 0 || count <= 0 || count > kRangeBytes || start > INT64_MAX - count)
                return finish(AVERROR(EINVAL));
            struct WaitingScope {
                std::function<void(bool)>& changed;
                bool announced = false;
                explicit WaitingScope(std::function<void(bool)>& callback) : changed(callback) {}
                void announce() {
                    if (!announced && changed) { announced = true; changed(true); }
                }
                void suspend() { if (announced) { announced = false; changed(false); } }
                ~WaitingScope() { suspend(); }
            } waiting(waitingChanged);
            auto deadline = started + std::chrono::duration<double>(timeout);
            std::chrono::steady_clock::duration deniedTime{};
            std::chrono::steady_clock::time_point deniedSince{};
            bool admissionDenied = false;
            uint64_t deniedSequence = 0;
            auto noteAdmission = [&](bool admitted) {
                const auto now = std::chrono::steady_clock::now();
                if (!admitted && !admissionDenied) {
                    admissionDenied = true;
                    ++deniedSequence;
                    deniedSince = now;
                    waiting.suspend();
                } else if (admitted && admissionDenied) {
                    const auto paused = now - deniedSince;
                    deniedTime += paused;
                    deadline += paused;
                    admissionDenied = false;
                }
            };
            auto admitted = [&] { return !readAdmission || readAdmission(); };
            auto awaitAdmission = [&] {
                if (!readAdmission) return !cancelled();
                while (true) {
                    const bool allowed = admitted();
                    noteAdmission(allowed);
                    if (cancelled()) { noteAdmission(true); return false; }
                    if (allowed) return true;
                    std::this_thread::sleep_for(std::chrono::milliseconds(25));
                }
            };
            bool slowAnnounced = false;
            auto announceWaiting = [&] {
                const auto elapsed = std::chrono::steady_clock::now() - started - deniedTime;
                if (!slowAnnounced && elapsed >= std::chrono::milliseconds(500)) {
                    slowAnnounced = true;
                    diagnose(start, count, elapsedMs(), 1, 0, currentAttempt);
                }
                if (elapsed >= std::chrono::milliseconds(250)) waiting.announce();
            };
            int64_t expectedTotal = length;
            NSString* expectedValidator = validator;
            // A transient transport error must not reach AVIO: some demuxers
            // retain it as terminal EOF, while others discard an incomplete packet.
            // Retry the exact bounded request, never exposing a partial body.
            int attempt = 0;
            int conflictReplays = 0;
            while (attempt < 3) {
                currentAttempt = attempt + 1;
                if (!awaitAdmission()) return finish(AVERROR_EXIT);
                const double remaining = std::chrono::duration<double>(
                    deadline - std::chrono::steady_clock::now()).count();
                if (remaining <= 0) return finish(AVERROR(ETIMEDOUT));
                // Admission can revoke repeatedly. Release every cancelled task
                // and partial body before creating its same-range replacement.
                @autoreleasepool {
                    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url
                        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:remaining];
                    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", (long long)start,
                        (long long)(start + count - 1)] forHTTPHeaderField:@"Range"];
                    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
                    if (authorization) [request setValue:authorization forHTTPHeaderField:@"Authorization"];
                    if (expectedValidator) [request setValue:expectedValidator forHTTPHeaderField:@"If-Range"];
                    // No suspended task exists while waiting for admission.
                    if (!awaitAdmission()) return finish(AVERROR_EXIT);
                    request.timeoutInterval = std::chrono::duration<double>(
                        deadline - std::chrono::steady_clock::now()).count();
                    if (request.timeoutInterval <= 0) return finish(AVERROR(ETIMEDOUT));
                    const uint64_t requestDeniedSequence = deniedSequence;
                    SPHTTPRangeRequest* state = [SPHTTPRangeRequest new];
                    state->first = start; state->last = start + count - 1;
                    state->knownTotal = expectedTotal; state->expectedValidator = expectedValidator;
                    NSURLSessionDataTask* task = [session dataTaskWithRequest:request];
                    [transport addRequest:state task:task];
                    [task resume];
                    bool preempted = false;
                    const int pollMs = readAdmission ? 25 : 50;
                    while (dispatch_semaphore_wait(state->completed,
                           dispatch_time(DISPATCH_TIME_NOW, pollMs * NSEC_PER_MSEC))) {
                        if (cancelled()) { [task cancel]; return finish(AVERROR_EXIT); }
                        if (!admitted()) {
                            noteAdmission(false);
                            [task cancel];
                            preempted = true;
                            // Completion is the handoff barrier: no replacement
                            // task overlaps a reader that has not been cancelled.
                            while (dispatch_semaphore_wait(state->completed,
                                   dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC))) {
                                if (cancelled()) { noteAdmission(true); return finish(AVERROR_EXIT); }
                                noteAdmission(admitted());
                                if (!admissionDenied && std::chrono::steady_clock::now() >= deadline)
                                    return finish(AVERROR(ETIMEDOUT));
                            }
                            break;
                        }
                        if (std::chrono::steady_clock::now() >= deadline) {
                            [task cancel]; return finish(AVERROR(ETIMEDOUT));
                        }
                        announceWaiting();
                    }
                    if (cancelled()) { noteAdmission(true); return finish(AVERROR_EXIT); }
                    if (!awaitAdmission()) return finish(AVERROR_EXIT);
                    if (state->headersValidated) {
                        // A cancelled body still establishes immutable identity.
                        expectedTotal = state->total;
                        if (state->validator.length) expectedValidator = state->validator;
                    }
                    if (std::chrono::steady_clock::now() >= deadline) return finish(AVERROR(ETIMEDOUT));
                    if (preempted && state->cancelledResult) continue;
                    // A worker can reject a racing background request while its
                    // parent seek is awaiting acknowledgment. Only an observed
                    // admission revocation makes that409 a soft lane conflict.
                    // Invalid ranges/entities/bodies and permanent statuses keep
                    // their existing terminal behavior, even after revocation.
                    if (readAdmission && state->httpStatus == 409 &&
                        deniedSequence != requestDeniedSequence && conflictReplays < 2) {
                        ++conflictReplays;
                        retryAnnounced = true;
                        diagnose(start, count, elapsedMs(), 3, AVERROR(EAGAIN), currentAttempt);
                        continue;
                    }
                    if (state->result >= 0) {
                        receivedTotal = state->total;
                        if (state->validator.length) validator = state->validator;
                        output.resize(state->body.length);
                        if (!output.empty()) memcpy(output.data(), state->body.bytes, output.size());
                        return finish(0);
                    }
                    if (!state->retryable || attempt == 2) return finish(state->result);
                    retryAnnounced = true;
                    diagnose(start, count, elapsedMs(), 3, state->result, currentAttempt);
                    const auto retryAt = std::chrono::steady_clock::now() +
                        std::chrono::duration<double>(attempt == 0 ? 0.05 : 0.15);
                    ++attempt;
                    while (std::chrono::steady_clock::now() < retryAt) {
                        if (!awaitAdmission()) return finish(AVERROR_EXIT);
                        const auto now = std::chrono::steady_clock::now();
                        if (now >= deadline) return finish(AVERROR(ETIMEDOUT));
                        if (now >= retryAt) break;
                        announceWaiting();
                        std::this_thread::sleep_for(std::min(std::chrono::duration<double>(retryAt - now),
                                                            std::chrono::duration<double>(0.025)));
                    }
                }
            }
            return finish(AVERROR(EIO));
        }
    }
};

HTTPRangeIO::HTTPRangeIO(std::string url, std::function<bool()> interrupted, double timeout,
                         std::function<void(bool)> waitingChanged)
    : impl_(std::make_unique<Impl>(url, std::move(interrupted), timeout, std::move(waitingChanged))) {}
HTTPRangeIO::~HTTPRangeIO() = default;
bool HTTPRangeIO::supportsURL(const std::string& url) {
    @autoreleasepool { return urlComponents(url) != nil; }
}
int HTTPRangeIO::open() {
    if (impl_->length >= 0) return 0;
    int64_t total = -1;
    std::vector<uint8_t> probe;
    const int result = impl_->fetch(0, 1, probe, total);
    if (result < 0) return result;
    impl_->length = total; impl_->position = 0;
    impl_->cacheBytes(0, std::move(probe));
    return 0;
}
int64_t HTTPRangeIO::size() const { return impl_->length; }
bool HTTPRangeIO::setReadBlockSize(int64_t bytes) {
    if (bytes < 16 * 1024 || bytes > kRangeBytes) return false;
    if (bytes != impl_->readBlockBytes) {
        impl_->readBlockBytes = bytes;
        impl_->cache.clear();
    }
    return true;
}
void HTTPRangeIO::setReadAdmission(std::function<bool()> admitted) {
    impl_->readAdmission = std::move(admitted);
}
int HTTPRangeIO::read(uint8_t* destination, int requested) {
    if (impl_->cancelled()) return AVERROR_EXIT;
    if (requested < 0 || (!destination && requested) || impl_->length < 0) return AVERROR(EINVAL);
    if (!requested) return 0;
    if (impl_->position >= impl_->length) return AVERROR_EOF;
    auto* cached = impl_->cachedAt(impl_->position);
    if (!cached) {
        const int64_t count = std::min(impl_->readBlockBytes, impl_->length - impl_->position);
        int64_t total = -1;
        std::vector<uint8_t> bytes;
        const int result = impl_->fetch(impl_->position, count, bytes, total);
        if (result < 0) return result;
        impl_->cacheBytes(impl_->position, std::move(bytes));
        cached = impl_->cachedAt(impl_->position);
    }
    if (!cached) return AVERROR(EIO);
    const size_t offset = (size_t)(impl_->position - cached->first);
    const size_t count = std::min<size_t>(requested, cached->bytes.size() - offset);
    if (!count) return AVERROR(EIO);
    memcpy(destination, cached->bytes.data() + offset, count);
    impl_->position += (int64_t)count;
    return (int)count;
}
int64_t HTTPRangeIO::seek(int64_t offset, int whence) {
    if (impl_->cancelled()) return AVERROR_EXIT;
    if (impl_->length < 0) return AVERROR(EINVAL);
    whence &= ~AVSEEK_FORCE;
    if (whence == AVSEEK_SIZE) return impl_->length;
    const int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? impl_->position :
                         whence == SEEK_END ? impl_->length : -1;
    if (base < 0 || (offset < 0 && offset < -base) || (offset > 0 && base > INT64_MAX - offset))
        return AVERROR(EINVAL);
    impl_->position = base + offset;
    return impl_->position;
}
} // namespace sp
