import Foundation
import Testing
@testable import HarnessLauncher

struct PluginStoreTests {
    @Test func validatesStoreCommandsAndPreservesExplicitBuildApproval() throws {
        let request = try PluginStoreRequest(arguments: ["plugin", "--profile", "web", "add", "--allow-build=example", "github:owner/example"])
        #expect(request.arguments == ["add", "https://github.com/owner/example.git"])
        #expect(request.allowedBuildScripts == ["example"])
        for invalid in [
            ["plugin", "--profile", "global", "add", "example"],
            ["plugin", "--profile", "web", "exec", "example"],
            ["plugin", "--profile", "web", "add", "--global", "example"],
            ["plugin", "--profile", "web", "add", "--allow-build=*", "example"],
            ["plugin", "--profile", "web", "add", "example;touch/tmp/unwanted"],
            ["plugin", "--profile", "web", "remove", "../../example"],
            ["plugin", "--profile", "web", "add", "dsh1024@latest"],
        ] {
            #expect(throws: (any Error).self) { try PluginStoreRequest(arguments: invalid) }
        }
    }

    @Test @MainActor func validatesLocalAndEmbeddedStoreMessageOrigins() throws {
        let local = URL(string: "http://127.0.0.1:41234")!
        #expect(HarnessWebView.allowsStoreMessage(isMainFrame: true, origin: local, allowedOrigin: local))
        #expect(!HarnessWebView.allowsStoreMessage(isMainFrame: false, origin: local, allowedOrigin: local))
        #expect(!HarnessWebView.allowsStoreMessage(isMainFrame: true,
            origin: URL(string: "https://deepseek1024.com")!, allowedOrigin: local))
        #expect(HarnessWebView.allowsStoreMessage(isMainFrame: false,
            origin: URL(string: "https://deepseek1024.com")!, allowedOrigin: local, mainFrameURL: local))
        #expect(!HarnessWebView.allowsStoreMessage(isMainFrame: false,
            origin: URL(string: "https://deepseek1024.com")!, allowedOrigin: local,
            mainFrameURL: URL(string: "http://127.0.0.1:41235")!))
        #expect(!HarnessWebView.allowsStoreMessage(isMainFrame: true,
            origin: URL(string: "http://127.0.0.1:41235")!, allowedOrigin: local))
    }

    @Test func adapterIsIdempotentAndRejectsUnreviewedVersions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("node_modules/dsh1024")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest = package.appendingPathComponent("package.json")
        try Data(#"{"name":"dsh1024","version":"0.5.0"}"#.utf8).write(to: manifest)
        #expect(try Dsh1024Adapter.sync(profile: root))
        #expect(try !Dsh1024Adapter.sync(profile: root))
        try Data(#"{"name":"dsh1024","version":"0.6.0"}"#.utf8).write(to: manifest)
        #expect(throws: Dsh1024Adapter.Failure.self) { try Dsh1024Adapter.sync(profile: root) }
    }

    @Test func runtimeAndPluginToolsUseThePrivateProfileWithoutChangingHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness environment \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(applicationSupport: root.appendingPathComponent("support"), caches: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs"))
        let installation = RuntimeInstallation(executable: root.appendingPathComponent("runtime/bin/dsh"), root: root.appendingPathComponent("runtime"), version: nil, nodeExecutable: root.appendingPathComponent("runtime/node/bin/node"))
        let env = try PluginExecutionEnvironment.make(installation: installation, paths: paths, dshHome: paths.dshHome,
            base: ["HOME": "/Users/example", "PATH": "/usr/bin:/bin", "NPM_CONFIG_PREFIX": "/usr/local"])
        #expect(env["HOME"] == "/Users/example")
        #expect(env["DSH_HOME"] == paths.dshHome.path)
        #expect(env["npm_config_prefix"] == env["NPM_CONFIG_PREFIX"])
        #expect(env["npm_config_prefix"]?.hasPrefix(paths.toolchain.path + "/") == true)
        #expect(env["npm_config_store_dir"]?.hasPrefix(paths.caches.path + "/") == true)
        #expect(env["PATH"]?.contains(paths.profileWeb.appendingPathComponent("node_modules/.bin").path) == true)
        let modules = paths.profileWeb.appendingPathComponent("node_modules/.modules.yaml")
        try FileManager.default.createDirectory(at: modules.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "storeDir: /Users/buildrunner/pnpm/store/v10\n".write(to: modules, atomically: true, encoding: .utf8)
        let store = paths.caches.appendingPathComponent("pnpm/store")
        #expect(PluginExecutionEnvironment.requiresStoreMigration(profile: paths.profileWeb, store: store))
        try "storeDir: \(store.path)/v10\n".write(to: modules, atomically: true, encoding: .utf8)
        #expect(!PluginExecutionEnvironment.requiresStoreMigration(profile: paths.profileWeb, store: store))
    }
}
