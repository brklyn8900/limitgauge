import Foundation
import Synchronization
import Testing
@testable import LimitGaugeCore

/// A stand-in for `/usr/bin/security`: a shell script with the same contract (stdout, exit code).
private func standIn(_ script: String, timeout: Duration = .seconds(5)) -> ClaudeCodeCredentials {
    ClaudeCodeCredentials(command: .init(tool: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]),
                          timeout: timeout)
}

/// The service's token source over a reader.
private func reading(_ reader: ClaudeCodeCredentials) -> TokenReader {
    { () async throws(CredentialError) -> AccessToken in try await reader.read() }
}

private let item = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-test"}}"#

@Suite struct CredentialReadTests {
    /// Today the wait starts only after stdout reaches EOF, which a stuck tool never sends, so
    /// the deadline cannot fire. The tool must be gone afterwards, not just abandoned.
    @Test func readIsTerminatedAtTheTimeout() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("limitgauge-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let reader = standIn("echo $$ > '\(pidFile.path)'; exec /bin/sleep 30", timeout: .milliseconds(300))

        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CredentialError.timedOut) { try await reader.read() }
        #expect(clock.now - start < .seconds(2))

        let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<30 where alive {
            try await Task.sleep(for: .milliseconds(100))
            alive = kill(pid, 0) == 0
        }
        #expect(!alive)
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
    /// A slow Keychain read must not block the main actor: the menu stays responsive.
    @Test func readLeavesTheMainActorFree() async throws {
        let reader = standIn("/bin/sleep 0.5; printf '%s' '\(item)'")
        let rig = Rig(readToken: reading(reader))
        let clock = ContinuousClock()
        let start = clock.now
        let refresh = rig.service.refresh(.refreshRow)
        let marker = Task { @MainActor in clock.now }
        let mainRan = await marker.value - start
        _ = await refresh.value
        #expect(mainRan < .milliseconds(300))
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

    /// Today a malformed item, exit 51 and a tool that cannot launch all say "Sign in with
    /// Claude Code", which is wrong for a user who is signed in.
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

    /// Exit 51 and 128 mean the read was refused, so the message says access was denied
    /// instead of asking the user to unlock a keychain that is already unlocked.
    @Test func deniedSaysDeniedNotLocked() {
        let denied = UsageProblem.keychainDenied.message
        #expect(denied.localizedCaseInsensitiveContains("denied"))
        #expect(!denied.localizedCaseInsensitiveContains("unlock"))
        #expect(Set([UsageProblem.keychainLocked, .keychainDenied, .keychainTimedOut].map(\.message)).count == 3)
    }

    /// The log line names the cause with its code and nothing else.
    @Test func logLinesCarryTheExitCode() {
        #expect(RefreshFailure(CredentialError.refused(exitCode: 51)).logDescription == "security: refused (exit 51)")
        #expect(RefreshFailure(CredentialError.failed(exitCode: 7)).logDescription == "security: exit 7")
        #expect(RefreshFailure(UsageAPI.Error.decoding(.malformedJSON("{\"email\": \"x\"}"))).logDescription
            == "usage: response unreadable (malformedJSON)")
    }
}

@MainActor
@Suite struct RereadTests {
    /// A re-read after a 401 that fails reports its own problem; today try? hid it as a
    /// rejected token.
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
