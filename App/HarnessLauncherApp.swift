import AppKit
import SwiftUI

@main
struct HarnessLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DeepSeek Harness", id: "main") {
            ContentView(model: appDelegate.model)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            LauncherCommands(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LauncherModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isHarnessRunning else { return .terminateNow }
        Task { @MainActor in
            await model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct LauncherCommands: Commands {
    @ObservedObject var model: LauncherModel

    var body: some Commands {
        CommandMenu("DeepSeek") {
            Button("Change DeepSeek API Key…") {
                model.configureDeepSeekBalance(forcePrompt: true)
            }
        }

        CommandMenu("Plugins") {
            Button("Install Plugin…") {
                model.installPluginPrompt()
            }
            Button("Stop Plugin…") {
                model.stopPluginPrompt()
            }
            Button("Remove Plugin…") {
                model.removePluginPrompt()
            }

            Divider()

            if model.plugins.isEmpty {
                Text("No installed bundle plugins")
            } else {
                Menu("Installed Plugins") {
                    ForEach(model.plugins) { plugin in
                        Menu(plugin.name) {
                            let status = model.pluginStatus(for: plugin)
                            Text("Status: \(status.rawValue)")
                            Text("Version: \(plugin.version)")
                            Divider()
                            Button("Start Plugin") {
                                Task { await model.setPluginEnabled(plugin, enabled: true) }
                            }
                            .disabled(!(status == .stopped || status == .error))
                            Button("Stop Plugin") {
                                Task { await model.setPluginEnabled(plugin, enabled: false) }
                            }
                            .disabled(!(status == .running || status == .starting))
                        }
                    }
                }
            }
        }

        CommandGroup(after: .appInfo) {
            Divider()
            Button("Check for Updates…") {
                model.checkForUpdates()
            }
        }

        CommandGroup(after: .windowArrangement) {
            Button("Restart DeepSeek Harness") {
                Task { await model.restart() }
            }
        }
    }
}
