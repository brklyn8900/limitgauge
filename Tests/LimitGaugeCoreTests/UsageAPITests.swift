import Foundation
import Testing
@testable import LimitGaugeCore

@Suite struct UsageAPITests {
    @Test func sessionKeepsNothingOnDisk() {
        let configuration = UsageAPI.makeSession().configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.timeoutIntervalForResource == 30)
    }

    @Test func sessionWaitsForConnectivity() {
        #expect(UsageAPI.makeSession().configuration.waitsForConnectivity)
    }
}
