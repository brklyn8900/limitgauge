import Foundation

/// Client for the two account endpoints. Read-only: it never touches token refresh.
public struct UsageAPI: Sendable {
    public enum Error: Swift.Error {
        /// The token was rejected. The caller re-reads the Keychain once and retries.
        case unauthorized
        case httpStatus(Int)
        case decoding(UsageDecoding.Error)
        case transport(any Swift.Error)
    }

    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private let session: URLSession

    public init() {
        self.init(session: Self.makeSession())
    }

    init(session: URLSession) {
        self.session = session
    }

    /// Ephemeral, with no cache, cookie or credential store, so neither the bearer request nor
    /// the /profile body (which holds the account email) reaches disk. A fetch without a network
    /// waits for one, so a poll that fires on wake does not fail before Wi-Fi is back. The
    /// resource timeout bounds that wait and every fetch a refresh waits on; the default is
    /// seven days.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    public func fetchUsage(token: AccessToken) async throws(Error) -> UsageSnapshot {
        let data = try await get(Self.usageURL, token: token)
        do {
            return try UsageDecoding.snapshot(from: data)
        } catch let e as UsageDecoding.Error {
            throw .decoding(e)
        } catch {
            throw .decoding(.malformedJSON(String(describing: error)))
        }
    }

    public func fetchPlan(token: AccessToken) async throws(Error) -> Plan {
        let data = try await get(Self.profileURL, token: token)
        do {
            return try UsageDecoding.plan(from: data)
        } catch let e as UsageDecoding.Error {
            throw .decoding(e)
        } catch {
            throw .decoding(.malformedJSON(String(describing: error)))
        }
    }

    public static func request(_ url: URL, token: AccessToken) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    private func get(_ url: URL, token: AccessToken) async throws(Error) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: Self.request(url, token: token))
        } catch {
            throw .transport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw .unauthorized
        default: throw .httpStatus(status)
        }
    }
}
