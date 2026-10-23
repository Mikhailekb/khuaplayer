// Seekable, bounded HTTP input for FFmpeg builds which only enable file I/O.
// Reads are serialized by the demux owner; cancellation may arrive on any thread.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace sp {

class HTTPRangeIO {
public:
    HTTPRangeIO(std::string url, std::function<bool()> interrupted,
                double requestTimeoutSeconds = 120.0,
                std::function<void(bool)> waitingChanged = {});
    ~HTTPRangeIO();
    HTTPRangeIO(const HTTPRangeIO&) = delete;
    HTTPRangeIO& operator=(const HTTPRangeIO&) = delete;

    static bool supportsURL(const std::string& url);
    int open();
    int read(uint8_t* destination, int requested);
    int64_t seek(int64_t offset, int whence);
    int64_t size() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace sp
