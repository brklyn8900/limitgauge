import Foundation
import Testing
@testable import LimitGaugeCore

@Suite struct UsageAPITests {
    /// The bearer request and the /profile body (which holds the account email) must not reach
    /// a cache, cookie store or credential store on disk, and no fetch may hold a refresh open
    /// for the default seven-day resource timeout.
    @Test func sessionKeepsNothingOnDisk() {
        let configuration = UsageAPI.makeSession().configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.timeoutIntervalForResource == 30)
    }

    /// A poll that fires on wake, before Wi-Fi is back, must wait for the network within the
    /// resource timeout instead of failing at once as offline.
    @Test func sessionWaitsForConnectivity() {
        #expect(UsageAPI.makeSession().configuration.waitsForConnectivity)
    }
}
