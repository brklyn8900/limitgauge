import Foundation

/// Claude Code's OAuth access token. Opaque outside Core: `value` is internal and read only to
/// build the Authorization header, and every textual form is redacted, so neither string
/// interpolation, `print`, `dump` nor `String(reflecting:)` can put it in a log.
public struct AccessToken: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    let value: String

    init(_ value: String) {
        self.value = value
    }

    public var description: String { "AccessToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Why the token could not be read (ADR-0004 point 2). No case carries the tool's output, so
/// no case can leak it.
public enum CredentialError: Error, Equatable, Sendable {
    /// Exit 44: no item. Claude Code has never signed in on this machine.
    case notFound
    /// Exit 36, 51 or 128: the keychain is locked, or the read was refused or cancelled.
    case refused(exitCode: Int32)
    /// No exit within the deadline; the tool was terminated (ADR-0004 point 3).
    case timedOut
    /// Any other exit code.
    case failed(exitCode: Int32)
    /// `/usr/bin/security` could not be launched.
    case launchFailed
    /// The item was read but holds no `claudeAiOauth.accessToken` string.
    case malformed
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

    /// Suspends, never blocks, for the whole read, and is bounded by `timeout` whatever the
    /// tool does (ADR-0004 point 3).
    public func read() async throws(CredentialError) -> AccessToken {
        let exit: ToolRun.Exit
        do {
            exit = try await ToolRun.run(command, timeout: timeout)
        } catch .launchFailed {
            throw .launchFailed
        } catch {
            throw .timedOut
        }
        if let failure = Self.error(forExitCode: exit.status) { throw failure }
        return try Self.parse(exit.stdout)
    }

    /// `security` exits with the low byte of the Security framework's status: 44
    /// errSecItemNotFound, 36 errSecInteractionNotAllowed, 51 errSecAuthFailed, 128
    /// errSecUserCanceled.
    static func error(forExitCode code: Int32) -> CredentialError? {
        switch code {
        case 0: return nil
        case 44: return .notFound
        case 36, 51, 128: return .refused(exitCode: code)
        default: return .failed(exitCode: code)
        }
    }

    /// The item is JSON: {"claudeAiOauth": {"accessToken": ..., ...}}. Only `accessToken` is
    /// read; `expiresAt` is ignored on purpose (ADR-0004 point 1).
    static func parse(_ data: Data) throws(CredentialError) -> AccessToken {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw .malformed }
        return AccessToken(token)
    }
}
