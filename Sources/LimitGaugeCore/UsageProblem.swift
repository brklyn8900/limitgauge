import Foundation

/// What the menu shows instead of numbers when a fetch cannot produce them. Each credential
/// failure has its own case, so a signed-in user is never told to sign in (ADR-0004 point 2).
public enum UsageProblem: Equatable, Sendable {
    /// Exit 44: Claude Code has never signed in on this machine.
    case noCredentials
    /// Exit 36: the login keychain is locked.
    case keychainLocked
    /// Exit 51 or 128: the read was refused or cancelled.
    case keychainDenied
    /// No answer within the read's deadline; the tool was terminated.
    case keychainTimedOut
    /// Any other exit code, or `/usr/bin/security` could not be launched.
    case keychainToolFailed
    /// The item exists but holds no access token where Claude Code keeps it.
    case credentialsUnreadable
    /// 401, and the Keychain still holds the same token, or a re-read token was rejected too.
    case tokenRejected
    case offline
    case server(Int)
    case decoding
    case codex(CodexUsageError)

    public var message: String {
        switch self {
        case .noCredentials: return "Sign in with Claude Code to see usage."
        case .keychainLocked: return "The login keychain is locked. Unlock it and refresh."
        // No "Refresh": after Deny, as the README advises, a refresh brings the same dialog back.
        case .keychainDenied: return "Access to Claude Code's Keychain item was denied. See the Keychain note in limitgauge's README."
        case .keychainTimedOut:
            return "The Keychain read did not finish within \(ClaudeCodeCredentials.readTimeoutText). Refresh to try again."
        case .keychainToolFailed: return "Could not read the Keychain through /usr/bin/security."
        case .credentialsUnreadable: return "Claude Code's Keychain item has a format limitgauge does not recognise."
        case .tokenRejected: return "Token expired. Run claude in a terminal to sign in again."
        case .offline: return "Could not reach the usage endpoint."
        case .server(let status): return "Usage endpoint returned \(status)."
        case .decoding: return "Usage response could not be read."
        case .codex(.notInstalled): return "Install Codex CLI and sign in to see Codex usage."
        case .codex(.notSignedIn): return "Run codex in a terminal and sign in with ChatGPT to see usage."
        case .codex(.timedOut): return "Codex usage took too long. Refresh to try again."
        case .codex(.unavailable): return "Could not read Codex usage. Check your connection and Codex sign-in."
        case .codex(.invalidResponse): return "Codex usage response could not be read. Try updating Codex CLI."
        }
    }

    /// How a failure backs off (ADR-0002 point 3). Exhaustive with no default, so a new
    /// problem does not build until it has a retry policy.
    var retry: RetryClass {
        switch self {
        case .codex(.notInstalled), .codex(.notSignedIn): return .needsUser
        case .codex(.timedOut), .codex(.unavailable), .codex(.invalidResponse): return .transient
        case .offline, .decoding: return .transient
        case .server(429): return .rateLimited
        case .server: return .transient
        case .noCredentials, .tokenRejected, .credentialsUnreadable, .keychainToolFailed,
             .keychainLocked, .keychainDenied, .keychainTimedOut: return .needsUser
        }
    }
}

/// Transient: offline, 5xx, an unreadable response. Rate limited: 429. Needs user: nothing
/// changes until the user acts (signs in, runs Claude Code, unlocks or answers the Keychain,
/// updates limitgauge).
enum RetryClass: Sendable {
    case transient, rateLimited, needsUser
}

struct RefreshFailure: Error, Equatable {
    var problem: UsageProblem
    /// Built only from case names, exit codes, HTTP statuses and error domains and codes, so
    /// it is safe at `privacy: .public`. Never the token, the tool's output, or a response body.
    var logDescription: String
    var pollSentNothing = false

    init(problem: UsageProblem, logDescription: String, pollSentNothing: Bool = false) {
        self.problem = problem
        self.logDescription = logDescription
        self.pollSentNothing = pollSentNothing
    }

    init(_ error: CredentialError) {
        switch error {
        case .notFound:
            self.init(problem: .noCredentials, logDescription: "security: no item (exit 44)")
        case .refused(let code):
            self.init(problem: code == 36 ? .keychainLocked : .keychainDenied, logDescription: "security: refused (exit \(code))")
        case .timedOut:
            self.init(problem: .keychainTimedOut, logDescription: "security: no answer in \(ClaudeCodeCredentials.readTimeoutText), terminated")
        case .failed(let code):
            self.init(problem: .keychainToolFailed, logDescription: "security: exit \(code)")
        case .launchFailed:
            self.init(problem: .keychainToolFailed, logDescription: "security: could not launch /usr/bin/security")
        case .malformed:
            self.init(problem: .credentialsUnreadable, logDescription: "security: item has no claudeAiOauth.accessToken")
        }
    }

    init(_ error: UsageAPI.Error) {
        switch error {
        case .unauthorized:
            self.init(problem: .tokenRejected, logDescription: "usage: 401 after the one re-read")
        case .httpStatus(let status):
            self.init(problem: .server(status), logDescription: "usage: HTTP \(status)")
        case .decoding(let decoding):
            let name = switch decoding {
            case .missingLimits: "missingLimits"
            case .malformedJSON: "malformedJSON"
            }
            self.init(problem: .decoding, logDescription: "usage: response unreadable (\(name))")
        case .transport(let underlying):
            let error = underlying as NSError
            self.init(problem: .offline, logDescription: "usage: transport \(error.domain) \(error.code)")
        }
    }

    /// 401, and the re-read returned the same token: ADR-0001's one retry is spent.
    static let tokenUnchanged = RefreshFailure(
        problem: .tokenRejected, logDescription: "usage: 401; the Keychain still holds the same token")

    /// A poll read the token the endpoint already rejected and sent nothing (ADR-0002 point 3).
    static let tokenStillRejected = RefreshFailure(
        problem: .tokenRejected, logDescription: "usage: token already rejected; poll sent no request",
        pollSentNothing: true)

    /// The last Keychain read was refused or timed out, so a poll ran no read (ADR-0002 point 3).
    static func readStillRefused(_ problem: UsageProblem) -> RefreshFailure {
        RefreshFailure(problem: problem, logDescription: "security: last read refused or timed out; poll ran no read",
                       pollSentNothing: true)
    }
}
