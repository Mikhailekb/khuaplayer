#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include "SPPersistentThumbnailStore.hpp"
#include <cstdio>
#include <cstdlib>
#include <set>

static int checks = 0;
static void check(bool value, const char *description) {
    if (!value) { fprintf(stderr, "FAIL %s\n", description); std::exit(1); }
    ++checks;
}
static NSData *encodedImage(size_t width = 8, size_t height = 4, CFStringRef type = CFSTR("public.jpeg")) {
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    memset(pixels.mutableBytes, 127, pixels.length);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4,
        space, kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *result = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)result, type, 1, nullptr);
    CGImageDestinationAddImage(destination, image, nullptr);
    check(CGImageDestinationFinalize(destination), "owned image fixture encodes");
    CFRelease(destination); CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(space);
    return result;
}
static NSURL *directory(NSURL *base, NSString *name) {
    NSURL *url = [base URLByAppendingPathComponent:name isDirectory:YES];
    check([NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions: @0700} error:nil], "owned private directory created");
    return url;
}
static NSURL *firstSample(NSURL *base) {
    for (NSURL *entry in [NSFileManager.defaultManager contentsOfDirectoryAtURL:base
        includingPropertiesForKeys:nil options:0 error:nil])
        if ([entry.pathExtension isEqualToString:@"kpv"]) return entry;
    return nil;
}

int main(int argc, const char **argv) { @autoreleasepool {
    check(argc == 2, "owned temporary directory supplied");
    NSURL *root = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
    check(spthumb::persistentPreviewBucket(-1, 5000000) == -1, "negative hover rejected");
    check(spthumb::persistentPreviewBucket(12000000, 5000000) == 10000000, "hover quantizes to preceding five-second bucket");
    check(spthumb::persistentPreviewPlan(0, 5000000).empty(), "unknown duration has no plan");
    check(spthumb::persistentPreviewPlan(10000000, 0).empty(), "invalid interval has no plan");
    auto shortPlan = spthumb::persistentPreviewPlan(7000000, 5000000);
    check(shortPlan == std::vector<int64_t>({0, 5000000}), "short video has zero and five second previews");
    auto plan = spthumb::persistentPreviewPlan(55000000, 5000000);
    check(plan.size() == 11 && std::set<int64_t>(plan.begin(), plan.end()).size() == 11, "whole duration has exactly one unique five-second target");
    check(*std::max_element(plan.begin(), plan.end()) == 50000000, "no target at or past EOF");
    check(plan[1] >= 20000000, "partial generation spreads coverage across the file");
    auto enormous = spthumb::persistentPreviewPlan(INT64_MAX, 5000000);
    check(enormous.size() == spthumb::kPersistentPreviewMaxSamples &&
        std::all_of(enormous.begin(), enormous.end(), [](int64_t v) { return v >= 0; }),
        "untrusted enormous duration has bounded memory without overflow");

    NSURL *cache = directory(root, @"media");
    NSData *image = encodedImage();
    {
        spthumb::PersistentThumbnailStore store(cache, 55000000, 5000000, 1, 17, 1920, 1080);
        check(store.available(), "private store opens");
        check(store.save(5000000, 4000000, 5000000, false, image), "valid encoded preview persists");
        auto loaded = store.load(5900000);
        check(loaded && loaded->bucketUs == 5000000 && loaded->keyUs == 4000000 &&
            loaded->resolvedTargetUs == 5000000 && [loaded->data isEqualToData:image],
            "same bucket restores exact image and actual frame metadata");
        check(!store.load(10000000), "unprepared bucket is not claimed present");
        check(store.alias(10000000, 4000000, 10000000), "one keyframe can persist another sampled bucket without network");
        check(store.load(10900000)->resolvedTargetUs == 10000000, "alias has independent verified target");
        check(!store.alias(15000000, 123456, 15000000), "unknown key cannot create an alias");
        check(!store.save(-1, 0, 0, false, image), "negative targets rejected");
        check(!store.save(60000000, 0, 0, false, image), "targets beyond duration rejected");
        check(!store.save(15000000, -1, 15000000, false, image), "negative actual frame rejected");
        check(!store.save(15000000, 0, 60000000, false, image), "out-of-bounds resolved target rejected");
        check(!store.save(15000000, 0, 15000000, true, image), "JPEG cannot masquerade as HDR HEIF");
        CFArrayRef formats = CGImageDestinationCopyTypeIdentifiers();
        const bool heifAvailable = formats && CFArrayContainsValue(formats,
            CFRangeMake(0, CFArrayGetCount(formats)), CFSTR("public.heic"));
        if (formats) CFRelease(formats);
        if (heifAvailable) {
            NSData *heif = encodedImage(64, 36, CFSTR("public.heic"));
            check(store.save(20000000, 18000000, 20000000, true, heif), "HDR HEIF cache format persists");
            auto restored = store.load(20900000);
            check(restored && restored->hdr && [restored->data isEqualToData:heif], "HEIF cache restores encoded bytes and HDR format marker");
            check(!store.save(25000000, 20000000, 25000000, false, heif), "HEIF cannot masquerade as SDR JPEG");
        } else printf("SKIP HEIF encoder is unavailable on this host.\n");
        check(!store.save(15000000, 0, 15000000, false, [@"source-url-and-secret" dataUsingEncoding:NSUTF8StringEncoding]),
            "non-image text cannot enter cache");
        check(!store.save(15000000, 0, 15000000, false,
            [NSMutableData dataWithLength:spthumb::kPersistentPreviewMaxImageBytes + 1]), "oversized payload rejected before decoding");
        check(!store.save(15000000, 0, 15000000, false, encodedImage(500, 500)), "oversized image dimensions rejected");
        NSURL *sample = firstSample(cache);
        struct stat info{}; check(stat(sample.path.fileSystemRepresentation, &info) == 0 &&
            (info.st_mode & 0777) == 0600, "image file permissions are private");
    }
    {
        spthumb::PersistentThumbnailStore store(cache, 55000000, 5000000, 1, 17, 1920, 1080);
        check(store.load(5000000).has_value(), "new session restores disk cache without the source");
        spthumb::PersistentThumbnailStore otherVideo(cache, 55000000, 5000000, 2, 17, 1920, 1080);
        spthumb::PersistentThumbnailStore otherID(cache, 55000000, 5000000, 1, 18, 1920, 1080);
        spthumb::PersistentThumbnailStore otherGeometry(cache, 55000000, 5000000, 1, 17, 1280, 720);
        check(!otherVideo.load(5000000) && !otherID.load(5000000) && !otherGeometry.load(5000000),
            "selected video stream, ID and geometry cannot mix cached frames");
    }
    NSURL *single = directory(root, @"single");
    spthumb::PersistentThumbnailStore store(single, 55000000, 5000000);
    check(store.save(0, 0, 0, false, image), "single sample saves");
    NSURL *sample = firstSample(single);
    NSMutableData *bytes = [[NSData dataWithContentsOfURL:sample] mutableCopy];
    ((uint8_t *)bytes.mutableBytes)[24] ^= 1;
    check([bytes writeToURL:sample atomically:NO], "owned metadata corruption installed");
    check(!store.load(0), "corrupted numeric metadata rejected by checksum");
    check(store.save(0, 0, 0, false, image), "corrupt private cache may be regenerated");
    bytes = [[NSData dataWithContentsOfURL:sample] mutableCopy];
    ((uint8_t *)bytes.mutableBytes)[bytes.length - 1] ^= 1;
    [bytes writeToURL:sample atomically:NO];
    check(!store.load(0), "corrupted encoded image rejected");
    check(store.save(0, 0, 0, false, image), "encoded image regenerates");
    NSURL *linked = [single URLByAppendingPathComponent:@"hardlink"];
    check(link(sample.path.fileSystemRepresentation, linked.path.fileSystemRepresentation) == 0, "owned hardlink fixture created");
    check(!store.load(0) && !store.save(0, 0, 0, false, image), "linked cache file is neither read nor replaced");
    unlink(linked.path.fileSystemRepresentation);
    chmod(sample.path.fileSystemRepresentation, 0644);
    check(!store.load(0) && !store.save(0, 0, 0, false, image), "publicly readable existing file is rejected");
    chmod(sample.path.fileSystemRepresentation, 0600);
    NSURL *target = [root URLByAppendingPathComponent:@"untouched"];
    NSData *marker = [@"untouched private value" dataUsingEncoding:NSUTF8StringEncoding];
    [marker writeToURL:target atomically:NO];
    unlink(sample.path.fileSystemRepresentation);
    check(symlink(target.path.fileSystemRepresentation, sample.path.fileSystemRepresentation) == 0, "owned symlink fixture created");
    check(!store.load(0) && !store.save(0, 0, 0, false, image), "symlink is neither read nor replaced");
    check([[NSData dataWithContentsOfURL:target] isEqualToData:marker], "symlink target unchanged");
    NSURL *linkDirectory = [root URLByAppendingPathComponent:@"directory-link"];
    symlink(cache.path.fileSystemRepresentation, linkDirectory.path.fileSystemRepresentation);
    spthumb::PersistentThumbnailStore throughLink(linkDirectory, 55000000, 5000000);
    check(!throughLink.available(), "symlink directory traversal rejected");
    NSURL *publicDirectory = directory(root, @"public"); chmod(publicDirectory.path.fileSystemRepresentation, 0755);
    spthumb::PersistentThumbnailStore publicStore(publicDirectory, 55000000, 5000000);
    check(!publicStore.available(), "public directory is not used for private images");
    spthumb::PersistentThumbnailStore invalid(cache, -1, 5000000);
    check(!invalid.available(), "invalid duration disables the disk store");
    printf("Persistent thumbnail store checks passed (%d assertions).\n", checks);
    return 0;
} }
