import Foundation
import Synchronization

struct ToolRun {
    struct Command: Sendable, Equatable {
        var tool: URL
        var arguments: [String]
    }

    struct Exit: Sendable {
        var status: Int32
        var stdout: SecretOutput
    }

    struct SecretOutput: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let data: Data
        var description: String { "SecretOutput(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    enum Failure: Error, Equatable {
        case launchFailed
        case timedOut
    }

    static func run(_ command: Command, timeout: Duration) async throws(Failure) -> Exit {
        let process = Process()
        process.executableURL = command.tool
        process.arguments = command.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let once = ResumeOnce<Result<Exit, Failure>>()

        let result = await withCheckedContinuation { continuation in
            once.install(continuation)
            let exitAndEOF = DispatchGroup()
            exitAndEOF.enter()
            exitAndEOF.enter()
            let output = Mutex(Data())
            let status = ExitStatus()
            process.terminationHandler = { process in
                status.set(process.terminationStatus)
                exitAndEOF.leave()
            }
            do {
                try process.run()
            } catch {
                exitAndEOF.leave()
                exitAndEOF.leave()
                once.resume(.failure(.launchFailed))
                return
            }
            let pid = process.processIdentifier
            // Drain on a dispatch thread, not the cooperative pool: the read blocks until EOF,
            // and a full pipe must not stall the tool.
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                output.withLock { $0 = data }
                exitAndEOF.leave()
            }
            // The deadline runs on its own clock, independent of the blocking read, so it fires
            // even while the tool is stuck (ADR-0004 point 3).
            let deadline = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, once.resume(.failure(.timedOut)) else { return }
                kill(pid, SIGTERM)
                try? await Task.sleep(for: .seconds(1))
                if status.code == nil { kill(pid, SIGKILL) }
            }
            exitAndEOF.notify(queue: .global()) {
                deadline.cancel()
                once.resume(.success(Exit(status: status.code!, stdout: SecretOutput(data: output.withLock { $0 }))))
            }
        }
        return try result.get()
    }

    private final class ExitStatus: Sendable {
        private let state = Mutex<Int32?>(nil)
        var code: Int32? { state.withLock { $0 } }
        func set(_ code: Int32) { state.withLock { $0 = code } }
    }
}

final class ResumeOnce<Value: Sendable>: Sendable {
    private let state = Mutex<CheckedContinuation<Value, Never>?>(nil)

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        state.withLock { $0 = continuation }
    }

    @discardableResult
    func resume(_ value: Value) -> Bool {
        guard let continuation = state.withLock({ slot -> CheckedContinuation<Value, Never>? in
            defer { slot = nil }
            return slot
        }) else { return false }
        continuation.resume(returning: value)
        return true
    }
}
