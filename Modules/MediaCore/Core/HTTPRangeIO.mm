#include "HTTPRangeIO.hpp"
#import <Foundation/Foundation.h>

extern "C" {
#include <libavformat/avio.h>
#include <libavutil/error.h>
}

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <string_view>
#include <vector>

namespace {
constexpr int64_t kRangeBytes = 256 * 1024;

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
    BOOL headersValidated, acceptedEmpty;
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
    ContentRange range;
    const BOOL validRange = parseContentRange([http valueForHTTPHeaderField:@"Content-Range"], range);
    if (http.statusCode == 416 && validRange && range.empty && state->knownTotal < 0) {
        state->total = 0; state->acceptedEmpty = YES;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (http.statusCode != 206) {
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
        if (error) state->result = AVERROR(error.code == NSURLErrorTimedOut ? ETIMEDOUT : EIO);
        else if (!state->headersValidated || state->body.length != (NSUInteger)state->expectedLength)
            state->result = AVERROR_INVALIDDATA;
    }
    dispatch_semaphore_signal(state->completed);
}
@end

namespace sp {
struct HTTPRangeIO::Impl {
    std::function<bool()> interrupted;
    std::function<void(bool)> waitingChanged;
    double timeout;
    NSURL* url = nil;
    NSString* authorization = nil;
    NSString* validator = nil;
    SPHTTPRangeTransport* transport = nil;
    NSURLSession* session = nil;
    int64_t length = -1, position = 0, cachePosition = -1;
    std::vector<uint8_t> cache;

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
            if (cancelled()) return AVERROR_EXIT;
            if (!url || !session || start < 0 || count <= 0 || count > kRangeBytes || start > INT64_MAX - count)
                return AVERROR(EINVAL);
            struct WaitingScope {
                std::function<void(bool)>& changed;
                bool announced = false;
                explicit WaitingScope(std::function<void(bool)>& callback) : changed(callback) {}
                void announce() {
                    if (!announced && changed) { announced = true; changed(true); }
                }
                ~WaitingScope() { if (announced) changed(false); }
            } waiting(waitingChanged);
            NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url
                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
            [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", (long long)start,
                (long long)(start + count - 1)] forHTTPHeaderField:@"Range"];
            [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
            if (authorization) [request setValue:authorization forHTTPHeaderField:@"Authorization"];
            if (validator) [request setValue:validator forHTTPHeaderField:@"If-Range"];
            SPHTTPRangeRequest* state = [SPHTTPRangeRequest new];
            state->first = start; state->last = start + count - 1;
            state->knownTotal = length; state->expectedValidator = validator;
            NSURLSessionDataTask* task = [session dataTaskWithRequest:request];
            [transport addRequest:state task:task];
            [task resume];
            const auto started = std::chrono::steady_clock::now();
            const auto deadline = started + std::chrono::duration<double>(timeout);
            while (dispatch_semaphore_wait(state->completed, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC))) {
                if (cancelled()) { [task cancel]; return AVERROR_EXIT; }
                if (std::chrono::steady_clock::now() >= deadline) { [task cancel]; return AVERROR(ETIMEDOUT); }
                if (std::chrono::steady_clock::now() - started >= std::chrono::milliseconds(250))
                    waiting.announce();
            }
            if (cancelled()) return AVERROR_EXIT;
            if (state->result < 0) return state->result;
            receivedTotal = state->total;
            if (state->validator.length) validator = state->validator;
            output.resize(state->body.length);
            if (!output.empty()) memcpy(output.data(), state->body.bytes, output.size());
            return 0;
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
    const int result = impl_->fetch(0, 1, impl_->cache, total);
    if (result < 0) return result;
    impl_->length = total; impl_->position = 0; impl_->cachePosition = 0;
    return 0;
}
int64_t HTTPRangeIO::size() const { return impl_->length; }
int HTTPRangeIO::read(uint8_t* destination, int requested) {
    if (impl_->cancelled()) return AVERROR_EXIT;
    if (requested < 0 || (!destination && requested) || impl_->length < 0) return AVERROR(EINVAL);
    if (!requested) return 0;
    if (impl_->position >= impl_->length) return AVERROR_EOF;
    const int64_t cached = impl_->cachePosition < 0 ? -1 : impl_->position - impl_->cachePosition;
    if (impl_->cachePosition < 0 || cached < 0 || cached >= (int64_t)impl_->cache.size()) {
        const int64_t count = std::min(kRangeBytes, impl_->length - impl_->position);
        int64_t total = -1;
        const int result = impl_->fetch(impl_->position, count, impl_->cache, total);
        if (result < 0) return result;
        impl_->cachePosition = impl_->position;
    }
    const size_t offset = (size_t)(impl_->position - impl_->cachePosition);
    const size_t count = std::min<size_t>(requested, impl_->cache.size() - offset);
    if (!count) return AVERROR(EIO);
    memcpy(destination, impl_->cache.data() + offset, count);
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
