import Foundation
import Security

/// Reads the access token Claude Code keeps in the login Keychain. Read-only by design:
/// refreshing or rewriting the item could log Claude Code out (ADR-0001).
public enum ClaudeCodeCredentials {
    public static let service = "Claude Code-credentials"

    public struct Token: Sendable {
        public var accessToken: String
        public var expiresAt: Date?

        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    public enum Error: Swift.Error, Equatable {
        /// No item named `service`. Claude Code has never signed in on this machine.
        case notFound
        /// The user denied the Keychain prompt, or the ACL does not include this app.
        case accessDenied
        case keychain(OSStatus)
        case malformed
    }

    public static func read() throws(Error) -> Token {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: throw .notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed: throw .accessDenied
        default: throw .keychain(status)
        }
        guard let data = result as? Data else { throw .malformed }
        return try parse(data)
    }

    /// The item is JSON: {"claudeAiOauth": {"accessToken": ..., "expiresAt": <ms since 1970>, ...}}.
    static func parse(_ data: Data) throws(Error) -> Token {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw .malformed }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Token(accessToken: token, expiresAt: expiresAt)
    }
}
