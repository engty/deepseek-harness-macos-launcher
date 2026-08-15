import Foundation
import Testing
@testable import HarnessLauncher

@Suite
struct HarnessWebViewTests {
    @Test
    @MainActor
    func balanceStateUpdatesKeepTheCurrentHarnessRoute() throws {
        let home = try #require(URL(string: "http://127.0.0.1:43127"))
        let settings = try #require(URL(string: "http://127.0.0.1:43127/settings/models"))

        #expect(HarnessWebView.sharesOrigin(home, settings))
    }

    @Test
    @MainActor
    func aNewHarnessPortTriggersAWebViewReload() throws {
        let oldEndpoint = try #require(URL(string: "http://127.0.0.1:43127"))
        let newEndpoint = try #require(URL(string: "http://127.0.0.1:43128"))

        #expect(!HarnessWebView.sharesOrigin(oldEndpoint, newEndpoint))
    }
}
