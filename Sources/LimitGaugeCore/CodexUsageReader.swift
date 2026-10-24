import Foundation
import Darwin

/// The read-only Codex usage view returned by the local Codex app server.
public struct CodexUsageReading: Sendable {
    public var snapshot: UsageSnapshot
    public var plan: Plan?

    public init(snapshot: UsageSnapshot, plan: Plan?) {
        self.snapshot = snapshot
        self.plan = plan
    }
}

/// Failures that are safe to show without revealing an app-server response.
public enum CodexUsageError: Error, Equatable, Sendable {
    case notInstalled
    case notSignedIn
    case timedOut
    case unavailable
    case invalidResponse
}

/// Reads the account limit snapshot through Codex's documented local app-server protocol.
/// It starts a short-lived server for each read and never receives, stores, or refreshes a
/// ChatGPT credential itself.
public struct CodexUsageReader: Sendable {
    static let timeout: Duration = .seconds(15)

    public init() {}

    public func read() async throws(CodexUsageError) -> CodexUsageReading {
        guard let executable = Self.executable() else { throw .notInstalled }
        return try await CodexAppServer(executable: executable, timeout: Self.timeout).read()
    }

    /// Avoids a shell so a user-controlled PATH is never interpreted as code. The conventional
    /// locations cover the supported installers; PATH is a final convenience for custom ones.
    static func executable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fixedPaths: [String] = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
    ) -> URL? {
        let manager = FileManager.default
        if let path = fixedPaths.first(where: { manager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.first == "/" {
            let path = String(directory) + "/codex"
            if manager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Internal to make the schema contract directly testable without spawning Codex.
    static func decode(_ data: Data, fetchedAt: Date = Date()) throws(CodexUsageError) -> CodexUsageReading {
        let response: RateLimitsResponse
        do {
            response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        } catch {
            throw .invalidResponse
        }
        guard let result = response.result else { throw response.error?.isAuthenticationFailure == true ? .notSignedIn : .unavailable }
        let buckets: [(String, RateLimitsResponse.Bucket)]
        if let multi = result.rateLimitsByLimitId, !multi.isEmpty {
            buckets = multi.keys.sorted().compactMap { key in multi[key].map { (key, $0) } }
        } else if let single = result.rateLimits {
            buckets = [(single.limitId ?? "codex", single)]
        } else {
            throw .invalidResponse
        }

        var limits: [RateLimit] = []
        var planType: String?
        for (key, bucket) in buckets {
            if planType == nil { planType = bucket.planType }
            for (_, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window else { continue }
                guard (0...100).contains(window.usedPercent), window.windowDurationMins > 0, window.resetsAt > 0 else {
                    throw .invalidResponse
                }
                let duration = Self.durationText(window.windowDurationMins)
                let id = bucket.limitId ?? key
                let label = bucket.limitName ?? (id == "codex" ? "Codex" : id)
                // The raw kind is a stable per-bucket/per-window identity. The menu layer turns
                // it into its user-facing Codex title, while warnings remain distinct.
                limits.append(RateLimit(kind: .other("codex:\(id):\(window.windowDurationMins)"),
                                        percent: window.usedPercent,
                                        resetsAt: Date(timeIntervalSince1970: TimeInterval(window.resetsAt)),
                                        displayTitle: "\(label) · \(duration)"))
            }
        }
        guard !limits.isEmpty else { throw .unavailable }
        return CodexUsageReading(snapshot: UsageSnapshot(limits: limits, fetchedAt: fetchedAt),
                                 plan: planType.map(Plan.init(rateLimitTier:)))
    }

    static func durationText(_ minutes: Int) -> String {
        if minutes % (24 * 60) == 0 {
            let days = minutes / (24 * 60)
            return "\(days) \(days == 1 ? "day" : "days")"
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        return "\(minutes) min"
    }
}

private struct RateLimitsResponse: Decodable {
    let result: Result?
    let error: RPCError?

    struct Result: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
    }

    struct Bucket: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        let secondary: Window?
        let planType: String?
    }

    struct Window: Decodable {
        let usedPercent: Int
        let windowDurationMins: Int
        let resetsAt: Int64
    }

    struct RPCError: Decodable {
        let code: Int?
        let message: String?

        var isAuthenticationFailure: Bool {
            let text = (message ?? "").lowercased()
            return text.contains("sign in") || text.contains("authentication") || text.contains("unauthenticated")
        }
    }
}

/// One blocking dispatch worker owns the process and both pipe ends. Nonblocking IO plus
/// a monotonic deadline keeps a silent/full pipe from hanging it; no callback can race EOF,
/// close a handle under a read, retain the process, or enqueue unbounded output.
struct CodexAppServer: Sendable {
    let executable: URL
    let timeout: Duration

    func read() async throws(CodexUsageError) -> CodexUsageReading {
        try await read(arguments: ["app-server", "--stdio"])
    }

    func read(arguments: [String]) async throws(CodexUsageError) -> CodexUsageReading {
        let result: Result<CodexUsageReading, CodexUsageError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result: Result<CodexUsageReading, CodexUsageError>
                do throws(CodexUsageError) {
                    result = .success(try self.run(arguments: arguments))
                } catch {
                    result = .failure(error)
                }
                continuation.resume(returning: result)
            }
        }
        return try result.get()
    }

    private func run(arguments: [String]) throws(CodexUsageError) -> CodexUsageReading {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var launched = false
        defer {
            // Only this worker touches these handles. Closing stdin asks Codex to shut down;
            // TERM then KILL also covers helpers that ignore EOF or stop consuming their pipes.
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            if launched { Self.stopAndReap(process) }
        }
        do {
            try process.run()
            launched = true
        } catch {
            throw .unavailable
        }
        // Close the parent's copies of the child ends. EOF now means the child's stdout
        // really closed; process termination is deliberately not used as a response signal.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let writer = input.fileHandleForWriting.fileDescriptor
        let reader = output.fileHandleForReading.fileDescriptor
        try Self.makeNonblocking(writer)
        try Self.makeNonblocking(reader)
        // A child can close stdin at any point. Suppress SIGPIPE only on this descriptor,
        // without changing the application's process-wide signal disposition.
        guard fcntl(writer, F_SETNOSIGPIPE, 1) != -1 else { throw .unavailable }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        try Self.send(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "limitgauge", "version": "1"], "capabilities": [:],
        ], to: writer, deadline: deadline)

        var initialized = false
        var buffer = Data()
        var totalBytes = 0
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Self.wait(reader, for: Int16(POLLIN), until: deadline)
            let count = Darwin.read(reader, &chunk, chunk.count)
            if count == 0 { throw buffer.isEmpty ? .unavailable : .invalidResponse }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw .unavailable
            }
            totalBytes += count
            // Count all stdout, including complete notifications, so even a newline flood
            // has a strict memory/work bound. There is no queue of unread chunks.
            guard totalBytes <= 1_048_576 else { throw .invalidResponse }
            buffer.append(contentsOf: chunk.prefix(count))
            while let end = buffer.firstIndex(of: 10) {
                guard ContinuousClock.now < deadline else { throw .timedOut }
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw .invalidResponse
                }
                guard let id = object["id"] as? Int else { continue } // notifications
                if id == 1 && !initialized {
                    if object["error"] != nil {
                        let error = try? JSONDecoder().decode(RateLimitsResponse.self, from: line).error
                        throw error?.isAuthenticationFailure == true ? .notSignedIn : .unavailable
                    }
                    guard object["result"] is [String: Any] else { throw .invalidResponse }
                    try Self.send(id: nil, method: "initialized", params: [:], to: writer, deadline: deadline)
                    try Self.send(id: 2, method: "account/rateLimits/read", params: [:], to: writer, deadline: deadline)
                    initialized = true
                } else if id == 2 && initialized {
                    return try CodexUsageReader.decode(line)
                }
            }
        }
    }

    private static func makeNonblocking(_ descriptor: Int32) throws(CodexUsageError) {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { throw .unavailable }
    }

    private static func send(id: Int?, method: String, params: [String: Any], to descriptor: Int32,
                             deadline: ContinuousClock.Instant) throws(CodexUsageError) {
        var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { request["id"] = id }
        guard var bytes = try? JSONSerialization.data(withJSONObject: request) else { throw .invalidResponse }
        bytes.append(10)
        var offset = 0
        while offset < bytes.count {
            try wait(descriptor, for: Int16(POLLOUT), until: deadline)
            let count = bytes.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count }
            else if count < 0, errno == EINTR || errno == EAGAIN { continue }
            else { throw .unavailable }
        }
    }

    /// poll reports HUP along with final buffered stdout. Always let read drain that data;
    /// only read's EOF ends a response-less stream. A monotonic deadline bounds every wait.
    private static func wait(_ descriptor: Int32, for events: Int16,
                             until deadline: ContinuousClock.Instant) throws(CodexUsageError) {
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let milliseconds = Double(remaining.seconds) * 1000 + Double(remaining.attoseconds) / 1e15
            var descriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&descriptor, 1, Int32(max(1, min(100, milliseconds.rounded(.up)))))
            if ready > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw .unavailable }
                return
            }
            if ready < 0, errno != EINTR { throw .unavailable }
        }
        throw .timedOut
    }

    private static func stopAndReap(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let grace = ContinuousClock.now.advanced(by: .seconds(1))
            while process.isRunning && ContinuousClock.now < grace { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        // Foundation owns waitpid for Process. Waiting here ensures no helper survives a
        // completed read and no termination callback or detached cleanup task retains it.
        process.waitUntilExit()
    }
}
