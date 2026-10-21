import Foundation

/// Claude Code's OAuth access token. Opaque outside Core: `value` is internal and read only to
/// build the Authorization header, and every textual form is redacted, so neither string
/// interpolation, `print`, `dump` nor `String(reflecting:)` can put it in a log.
public struct AccessToken: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    let value: String
    public var expiresAt: Date?

    init(_ value: String, expiresAt: Date? = nil) {
        self.value = value
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    public var description: String { "AccessToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Reads the access token Claude Code keeps in the login Keychain. Read-only by design:
/// refreshing or rewriting the item could log Claude Code out (ADR-0001).
///
/// The read goes through `/usr/bin/security`, the same tool Claude Code uses to store and
/// read the item, so the item's access list already trusts it and no consent dialog is
/// raised (ADR-0004).
public struct ClaudeCodeCredentials: Sendable {
    public static let service = "Claude Code-credentials"
    static let security = ToolRun.Command(
        tool: URL(fileURLWithPath: "/usr/bin/security"),
        arguments: ["find-generic-password", "-s", service, "-w"]
    )
    static let readTimeout: Duration = .seconds(5)

    let command: ToolRun.Command
    let timeout: Duration

    /// The production reader: the absolute `/usr/bin/security` and five seconds. Neither can
    /// be changed from outside Core.
    public init() {
        self.init(command: Self.security, timeout: Self.readTimeout)
    }

    /// Tests: a stand-in tool and a short deadline.
    init(command: ToolRun.Command, timeout: Duration) {
        self.command = command
        self.timeout = timeout
    }

    public enum Error: Swift.Error, Equatable {
        /// No item named `service`. Claude Code has never signed in on this machine.
        case notFound
        /// The read was refused, cancelled, or did not finish: a locked keychain or a dialog
        /// that was not answered.
        case accessDenied
        /// The security tool failed with an exit code not covered above.
        case security(exitCode: Int32)
        case malformed
        /// No exit within the deadline; the tool was terminated (ADR-0004 point 3).
        case timedOut
    }

    /// Suspends, never blocks, for the whole read, and is bounded by `timeout` whatever the
    /// tool does (ADR-0004 point 3).
    public func read() async throws(Error) -> AccessToken {
        let exit: ToolRun.Exit
        do {
            exit = try await ToolRun.run(command, timeout: timeout)
        } catch .launchFailed {
            throw .security(exitCode: -1)
        } catch {
            throw .timedOut
        }
        if let failure = Self.error(forExitCode: exit.status) { throw failure }
        return try Self.parse(exit.stdout)
    }

    /// Exit codes of `security` as Claude Code relies on them: 44 for a missing item, 36 when
    /// interaction is not allowed, 128 when the user cancels a dialog.
    static func error(forExitCode code: Int32) -> Error? {
        switch code {
        case 0: return nil
        case 44: return .notFound
        case 36, 128: return .accessDenied
        default: return .security(exitCode: code)
        }
    }

    /// The item is JSON: {"claudeAiOauth": {"accessToken": ..., "expiresAt": <ms since 1970>, ...}}.
    static func parse(_ data: Data) throws(Error) -> AccessToken {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw .malformed }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return AccessToken(token, expiresAt: expiresAt)
    }
}
