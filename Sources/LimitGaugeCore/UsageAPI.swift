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

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchUsage(token: String) async throws(Error) -> UsageSnapshot {
        let data = try await get(Self.usageURL, token: token)
        do {
            return try UsageDecoding.snapshot(from: data)
        } catch let e as UsageDecoding.Error {
            throw .decoding(e)
        } catch {
            throw .decoding(.malformedJSON(String(describing: error)))
        }
    }

    public func fetchPlan(token: String) async throws(Error) -> Plan {
        let data = try await get(Self.profileURL, token: token)
        do {
            return try UsageDecoding.plan(from: data)
        } catch let e as UsageDecoding.Error {
            throw .decoding(e)
        } catch {
            throw .decoding(.malformedJSON(String(describing: error)))
        }
    }

    public static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    private func get(_ url: URL, token: String) async throws(Error) -> Data {
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
