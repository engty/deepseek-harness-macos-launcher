import Foundation
import Testing
@testable import HarnessLauncher

struct DeepSeekCredentialStoreTests {
    @Test
    func modelCredentialRoundTripsWithoutRemovingOtherProviders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = DeepSeekCredentialStore()
        let credentials = root.appendingPathComponent(".credentials.yaml")
        try "OPENAI_API_KEY: \"openai-test\"\n".write(to: credentials, atomically: true, encoding: .utf8)

        try store.write("deepseek-test", to: root)

        #expect(try store.read(from: root) == "deepseek-test")
        let text = try String(contentsOf: credentials, encoding: .utf8)
        #expect(text.contains("OPENAI_API_KEY: \"openai-test\""))
        #expect(text.contains("DEEPSEEK_API_KEY: \"deepseek-test\""))
    }

    @Test
    func readsAndUpdatesHarnessRefsFormatWithoutFlatteningIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let credentials = root.appendingPathComponent(".credentials.yaml")
        try "version: 1\nrefs:\n  DEEPSEEK_API_KEY: \"deepseek-old\"\n  ANIONEX_FREE_VISION: \"vision-ref\"\n"
            .write(to: credentials, atomically: true, encoding: .utf8)

        let store = DeepSeekCredentialStore()
        #expect(try store.read(from: root) == "deepseek-old")
        try store.write("deepseek-new", to: root)
        #expect(try store.read(from: root) == "deepseek-new")

        let text = try String(contentsOf: credentials, encoding: .utf8)
        #expect(text.contains("refs:\n  DEEPSEEK_API_KEY: \"deepseek-new\""))
        #expect(text.contains("ANIONEX_FREE_VISION: \"vision-ref\""))
        #expect(!text.contains("\nDEEPSEEK_API_KEY:"))
    }
}
