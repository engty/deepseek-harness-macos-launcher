import Foundation
import Testing
@testable import HarnessLauncher

struct PluginStoreIntegrationTests {
    /// Uses real packaged plugins and Runtime, but never copies credentials,
    /// sessions or configuration from the user's active profile.
    @Test @MainActor func realStoreInstallLoadsPluginsAndCreatesSession() async throws {
        guard ProcessInfo.processInfo.environment["HARNESS_RUN_PLUGIN_STORE_INTEGRATION"] == "1" else { return }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("harness store integration \(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let paths = AppPaths(applicationSupport: root.appendingPathComponent("support"),
            caches: root.appendingPathComponent("cache"), logs: root.appendingPathComponent("logs"))
        try paths.prepare()
        let installation = try RuntimeLocator().locate()
        let bundledRuntime = Dsh1024Adapter.resourceDirectory.deletingLastPathComponent().appendingPathComponent("runtime")
        let installer = DefaultProfileInstaller()
        #expect(try installer.seedIfNeeded(paths: paths, runtimeRoot: bundledRuntime))

        let fixture = root.appendingPathComponent("fixture")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data(#"{"name":"launcher-store-smoke","version":"1.0.0","type":"module","main":"index.js","bin":{"launcher-store-smoke":"cli.js"},"dsh":{"bundle":{"patch":"cordis.patch.yml"}}}"#.utf8)
            .write(to: fixture.appendingPathComponent("package.json"))
        try """
        export const name = 'launcher-store-smoke';
        export function apply(ctx) {
          ctx.inject(['webServer'], host => host.effect(() => host.webServer.register({
            kind: 'exact', path: '/launcher-store-smoke',
            handler: (req, res) => { res.writeHead(200); res.end('plugin-ready'); }
          })));
        }
        """.write(to: fixture.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try "- insert:\n    - id: launcher-store-smoke\n      name: launcher-store-smoke\n"
            .write(to: fixture.appendingPathComponent("cordis.patch.yml"), atomically: true, encoding: .utf8)
        try "#!/usr/bin/env node\nconsole.log('tool-ready');\n".write(to: fixture.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.appendingPathComponent("cli.js").path)
        let archive = root.appendingPathComponent("fixture.tgz")
        let packed = try await SubprocessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", archive.path, "-C", root.path, "fixture"])
        #expect(packed.status == 0)
        let isolatedEnvironment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "DSH1024_TELEMETRY": "0"]
        let runner = PluginCommandRunner(environment: isolatedEnvironment)
        let result = try await runner.mutateProfile(installation: installation, paths: paths,
            arguments: ["add", archive.path, "@anionex/dsh-vision-toolkit@0.1.40", "dsh-llm-codex@0.1.1"])
        #expect(result.status == 0)
        #expect(ProfileManager(paths: paths).refresh().contains { $0.id == "launcher-store-smoke" })
        #expect(!PluginExecutionEnvironment.requiresStoreMigration(profile: paths.profileWeb,
            store: paths.caches.appendingPathComponent("pnpm/store")))
        let environment = try PluginExecutionEnvironment.make(installation: installation, paths: paths,
            dshHome: paths.dshHome, base: ["HOME": root.path, "PATH": "/usr/bin:/bin"])
        let tool = try await SubprocessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["launcher-store-smoke"], environment: environment)
        #expect(tool.status == 0)
        #expect(tool.output.contains("tool-ready"))

        let controller = HarnessProcessController(readinessTimeout: 120, environment: isolatedEnvironment)
        do {
            let endpoint = try await controller.start(installation: installation, paths: paths, overlayURL: nil)
            let session = URLSession(configuration: .ephemeral)
            _ = try await session.data(from: endpoint)
            var origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            origin.query = nil; origin.fragment = nil; origin.path = ""
            let base = origin.url!
            let (pluginData, pluginResponse) = try await session.data(from: base.appendingPathComponent("launcher-store-smoke"))
            #expect((pluginResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(data: pluginData, encoding: .utf8) == "plugin-ready")
            for (method, payload) in [
                ("llm/listProviders", [:] as [String: Any]),
                ("session/create", ["request": ["cwd": root.path]] as [String: Any]),
            ] {
                var request = URLRequest(url: base.appendingPathComponent("api/\(method)"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "type": "client-request", "rpcId": UUID().uuidString, "method": method, "payload": ["args": payload]
                ])
                let (data, response) = try await session.data(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let result = json?["result"] as? [String: Any]
                if result?["ok"] as? Bool != true {
                    Issue.record("\(method) failed: \(String(data: data, encoding: .utf8) ?? "invalid JSON")")
                }
            }
            await controller.stop()
        } catch {
            await controller.stop()
            throw error
        }
        let manifestBeforeFailure = try Data(contentsOf: paths.profileWeb.appendingPathComponent("package.json"))
        do {
            _ = try await runner.mutateProfile(installation: installation, paths: paths,
                arguments: ["add", root.appendingPathComponent("missing-package.tgz").path])
            Issue.record("Missing package installation unexpectedly succeeded")
        } catch {
            #expect(try Data(contentsOf: paths.profileWeb.appendingPathComponent("package.json")) == manifestBeforeFailure)
        }
    }
}
