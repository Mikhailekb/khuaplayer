#pragma once

// Worker-owned persistent preview samples. A sample is an immutable small image
// plus fixed numeric metadata; no source locations or credentials are written.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <optional>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace spthumb {

inline constexpr int64_t kPersistentPreviewIntervalUs = 5000000;
inline constexpr size_t kPersistentPreviewMaxSamples = 100000;
inline constexpr size_t kPersistentPreviewMaxImageBytes = 2 * 1024 * 1024;

inline int64_t persistentPreviewBucket(int64_t targetUs, int64_t intervalUs) {
    if (targetUs < 0 || intervalUs <= 0) return -1;
    return targetUs / intervalUs * intervalUs;
}

inline std::vector<int64_t> persistentPreviewPlan(int64_t durationUs, int64_t intervalUs) {
    std::vector<int64_t> targets;
    if (durationUs <= 0 || intervalUs <= 0) return targets;
    const uint64_t count = std::min<uint64_t>(
        (uint64_t)(durationUs - 1) / (uint64_t)intervalUs + 1, kPersistentPreviewMaxSamples);
    unsigned bits = 0;
    while ((uint64_t(1) << bits) < count) ++bits;
    std::vector<std::pair<uint64_t, int64_t>> order;
    order.reserve((size_t)count);
    for (uint64_t i = 0; i < count; ++i) {
        uint64_t reversed = 0;
        for (unsigned b = 0; b < bits; ++b)
            if (i & (uint64_t(1) << b)) reversed |= uint64_t(1) << (bits - b - 1);
        order.emplace_back(reversed, (int64_t)i * intervalUs);
    }
    std::stable_sort(order.begin(), order.end());
    targets.reserve(order.size());
    for (const auto &entry : order) targets.push_back(entry.second);
    return targets;
}

struct PersistentPreview {
    int64_t bucketUs = 0, keyUs = 0, resolvedTargetUs = 0;
    bool hdr = false;
    NSData *data = nil;
};

class PersistentThumbnailStore {
    static constexpr size_t headerBytes = 64;
    int directory_ = -1;
    int64_t durationUs_, intervalUs_;
    int streamIndex_, streamId_, width_, height_;
    std::map<int64_t, int64_t> knownKeyBuckets_;

    static uint64_t checksum(const uint8_t *bytes, size_t length,
                              uint64_t value = 14695981039346656037ULL) {
        for (size_t i = 0; i < length; ++i) { value ^= bytes[i]; value *= 1099511628211ULL; }
        return value;
    }
    static void put64(uint8_t *where, uint64_t value) {
        for (unsigned i = 0; i < 8; ++i) where[i] = (uint8_t)(value >> (i * 8));
    }
    static uint64_t get64(const uint8_t *where) {
        uint64_t value = 0;
        for (unsigned i = 0; i < 8; ++i) value |= uint64_t(where[i]) << (i * 8);
        return value;
    }
    static uint64_t recordChecksum(std::array<uint8_t, headerBytes> header, NSData *data) {
        put64(header.data() + 48, 0);
        return checksum(static_cast<const uint8_t *>(data.bytes), data.length,
                        checksum(header.data(), header.size()));
    }
    static bool regularPrivate(int fd, struct stat &info) {
        return fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == getuid() &&
               info.st_nlink == 1 && (info.st_mode & 077) == 0;
    }
    static bool transfer(int fd, void *bytes, size_t length, bool writing) {
        auto *cursor = static_cast<uint8_t *>(bytes);
        size_t completed = 0;
        while (completed < length) {
            const ssize_t count = writing ? write(fd, cursor + completed, length - completed)
                                          : read(fd, cursor + completed, length - completed);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) return false;
            completed += (size_t)count;
        }
        return true;
    }
    static int openDirectory(NSURL *directory) {
        if (!directory.isFileURL || !directory.path.isAbsolutePath) return -1;
        int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (fd < 0) return -1;
        for (NSString *component in directory.path.pathComponents) {
            if ([component isEqualToString:@"/"]) continue;
            const char *utf8 = component.UTF8String;
            if ([component isEqualToString:@"."] || [component isEqualToString:@".."] || !utf8 ||
                strlen(utf8) != [component lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) { close(fd); return -1; }
            const int next = openat(fd, component.fileSystemRepresentation,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            close(fd);
            if (next < 0) return -1;
            fd = next;
        }
        struct stat info;
        if (fstat(fd, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != getuid() ||
            (info.st_mode & 077) != 0) { close(fd); return -1; }
        return fd;
    }
    std::array<char, 112> filename(int64_t bucketUs) const {
        std::array<char, 112> name{};
        snprintf(name.data(), name.size(), "v%u-i%u-%ux%u-sample-%019lld.kpv", (unsigned)streamIndex_,
                 (unsigned)streamId_, (unsigned)width_, (unsigned)height_, (long long)bucketUs);
        return name;
    }
    bool validTime(int64_t time) const { return time >= 0 && time <= durationUs_; }
    void rememberKey(int64_t keyUs, int64_t bucketUs) {
        if (knownKeyBuckets_.size() >= kPersistentPreviewMaxSamples && !knownKeyBuckets_.count(keyUs))
            knownKeyBuckets_.erase(knownKeyBuckets_.begin());
        knownKeyBuckets_[keyUs] = bucketUs;
    }
    static bool validImage(NSData *data, bool hdr) {
        if (!data || data.length == 0 || data.length > kPersistentPreviewMaxImageBytes) return false;
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
        if (!source) return false;
        CFStringRef type = CGImageSourceGetType(source);
        const bool format = type && (hdr
            ? (CFEqual(type, CFSTR("public.heic")) || CFEqual(type, CFSTR("public.heif")))
            : CFEqual(type, CFSTR("public.jpeg")));
        CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
        bool bounded = false;
        if (properties) {
            NSNumber *width = (__bridge NSNumber *)CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
            NSNumber *height = (__bridge NSNumber *)CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
            bounded = [width isKindOfClass:NSNumber.class] && [height isKindOfClass:NSNumber.class] &&
                width.longLongValue > 0 && height.longLongValue > 0 &&
                width.longLongValue <= 384 && height.longLongValue <= 384;
            CFRelease(properties);
        }
        CFRelease(source);
        return format && bounded;
    }
public:
    PersistentThumbnailStore(NSURL *directory, int64_t durationUs, int64_t intervalUs,
                             int streamIndex = -1, int streamId = 0, int width = 0, int height = 0)
        : durationUs_(durationUs), intervalUs_(intervalUs), streamIndex_(streamIndex),
          streamId_(streamId), width_(width), height_(height) {
        if (durationUs > 0 && intervalUs > 0 && streamIndex >= -1 && width >= 0 && height >= 0)
            directory_ = openDirectory(directory);
    }
    ~PersistentThumbnailStore() { if (directory_ >= 0) close(directory_); }
    PersistentThumbnailStore(const PersistentThumbnailStore &) = delete;
    PersistentThumbnailStore &operator=(const PersistentThumbnailStore &) = delete;
    bool available() const { return directory_ >= 0; }

    std::optional<PersistentPreview> load(int64_t targetUs) {
        const int64_t bucket = persistentPreviewBucket(targetUs, intervalUs_);
        if (directory_ < 0 || !validTime(bucket)) return std::nullopt;
        const auto name = filename(bucket);
        const int fd = openat(directory_, name.data(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) return std::nullopt;
        struct Close { int fd; ~Close() { close(fd); } } closeFile{fd};
        struct stat info;
        if (!regularPrivate(fd, info) || info.st_size <= (int64_t)headerBytes ||
            info.st_size > (int64_t)(headerBytes + kPersistentPreviewMaxImageBytes)) return std::nullopt;
        std::array<uint8_t, headerBytes> header{};
        if (!transfer(fd, header.data(), header.size(), false) || memcmp(header.data(), "KINOPRV1", 8) != 0 ||
            get64(header.data() + 8) != 1 || get64(header.data() + 16) != (uint64_t)bucket) return std::nullopt;
        const uint64_t key = get64(header.data() + 24), resolved = get64(header.data() + 32);
        const uint64_t length = get64(header.data() + 40), flags = get64(header.data() + 56);
        if (key > (uint64_t)durationUs_ || resolved > (uint64_t)durationUs_ || flags > 1 || length == 0 ||
            length > kPersistentPreviewMaxImageBytes || length + headerBytes != (uint64_t)info.st_size) return std::nullopt;
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
        if (!data || !transfer(fd, data.mutableBytes, (size_t)length, false) ||
            recordChecksum(header, data) != get64(header.data() + 48) ||
            !validImage(data, flags == 1)) return std::nullopt;
        rememberKey((int64_t)key, bucket);
        return PersistentPreview{bucket, (int64_t)key, (int64_t)resolved, flags == 1, data};
    }

    bool save(int64_t targetUs, int64_t keyUs, int64_t resolvedTargetUs, bool hdr, NSData *data) {
        const int64_t bucket = persistentPreviewBucket(targetUs, intervalUs_);
        if (directory_ < 0 || !validTime(bucket) || !validTime(keyUs) || !validTime(resolvedTargetUs) ||
            !validImage(data, hdr)) return false;
        const auto finalName = filename(bucket);
        struct stat existing;
        if (fstatat(directory_, finalName.data(), &existing, AT_SYMLINK_NOFOLLOW) == 0) {
            if (!S_ISREG(existing.st_mode) || existing.st_uid != getuid() || existing.st_nlink != 1 ||
                (existing.st_mode & 077) != 0) return false;
        } else if (errno != ENOENT) return false;
        std::array<char, 128> temporary{};
        // O_EXCL prevents following or replacing another producer's temporary.
        snprintf(temporary.data(), temporary.size(), ".sample-%019lld-%d-%llu.tmp", (long long)bucket,
                 getpid(), (unsigned long long)arc4random_uniform(UINT32_MAX));
        const int fd = openat(directory_, temporary.data(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) return false;
        std::array<uint8_t, headerBytes> header{};
        memcpy(header.data(), "KINOPRV1", 8);
        put64(header.data() + 8, 1); put64(header.data() + 16, (uint64_t)bucket);
        put64(header.data() + 24, (uint64_t)keyUs); put64(header.data() + 32, (uint64_t)resolvedTargetUs);
        put64(header.data() + 40, data.length);
        put64(header.data() + 56, hdr ? 1 : 0);
        put64(header.data() + 48, recordChecksum(header, data));
        bool ok = transfer(fd, header.data(), header.size(), true) &&
                  transfer(fd, const_cast<void *>(data.bytes), data.length, true);
        if (close(fd) != 0) ok = false;
        if (ok) ok = renameat(directory_, temporary.data(), directory_, finalName.data()) == 0;
        if (!ok) unlinkat(directory_, temporary.data(), 0);
        if (ok) rememberKey(keyUs, bucket);
        return ok;
    }

    bool alias(int64_t targetUs, int64_t keyUs, int64_t resolvedTargetUs) {
        const auto found = knownKeyBuckets_.find(keyUs);
        if (found == knownKeyBuckets_.end()) return false;
        const auto image = load(found->second);
        return image && save(targetUs, keyUs, resolvedTargetUs, image->hdr, image->data);
    }
};
} // namespace spthumb
