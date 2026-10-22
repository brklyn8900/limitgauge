import Foundation
import Synchronization
import Testing
@testable import LimitGaugeCore

private func standIn(_ script: String, timeout: Duration = .seconds(5)) -> ClaudeCodeCredentials {
    ClaudeCodeCredentials(command: .init(tool: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]),
                          timeout: timeout)
}

private func reading(_ reader: ClaudeCodeCredentials) -> TokenReader {
    { () async throws(CredentialError) -> AccessToken in try await reader.read() }
}

private let item = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-test"}}"#

@Suite struct CredentialReadTests {
    /// The deadline fires while the tool is stuck and has sent no EOF, and the tool is gone
    /// afterwards, not just abandoned (ADR-0004 point 3).
    @Test func readIsTerminatedAtTheTimeout() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("limitgauge-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // A second, so a slow shell start has written its pid before the deadline.
        let reader = standIn("echo $$ > '\(pidFile.path)'; exec /bin/sleep 30", timeout: .seconds(1))

        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CredentialError.timedOut) { try await reader.read() }
        // Not before the deadline, and far under the tool's 30 s, with room for a loaded machine.
        let elapsed = clock.now - start
        #expect(elapsed >= .seconds(1) && elapsed < .seconds(10))

        let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<50 where alive {
            try await Task.sleep(for: .milliseconds(100))
            alive = kill(pid, 0) == 0
        }
        #expect(!alive)
    }

    /// A tool that survives SIGTERM is killed a second later. The stand-in logs each TERM and
    /// keeps running, so once it is gone, only SIGKILL can have ended it.
    @Test func toolThatTrapsTermIsKilled() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("limitgauge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid")
        let termFile = dir.appendingPathComponent("term")
        let reader = standIn("trap 'echo term >> \"\(termFile.path)\"' TERM; echo $$ > '\(pidFile.path)'; while :; do /bin/sleep 0.1; done",
                             timeout: .seconds(1))   // the trap is installed before the deadline

        await #expect(throws: CredentialError.timedOut) { try await reader.read() }

        let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        // Only a pid seen alive: once it is reaped, the number may belong to another process.
        defer { if alive { kill(pid, SIGKILL) } }
        for _ in 0..<50 where alive {
            try await Task.sleep(for: .milliseconds(100))
            alive = kill(pid, 0) == 0
        }
        #expect(!alive)
        #expect(try String(contentsOf: termFile, encoding: .utf8).contains("term"))
    }

    @Test func goodItemIsRead() async throws {
        let token = try await standIn("printf '%s' '\(item)'").read()
        #expect(token.value == "sk-ant-oat01-test")
    }

    @Test(arguments: [(Int32(44), CredentialError.notFound), (36, .refused(exitCode: 36)),
                      (51, .refused(exitCode: 51)), (128, .refused(exitCode: 128)), (7, .failed(exitCode: 7))])
    func exitCodesMapToErrors(code: Int32, error: CredentialError) async {
        await #expect(throws: error) { try await standIn("exit \(code)").read() }
    }

    /// More than a pipe buffer of output must not stall the tool.
    @Test func largeOutputIsDrained() async {
        await #expect(throws: CredentialError.malformed) {
            try await standIn("head -c 300000 /dev/zero").read()
        }
    }
}

@MainActor
@Suite struct CredentialReadIsolationTests {
    @Test func readLeavesTheMainActorFree() async throws {
        let reader = standIn("/bin/sleep 2; printf '%s' '\(item)'")
        let rig = Rig(readToken: reading(reader))
        let clock = ContinuousClock()
        let start = clock.now
        let refresh = rig.service.refresh(.refreshRow)
        let marker = Task { @MainActor in clock.now }
        let mainRan = await marker.value - start
        _ = await refresh.value
        // Well under the tool's 2 s, so only a blocked main actor fails it.
        #expect(mainRan < .milliseconds(1500))
        #expect(rig.fetcher.usageTokens == ["sk-ant-oat01-test"])
    }
}

@MainActor
@Suite struct CredentialProblemTests {
    private func problem(after reader: ClaudeCodeCredentials) async -> (UsageProblem?, [String]) {
        let rig = Rig(readToken: reading(reader))
        _ = await rig.service.refresh(.refreshRow).value
        return (rig.service.problem, rig.fetcher.usageTokens)
    }

    /// A malformed item, exit 51 and a tool that cannot launch each have their own problem,
    /// and none tells a signed-in user to sign in (ADR-0004 point 2).
    @Test func malformedRefusedAndLaunchFailureAreTheirOwnProblems() async {
        let malformed = await problem(after: standIn("printf '{}'"))
        let refused = await problem(after: standIn("exit 51"))
        let launch = await problem(after: ClaudeCodeCredentials(
            command: .init(tool: URL(fileURLWithPath: "/nonexistent/security"), arguments: []), timeout: .seconds(5)))
        let problems = [malformed.0, refused.0, launch.0]
        #expect(!problems.contains(.noCredentials))
        #expect(Set(problems.compactMap { $0.map { "\($0)" } }).count == 3)
        #expect(malformed.1 + refused.1 + launch.1 == [])
    }
}

@Suite struct CredentialMappingTests {
    @Test(arguments: [
        (CredentialError.notFound, UsageProblem.noCredentials),
        (.refused(exitCode: 36), .keychainLocked), (.refused(exitCode: 51), .keychainDenied),
        (.refused(exitCode: 128), .keychainDenied), (.timedOut, .keychainTimedOut),
        (.failed(exitCode: 7), .keychainToolFailed), (.launchFailed, .keychainToolFailed),
        (.malformed, .credentialsUnreadable),
    ])
    func eachFailureHasItsProblem(error: CredentialError, problem: UsageProblem) {
        #expect(RefreshFailure(error).problem == problem)
    }

    @Test func deniedSaysDeniedNotLocked() {
        let denied = UsageProblem.keychainDenied.message
        #expect(denied.localizedCaseInsensitiveContains("denied"))
        #expect(!denied.localizedCaseInsensitiveContains("unlock"))
        #expect(Set([UsageProblem.keychainLocked, .keychainDenied, .keychainTimedOut].map(\.message)).count == 3)
    }

    @Test func deniedDoesNotSendTheUserToRefresh() {
        let denied = UsageProblem.keychainDenied.message
        #expect(!denied.localizedCaseInsensitiveContains("refresh"))
        #expect(denied.contains("README"))
    }

    @Test func logLinesCarryTheExitCode() {
        #expect(RefreshFailure(CredentialError.refused(exitCode: 51)).logDescription == "security: refused (exit 51)")
        #expect(RefreshFailure(CredentialError.failed(exitCode: 7)).logDescription == "security: exit 7")
        #expect(RefreshFailure(CredentialError.timedOut).logDescription == "security: no answer in 5 s, terminated")
        #expect(RefreshFailure(UsageAPI.Error.decoding(.malformedJSON("{\"email\": \"x\"}"))).logDescription
            == "usage: response unreadable (malformedJSON)")
    }
}

@MainActor
@Suite struct RereadTests {
    @Test func failedRereadReportsItsOwnProblem() async {
        let reads = Mutex(0)
        let rig = Rig(usage: [.failure(.unauthorized)], readToken: { () async throws(CredentialError) -> AccessToken in
            if reads.withLock({ $0 += 1; return $0 }) == 1 { return AccessToken("old") }
            throw .refused(exitCode: 36)
        })
        _ = await rig.service.refresh(.refreshRow).value
        #expect(rig.service.problem == .keychainLocked)
    }
}
