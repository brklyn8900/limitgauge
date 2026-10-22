import Foundation
import Synchronization

struct ToolRun {
    struct Command: Sendable, Equatable {
        var tool: URL
        var arguments: [String]
    }

    struct Exit: Sendable {
        var status: Int32
        /// The tool's stdout. May hold a secret: callers parse it and never log it.
        var stdout: Data
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
        let child = Child(process)
        let once = ResumeOnce<Result<Exit, Failure>>()

        let result = await withCheckedContinuation { continuation in
            once.install(continuation)
            let exitAndEOF = DispatchGroup()
            exitAndEOF.enter()
            exitAndEOF.enter()
            let output = Mutex(Data())
            process.terminationHandler = { _ in exitAndEOF.leave() }
            do {
                try process.run()
            } catch {
                exitAndEOF.leave()
                exitAndEOF.leave()
                once.resume(.failure(.launchFailed))
                return
            }
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
                child.terminate()
                try? await Task.sleep(for: .seconds(1))
                child.killIfRunning()
            }
            exitAndEOF.notify(queue: .global()) {
                deadline.cancel()
                once.resume(.success(Exit(status: child.status, stdout: output.withLock { $0 })))
            }
        }
        return try result.get()
    }

    /// `Process` is not Sendable. The deadline needs it from another thread only to signal it,
    /// which is safe once `run()` has returned.
    private final class Child: @unchecked Sendable {
        private let process: Process
        init(_ process: Process) { self.process = process }
        var status: Int32 { process.terminationStatus }
        func terminate() { process.terminate() }
        func killIfRunning() {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
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
