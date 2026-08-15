import Foundation
import Testing
@testable import HarnessLauncher

struct KeychainStoreTests {
    @Test
    func keychainValueSurvivesStoreRecreation() throws {
        let service = "com.harness.desktop.launcher.tests"
        let account = "api-key-\(UUID().uuidString)"
        let store = KeychainStore(service: service, account: account)
        defer { try? store.delete() }

        try store.save("test-persisted-value")

        let recreatedStore = KeychainStore(service: service, account: account)
        #expect(recreatedStore.read(allowInteraction: false) == "test-persisted-value")
    }
}
