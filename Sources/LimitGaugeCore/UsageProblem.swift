import Foundation

/// What the menu shows instead of numbers when a fetch cannot produce them. Each credential
/// failure has its own case, so a signed-in user is never told to sign in (ADR-0004 point 2).
public enum UsageProblem: Equatable, Sendable {
    /// Exit 44: Claude Code has never signed in on this machine.
    case noCredentials
    /// Exit 36, 51 or 128, or no answer within five seconds.
    case keychainDenied
    /// Any other exit code, or `/usr/bin/security` could not be launched.
    case keychainToolFailed
    /// The item exists but holds no access token where Claude Code keeps it.
    case credentialsUnreadable
    /// 401, and the Keychain still holds the same token, or a re-read token was rejected too.
    case tokenRejected
    case offline
    case server(Int)
    case decoding

    public var message: String {
        switch self {
        case .noCredentials: return "Sign in with Claude Code to see usage."
        case .keychainDenied: return "Keychain read was refused or did not finish. Unlock the login keychain and refresh."
        case .keychainToolFailed: return "Could not read the Keychain through /usr/bin/security."
        case .credentialsUnreadable: return "Claude Code's Keychain item has a format limitgauge does not recognise."
        case .tokenRejected: return "Token expired. Run claude in a terminal to sign in again."
        case .offline: return "Could not reach the usage endpoint."
        case .server(let status): return "Usage endpoint returned \(status)."
        case .decoding: return "Usage response could not be read."
        }
    }
}

/// A failed refresh: the problem the menu shows, and the one line the log gets.
struct RefreshFailure: Error, Equatable {
    var problem: UsageProblem
    /// Built only from case names, exit codes, HTTP statuses and error domains and codes, so
    /// it is safe at `privacy: .public`. Never the token, the tool's output, or a response body.
    var logDescription: String

    init(problem: UsageProblem, logDescription: String) {
        self.problem = problem
        self.logDescription = logDescription
    }

    init(_ error: CredentialError) {
        switch error {
        case .notFound:
            self.init(problem: .noCredentials, logDescription: "security: no item (exit 44)")
        case .refused(let code):
            self.init(problem: .keychainDenied, logDescription: "security: refused (exit \(code))")
        case .timedOut:
            self.init(problem: .keychainDenied, logDescription: "security: no answer in 5 s, terminated")
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
            // The case name only: malformedJSON's text can quote the response.
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
}
