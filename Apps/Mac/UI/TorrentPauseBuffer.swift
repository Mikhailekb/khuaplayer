import Foundation

/// Keeps one bounded forward read alive while the owner permits buffering.
/// The owner cancels on seek, source replacement and cache reconfiguration.
/// The worker owns the playback/history window; this reader never advances that
/// anchor. Its URL must retain the worker's playback_consumer query parameter.
/// `filled` describes this request window, not an entire file or a guarantee that
/// the worker will retain those bytes after another reader changes its cache.
@MainActor
final class SPTorrentPauseBuffer {
    struct Identity: Hashable, Sendable {
        let hash: String
        let fileID: Int
        let sessionGeneration: UUID
    }

    enum State: Equatable, Sendable { case idle, filling, filled, waitingForCapacity, stopped, failed }

    /// Deliberately contains no server URL, credentials or raw network error.
    enum Failure: Equatable, Sendable {
        case invalidInput, authorization, redirect, invalidResponse, shortRead, transport
    }

    struct Snapshot: Equatable, Sendable {
        let identity: Identity?
        let state: State
        let receivedBytes: Int64
        let budgetBytes: Int64
        let rangeStart: Int64?
        let rangeEnd: Int64?
        let failure: Failure?

        static let idle = Snapshot(identity: nil, state: .idle, receivedBytes: 0,
                                   budgetBytes: 0, rangeStart: nil, rangeEnd: nil, failure: nil)
    }

    private(set) var snapshot: Snapshot = .idle
    var onChange: (@MainActor (Snapshot) -> Void)?

    private struct Window: Equatable {
        let identity: Identity
        let source: SPTorrentPauseSource
        let start: Int64
        let end: Int64 // Exclusive worker-approved forward bound.
        let fileLength: Int64
        var length: Int64 { end - start }
    }

    private var window: Window?
    private var coveredEndOffset: Int64 = 0 // Exclusive contiguous frontier.
    private var requestStartOffset: Int64 = 0
    private var requestGeneration = UUID()
    private var reader: SPTorrentPauseRead?
    private struct RequestContext {
        let id: UUID
        let window: Window
        let start: Int64
        let end: Int64 // Exclusive HTTP range end, even if the desired window grows.

        func belongs(to next: Window) -> Bool {
            window.identity == next.identity && window.source == next.source && window.fileLength == next.fileLength &&
            next.start >= window.start
        }

        func matches(_ proof: SPTorrentPrefetchCapacityStop) -> Bool {
            proof.requestID == id && proof.fileID == window.identity.fileID && proof.revision > 0 &&
            proof.rangeStart == start && proof.rangeEnd == end && proof.nextOffset >= start && proof.nextOffset < end
        }
    }
    private struct InterruptedRead {
        let request: RequestContext
        let nextOffset: Int64 // Only bytes from a response whose range headers were validated.
    }
    private var requestContext: RequestContext?
    private var interruptedRead: InterruptedRead?
    private var pendingCapacityStop: SPTorrentPrefetchCapacityStop?

    deinit { reader?.cancel() }

    /// Start is idempotent for a filling or filled window. Failures remain sticky
    /// for the source until stop/start or cancel; advancing playback cannot retry
    /// them. Only an exact worker capacity proof permits automatic continuation
    /// after an interrupted response. The upper bound comes from worker policy: retained
    /// history and already-read ahead bytes
    /// have already consumed capacity. Never allocate another cache-sized window
    /// after `offset`. Explicit stop/start resumes a stopped window's suffix.
    func start(identity: Identity, streamURL: URL, offset: Int64,
               fileLength: Int64, forwardEndOffset: Int64,
               capacityStop: SPTorrentPrefetchCapacityStop? = nil) {
        guard !identity.hash.isEmpty, identity.fileID >= 0,
              offset >= 0, fileLength > 0, offset <= fileLength,
              forwardEndOffset >= 0, forwardEndOffset <= fileLength,
              let source = SPTorrentPauseSource(streamURL) else {
            invalidateRead()
            window = nil
            coveredEndOffset = 0
            publish(Snapshot(identity: identity, state: .failed, receivedBytes: 0,
                             budgetBytes: 0, rangeStart: nil, rangeEnd: nil, failure: .invalidInput))
            return
        }
        // Decoder read-ahead may already reach/past the approved upper bound.
        // That is an empty fill, not permission to move the retention anchor.
        let next = Window(identity: identity, source: source, start: offset,
                          end: max(offset, forwardEndOffset), fileLength: fileLength)
        // The worker can finish its response before Foundation delivers the
        // terminal callback. Keep proof for this exact request until its byte
        // count and validated response are available; it cannot authorize a
        // different request, source, file or playback session.
        if let proof = capacityStop, let request = requestContext,
           request.belongs(to: next), request.matches(proof) { pendingCapacityStop = proof }
        if let proof = capacityStop, let interrupted = interruptedRead,
           interrupted.request.belongs(to: next), interrupted.request.matches(proof),
           window.map({ next.start >= $0.start }) == true,
           proof.nextOffset == interrupted.nextOffset {
            interruptedRead = nil
            pendingCapacityStop = nil
            window = next
            coveredEndOffset = next.start <= interrupted.nextOffset ? min(interrupted.nextOffset, next.end) : next.start
            acceptCapacityStop(next)
            return
        }
        if snapshot.state == .failed, let previous = window,
           previous.identity == identity, previous.source == source, previous.fileLength == fileLength { return }
        if next == window {
            if snapshot.state == .filling || snapshot.state == .filled || snapshot.state == .waitingForCapacity ||
               snapshot.state == .failed { return }
        }

        let previous = window
        let observedEnd = reader.map { requestStartOffset + $0.receivedByteCount() } ?? coveredEndOffset
        var actualEnd = max(coveredEndOffset, observedEnd)
        let sameSource = previous.map {
            $0.identity == next.identity && $0.source == next.source && $0.fileLength == next.fileLength &&
            next.start >= $0.start
        } ?? false
        let keepRead = sameSource && next.start <= actualEnd && reader != nil && snapshot.state == .filling &&
                       previous.map { next.end >= $0.end } == true && actualEnd < next.end
        if !keepRead {
            let hadRead = reader != nil
            let received = invalidateRead()
            // Cancellation returns its final locked count. Bytes accepted
            // between the observation above and cancellation also remain part
            // of the reusable prefix when changing the approved upper bound.
            if hadRead { actualEnd = max(actualEnd, requestStartOffset + received) }
        }
        let reuse = sameSource && next.start <= actualEnd
        let nextCoveredEnd = reuse ? min(actualEnd, next.end) : next.start
        window = next
        coveredEndOffset = nextCoveredEnd
        if coveredEndOffset >= next.end {
            publish(next, state: sameSource && snapshot.state == .waitingForCapacity ? .waitingForCapacity : .filled)
            return
        }
        // A growing target keeps the original finite request. On success its
        // terminal callback starts only the newly approved suffix. A shrinking
        // target still cancels immediately, before any replacement read.
        if keepRead { publish(next, state: .filling); return }

        beginRead(next)
    }

    private func beginRead(_ next: Window) {
        requestStartOffset = coveredEndOffset
        let generation = UUID()
        requestGeneration = generation
        interruptedRead = nil
        pendingCapacityStop = nil
        requestContext = RequestContext(id: generation, window: next, start: coveredEndOffset, end: next.end)
        let plan = SPTorrentPauseRead.Plan(source: next.source, requestID: generation, start: coveredEndOffset,
                                         end: next.end - 1, fileLength: next.fileLength)
        let read = SPTorrentPauseRead(plan: plan) { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event, generation: generation) }
        }
        reader = read
        publish(next, state: .filling)
        // onChange may synchronously stop or replace the request.
        if requestGeneration == generation, reader === read { read.start() }
    }

    private func acceptCapacityStop(_ next: Window) {
        let generation = requestGeneration
        publish(next, state: .waitingForCapacity)
        // A proof-bearing ACK is computed after the quota stop. It may already
        // grant new credit even if no numeric shrink was observed by the owner.
        // Each continuation gets a new nonce, so replaying this ACK cannot retry
        // a later interruption. Stop/cancel from onChange remains dominant.
        if requestGeneration == generation, window == next, snapshot.state == .waitingForCapacity,
           coveredEndOffset < next.end { beginRead(next) }
    }

    /// Stop immediately, preserving only the response-validated contiguous prefix
    /// of this same window. No response body is retained by this object.
    func stop() {
        guard let window else { return }
        let hadRead = reader != nil
        let received = invalidateRead()
        if hadRead { coveredEndOffset = min(window.end, max(coveredEndOffset, requestStartOffset + received)) }
        if snapshot.state != .filled { publish(window, state: .stopped) }
    }

    /// Seek/source changes invalidate the cache-coverage assumption.
    func cancel() {
        invalidateRead()
        window = nil
        coveredEndOffset = 0
        requestStartOffset = 0
        publish(.idle)
    }

    func reset() { cancel() }

    @discardableResult
    private func invalidateRead() -> Int64 {
        requestGeneration = UUID()
        let received = reader?.cancel() ?? 0
        reader = nil
        requestContext = nil
        interruptedRead = nil
        pendingCapacityStop = nil
        return received
    }

    private func receive(_ event: SPTorrentPauseRead.Event, generation: UUID) {
        guard requestGeneration == generation, let window else { return }
        switch event {
        case .progress(let received):
            coveredEndOffset = min(window.end, max(coveredEndOffset, requestStartOffset + received))
            publish(window, state: .filling)
        case .finished(let received, let failure):
            let request = requestContext
            let validated = reader?.responseWasValidated() ?? false
            let proof = pendingCapacityStop
            coveredEndOffset = min(window.end, max(coveredEndOffset, requestStartOffset + received))
            reader = nil
            requestContext = nil
            pendingCapacityStop = nil
            // Ignore any queued progress/completion after this terminal event.
            requestGeneration = UUID()
            if let request, validated, failure == .shortRead || failure == .transport,
               received < request.end - request.start {
                let interrupted = InterruptedRead(request: request, nextOffset: request.start + received)
                interruptedRead = interrupted
                if let proof, request.matches(proof), proof.nextOffset == interrupted.nextOffset {
                    interruptedRead = nil
                    acceptCapacityStop(window)
                    return
                }
            }
            if failure == nil, coveredEndOffset < window.end {
                beginRead(window)
            } else {
                publish(window, state: failure == nil ? .filled : .failed, failure: failure)
            }
        }
    }

    private func publish(_ window: Window, state: State, failure: Failure? = nil) {
        publish(Snapshot(identity: window.identity, state: state, receivedBytes: max(coveredEndOffset - window.start, 0),
                         budgetBytes: window.length, rangeStart: window.start,
                         rangeEnd: window.length > 0 ? window.end - 1 : nil, failure: failure))
    }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }
}

/// The sanitized source is private and is never included in progress/errors.
private struct SPTorrentPauseSource: Equatable, Sendable {
    let url: URL
    let authorization: String?
    let origin: Origin
    let playbackConsumer: String?

    struct Origin: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    init?(_ input: URL) {
        guard var parts = URLComponents(url: input, resolvingAgainstBaseURL: false),
              parts.fragment == nil, let origin = Origin(input) else { return nil }
        let consumers = parts.queryItems?.filter { $0.name == "playback_consumer" } ?? []
        guard consumers.count <= 1 else { return nil }
        if let item = consumers.first {
            guard let value = item.value, !value.isEmpty else { return nil }
            playbackConsumer = value
        } else { playbackConsumer = nil }
        if let user = parts.user {
            // A colon in the username cannot be represented in HTTP Basic auth.
            guard !user.contains(":"), !user.contains("\r"), !user.contains("\n"),
                  !(parts.password ?? "").contains("\r"), !(parts.password ?? "").contains("\n") else { return nil }
            authorization = "Basic " + Data((user + ":" + (parts.password ?? "")).utf8).base64EncodedString()
        } else {
            guard parts.password == nil else { return nil }
            authorization = nil
        }
        parts.user = nil
        parts.password = nil
        // The worker may shrink this consumer's budget while a long range is
        // active. Prefetch reads obey that dynamic bound; normal Core reads
        // remain free to probe container metadata elsewhere in the file.
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "playback_prefetch" } +
                           [URLQueryItem(name: "playback_prefetch", value: "1")]
        parts.queryItems = parts.queryItems?.filter { $0.name != "playback_prefetch_request" }
        guard let url = parts.url else { return nil }
        self.url = url
        self.origin = origin
    }

    func preservesPlaybackConsumer(_ parts: URLComponents) -> Bool {
        let prefetch = parts.queryItems?.filter { $0.name == "playback_prefetch" } ?? []
        guard prefetch.count == 1, prefetch[0].value == "1" else { return false }
        let consumers = parts.queryItems?.filter { $0.name == "playback_consumer" } ?? []
        if let playbackConsumer { return consumers.count == 1 && consumers[0].value == playbackConsumer }
        return consumers.isEmpty
    }
}

/// URLSession delivers small chunks and this delegate only counts them. It never
/// appends Data, creates a download task/temp file, or caches a response. Mutable
/// state is lock-protected because main-actor cancellation races delegate calls.
private final class SPTorrentPauseRead: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Plan: Sendable {
        let source: SPTorrentPauseSource
        let requestID: UUID
        let start: Int64
        let end: Int64
        let fileLength: Int64
        var length: Int64 { end - start + 1 }
    }
    enum Event: Sendable {
        case progress(Int64)
        case finished(Int64, SPTorrentPauseBuffer.Failure?)
    }

    private let plan: Plan
    private let onEvent: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var received: Int64 = 0
    private var validated = false
    private var terminal = false
    private var lastProgressAt: TimeInterval = 0
    private var redirects = 0

    init(plan: Plan, onEvent: @escaping @Sendable (Event) -> Void) {
        self.plan = plan
        self.onEvent = onEvent
    }

    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request(url: plan.source.url))
        lock.lock()
        if terminal {
            lock.unlock()
            session.invalidateAndCancel()
            return
        }
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    @discardableResult
    func cancel() -> Int64 {
        lock.lock()
        terminal = true
        let count = received
        let session = self.session
        let task = self.task
        self.session = nil
        self.task = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        return count
    }

    func receivedByteCount() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func responseWasValidated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return validated
    }

    private func request(url: URL) -> URLRequest {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "playback_prefetch_request" } +
                           [URLQueryItem(name: "playback_prefetch_request", value: plan.requestID.uuidString)]
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("bytes=\(plan.start)-\(plan.end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(plan.source.authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private func finish(_ failure: SPTorrentPauseBuffer.Failure?) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        let count = received
        let session = self.session
        let task = self.task
        self.session = nil
        self.task = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        onEvent(.finished(count, failure))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              let url = response.url, SPTorrentPauseSource.Origin(url) == plan.source.origin else {
            completionHandler(.cancel)
            finish(.invalidResponse)
            return
        }
        guard response.statusCode == 206 else {
            completionHandler(.cancel)
            finish([401, 403].contains(response.statusCode) ? .authorization : .invalidResponse)
            return
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard encoding == nil || encoding == "identity",
              let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              Self.validRange(contentRange, plan: plan) else {
            completionHandler(.cancel)
            finish(.invalidResponse)
            return
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length"),
           Self.decimal(length.trimmingCharacters(in: .whitespacesAndNewlines)) != plan.length {
            completionHandler(.cancel)
            finish(.invalidResponse)
            return
        }
        lock.lock()
        let allow = !terminal
        if allow { validated = true }
        lock.unlock()
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !terminal, validated else { lock.unlock(); return }
        let remaining = plan.length - received
        guard Int64(data.count) <= remaining else {
            lock.unlock()
            finish(.invalidResponse)
            return
        }
        received += Int64(data.count)
        let count = received
        let complete = received == plan.length
        let now = ProcessInfo.processInfo.systemUptime
        let report = !complete && now - lastProgressAt >= 0.1
        if report { lastProgressAt = now }
        lock.unlock()
        if complete { finish(nil) }
        else if report { onEvent(.progress(count)) }
        // `data` is released when the callback returns; no body storage exists.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let count = received
        let hasResponse = validated
        lock.unlock()
        if error != nil { finish(.transport) }
        else { finish(hasResponse && count == plan.length ? nil : .shortRead) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = newRequest.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              plan.source.preservesPlaybackConsumer(parts),
              parts.queryItems?.filter({ $0.name == "playback_prefetch_request" }).map(\.value) == [plan.requestID.uuidString],
              SPTorrentPauseSource.Origin(url) == plan.source.origin else {
            completionHandler(nil)
            finish(.redirect)
            return
        }
        lock.lock()
        redirects += 1
        let allow = !terminal && redirects <= 5
        lock.unlock()
        guard allow else { completionHandler(nil); finish(.redirect); return }
        // Preserve the bounded range and explicit authorization only after the
        // same-origin/consumer checks. Dropping the consumer would turn this
        // forward read into an unmanaged moving cache window.
        completionHandler(request(url: url))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.authorization)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }

    private static func decimal(_ value: String) -> Int64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(value)
    }

    private static func validRange(_ value: String, plan: Plan) -> Bool {
        let pieces = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return false }
        let extent = pieces[1].split(separator: "/", omittingEmptySubsequences: false)
        guard extent.count == 2, decimal(String(extent[1])) == plan.fileLength else { return false }
        let bounds = extent[0].split(separator: "-", omittingEmptySubsequences: false)
        return bounds.count == 2 && decimal(String(bounds[0])) == plan.start && decimal(String(bounds[1])) == plan.end
    }
}
