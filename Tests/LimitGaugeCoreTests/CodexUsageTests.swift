import Foundation
import Testing
@testable import LimitGaugeCore

@Suite struct CodexUsageDecodingTests {
    @Test func decodesEveryPresentBucketWindow() throws {
        let reading = try CodexUsageReader.decode(Data("""
        {"id":2,"result":{"rateLimitsByLimitId":{
          "codex":{"limitId":"codex","limitName":null,"planType":"pro",
                     "primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1893456000},
                     "secondary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":1894060800}},
          "other":{"limitId":"other","limitName":"Other","primary":{"usedPercent":7,"windowDurationMins":60,"resetsAt":1893459600},"secondary":null}
        }}}
        """.utf8), fetchedAt: Date(timeIntervalSince1970: 1))

        #expect(reading.snapshot.limits.count == 3)
        #expect(reading.snapshot.limits.map(\.kind) == [.other("codex:codex:300"), .other("codex:codex:10080"), .other("codex:other:60")])
        #expect(reading.snapshot.limits[0].title == "Codex · 5 hours")
        #expect(reading.snapshot.limits[1].title == "Codex · 7 days")
        #expect(reading.plan?.rateLimitTier == "pro")
    }

    @Test func usesBackwardCompatibleSingleBucket() throws {
        let reading = try CodexUsageReader.decode(Data("""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":"Codex","primary":{"usedPercent":0,"windowDurationMins":15,"resetsAt":1893456000},"secondary":null}}}
        """.utf8))
        #expect(reading.snapshot.limits.count == 1)
        #expect(reading.snapshot.limits[0].title == "Codex · 15 min")
    }

    @Test func supportsAWeeklyOnlyPrimaryWindow() throws {
        let reading = try CodexUsageReader.decode(Data("""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1893456000},"secondary":null}}}
        """.utf8))
        #expect(reading.snapshot.limits[0].title == "Codex · 7 days")
        #expect(reading.snapshot.codexWeeklyLimit?.percent == 8)
    }

    @Test func compactWeeklyNeverSubstitutesAnotherQuota() throws {
        let reading = try CodexUsageReader.decode(Data(#"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1893456000}},"other":{"limitId":"other","primary":{"usedPercent":90,"windowDurationMins":10080,"resetsAt":1893456000}}}}}"#.utf8))
        #expect(reading.snapshot.codexWeeklyLimit == nil)
    }

    @Test func windowIdentityDoesNotDependOnPrimaryOrSecondarySlot() throws {
        let primary = try CodexUsageReader.decode(Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":1,"windowDurationMins":60,"resetsAt":1893456000},"secondary":null}}}"#.utf8))
        let secondary = try CodexUsageReader.decode(Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":null,"secondary":{"usedPercent":1,"windowDurationMins":60,"resetsAt":1893456000}}}}"#.utf8))
        #expect(primary.snapshot.limits[0].kind == secondary.snapshot.limits[0].kind)
    }

    @Test func usesMultiBucketKeyWhenLimitIdIsNull() throws {
        let reading = try CodexUsageReader.decode(Data("""
        {"id":2,"result":{"rateLimitsByLimitId":{"team":{"limitId":null,"limitName":"Team","primary":{"usedPercent":1,"windowDurationMins":60,"resetsAt":1893456000},"secondary":null}}}}
        """.utf8))
        #expect(reading.snapshot.limits[0].kind == .other("codex:team:60"))
        #expect(reading.snapshot.limits[0].title == "Team · 1 hour")
    }

    @Test(arguments: [
        #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":null,"secondary":null}}}"#,
        #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":101,"windowDurationMins":5,"resetsAt":1}}}}"#,
        #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5,"windowDurationMins":0,"resetsAt":1}}}}"#,
        #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":null,"secondary":{"usedPercent":"five","windowDurationMins":60,"resetsAt":1}}}}"#,
    ])
    func rejectsEmptyOrMalformedWindows(_ json: String) {
        #expect(throws: CodexUsageError.self) { try CodexUsageReader.decode(Data(json.utf8)) }
    }

    @Test func authenticationErrorIsSeparated() {
        let json = #"{"id":2,"error":{"code":-32000,"message":"ChatGPT authentication required"}}"#
        #expect(throws: CodexUsageError.notSignedIn) { try CodexUsageReader.decode(Data(json.utf8)) }
    }

    @Test func ignoresRelativeAndMissingCandidates() {
        #expect(CodexUsageReader.executable(environment: ["PATH": "./bin:/definitely/not/a/directory"], fixedPaths: []) == nil)
    }

    @Test func transportTimesOut() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CodexUsageError.timedOut) {
            try await CodexAppServer(executable: URL(fileURLWithPath: "/bin/sh"), timeout: .milliseconds(100)).read(arguments: ["-c", "exec /bin/sleep 30"])
        }
        #expect(clock.now - start < .seconds(3))
    }

    @Test func transportRejectsEofBeforeReply() async {
        await #expect(throws: CodexUsageError.unavailable) {
            try await CodexAppServer(executable: URL(fileURLWithPath: "/bin/true"), timeout: .seconds(1)).read(arguments: [])
        }
    }

    @Test func transportKillsTermIgnoringProcessBeforeReturning() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("limitgauge-codex-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; while :; do :; done"
        await #expect(throws: CodexUsageError.timedOut) {
            try await CodexAppServer(executable: URL(fileURLWithPath: "/bin/sh"), timeout: .milliseconds(100)).read(arguments: ["-c", script])
        }
        let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }

    @Test func transportIgnoresNotificationsAndExitsAfterItsReply() async throws {
        let script = "IFS= read x; printf '%s\\n' '{\"id\":1,\"result\":{}}'; IFS= read x; IFS= read x; printf '%s\\n' '{\"method\":\"account/rateLimits/updated\",\"params\":{}}'; printf '%s\\n' '{\"id\":99,\"result\":{}}'; printf '%s\\n' '{\"id\":2,\"result\":{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":10,\"windowDurationMins\":60,\"resetsAt\":1893456000},\"secondary\":null}}}'"
        let reading = try await CodexAppServer(executable: URL(fileURLWithPath: "/bin/sh"), timeout: .seconds(2)).read(arguments: ["-c", script])
        #expect(reading.snapshot.limits.count == 1)
        #expect(reading.snapshot.limits[0].percent == 10)
    }

    @Test func initializationErrorStopsHandshake() async throws {
        let requests = FileManager.default.temporaryDirectory.appendingPathComponent("codex-unexpected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: requests) }
        let script = """
        IFS= read x
        printf '%s\\n' '{"id":1,"error":{"code":-32000,"message":"authentication required"}}'
        while IFS= read x; do printf '%s\\n' "$x" >> '\(requests.path)'; done
        """
        await #expect(throws: CodexUsageError.notSignedIn) {
            try await CodexAppServer(executable: URL(fileURLWithPath: "/bin/sh"), timeout: .seconds(2)).read(arguments: ["-c", script])
        }
        #expect(!FileManager.default.fileExists(atPath: requests.path))
    }

    @Test(arguments: ["printf '%s\\n' 'not-json'", "printf '%s\\n' '{\"id\":1}'"])
    func malformedHandshakeIsRejected(_ script: String) async {
        await #expect(throws: CodexUsageError.invalidResponse) {
            try await CodexAppServer(executable: URL(fileURLWithPath: "/bin/sh"), timeout: .seconds(2)).read(arguments: ["-c", script])
        }
    }

    @Test func newlineFloodIsBoundedAcrossCompleteMessages() async {
        // Each line is valid notification JSON; the cap must cover all lines, not only the
        // current partial line, and must end the helper before its long timeout.
        let script = #"exec /usr/bin/awk 'BEGIN { for (i=0; i<50000; i++) print "{\"method\":\"notification\",\"params\":{}}" }'"#
        await #expect(throws: CodexUsageError.invalidResponse) {
            try await CodexAppServer(executable: URL(fileURLWithPath: "/bin/sh"), timeout: .seconds(10)).read(arguments: ["-c", script])
        }
    }

    @Test func closedStdinDoesNotSignalTheApplication() async {
        // Close only after receiving initialize, then reply. The client's next write is
        // guaranteed to meet a closed reader while the helper remains alive.
        let script = """
        IFS= read x
        exec 0<&-
        printf '%s\\n' '{"id":1,"result":{}}'
        exec /bin/sleep 30
        """
        await #expect(throws: CodexUsageError.unavailable) {
            try await CodexAppServer(executable: URL(fileURLWithPath: "/bin/sh"), timeout: .seconds(2)).read(arguments: ["-c", script])
        }
    }

}
