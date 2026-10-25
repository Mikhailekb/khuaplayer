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
    // Background metadata readers may request smaller validated windows. Main
    // playback keeps the default256KiB. Serialized owner access only; accepted
    // sizes are16...256KiB and changing the size drops only this local LRU.
    bool setReadBlockSize(int64_t bytes);
    // Independent background readers can yield their network lane without
    // returning a transport error to AVIO. The owner installs this before use;
    // the predicate must be fast, thread-safe and remain valid for this reader.
    // Revocation cancels any pending request; regrant resumes the exact range.
    // Time spent denied does not consume the request's active-I/O timeout.
    void setReadAdmission(std::function<bool()> admitted);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace sp
