import Foundation
import Testing
@testable import LimitGaugeCore

/// A stand-in for `/usr/bin/security`: a shell script with the same contract (stdout, exit code).
private func standIn(_ script: String, timeout: Duration = .seconds(5)) -> ClaudeCodeCredentials {
    ClaudeCodeCredentials(command: .init(tool: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]),
                          timeout: timeout)
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
        await #expect(throws: ClaudeCodeCredentials.Error.timedOut) { try await reader.read() }
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

    @Test(arguments: [(Int32(44), ClaudeCodeCredentials.Error.notFound),
                      (36, .accessDenied), (128, .accessDenied), (7, .security(exitCode: 7))])
    func exitCodesMapToErrors(code: Int32, error: ClaudeCodeCredentials.Error) async {
        await #expect(throws: error) { try await standIn("exit \(code)").read() }
    }

    /// More than a pipe buffer of output must not stall the tool.
    @Test func largeOutputIsDrained() async {
        await #expect(throws: ClaudeCodeCredentials.Error.malformed) {
            try await standIn("head -c 300000 /dev/zero").read()
        }
    }
}

@MainActor
@Suite struct CredentialReadIsolationTests {
    /// A slow Keychain read must not block the main actor: the menu stays responsive.
    @Test func readLeavesTheMainActorFree() async throws {
        let reader = standIn("/bin/sleep 0.5; printf '%s' '\(item)'")
        let fetcher = ScriptedFetcher(usage: [])
        let service = UsageService(fetcher: fetcher, tokenSource: { try await reader.read() })
        let clock = ContinuousClock()
        let start = clock.now
        let refresh = service.refresh()
        let marker = Task { @MainActor in clock.now }
        let mainRan = await marker.value - start
        await refresh.value
        #expect(mainRan < .milliseconds(300))
        #expect(fetcher.usageTokens == ["sk-ant-oat01-test"])
    }
}
