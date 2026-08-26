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
    private var menuTrackingObserver: NSObjectProtocol?
    private var menuItemObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        localizeSystemMenus()
        DispatchQueue.main.async { [weak self] in
            self?.localizeSystemMenus()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.localizeSystemMenus()
        }
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.localizeSystemMenus()
            }
        }
        menuItemObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.localizeSystemMenus()
            }
        }
    }

    deinit {
        if let menuTrackingObserver {
            NotificationCenter.default.removeObserver(menuTrackingObserver)
        }
        if let menuItemObserver {
            NotificationCenter.default.removeObserver(menuItemObserver)
        }
    }

    private func localizeSystemMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let translations = [
            "File": "文件",
            "Edit": "编辑",
            "View": "显示",
            "Window": "窗口",
            "Help": "帮助",
            "DeepSeek": "设置",
            "Plugins": "插件",
            "About DeepSeek Harness": "关于 DeepSeek Harness",
            "Services": "服务",
            "Hide DeepSeek Harness": "隐藏 DeepSeek Harness",
            "Hide Others": "隐藏其他",
            "Show All": "显示全部",
            "Quit and Keep Windows": "退出并保留窗口",
            "Undo": "撤销",
            "Redo": "重做",
            "Cut": "剪切",
            "Copy": "拷贝",
            "Paste": "粘贴",
            "Paste and Match Style": "粘贴并匹配样式",
            "Delete": "删除",
            "Select All": "全选",
            "Start Dictation": "开始听写",
            "Emoji & Symbols": "表情与符号",
            "Enter Full Screen": "进入全屏",
            "Exit Full Screen": "退出全屏",
            "Minimize": "最小化",
            "Zoom": "缩放",
            "Bring All to Front": "将全部置于最前"
        ]

        func translate(_ menu: NSMenu) {
            if let translated = translations[menu.title] {
                menu.title = translated
            }
            for item in menu.items {
                if let translated = translations[item.title] {
                    item.title = translated
                }
                if let submenu = item.submenu {
                    translate(submenu)
                }
            }
        }
        translate(mainMenu)
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
        CommandMenu("设置") {
            Button("更换 DeepSeek API 密钥…") {
                model.configureDeepSeekBalance(forcePrompt: true)
            }

            Divider()

            Button("检查 Harness 更新…") {
                model.checkForUpdates()
            }
        }

        CommandMenu("插件") {
            Button("安装插件…") {
                model.installPluginPrompt()
            }
            .disabled(model.isOperationInProgress)
            Button("停用插件…") {
                model.stopPluginPrompt()
            }
            .disabled(model.isOperationInProgress)
            Button("卸载插件…") {
                model.removePluginPrompt()
            }
            .disabled(model.isOperationInProgress)
            Button("清理插件缓存…") {
                model.clearPluginCachePrompt()
            }
            .disabled(model.isOperationInProgress)

            Divider()

            if model.plugins.isEmpty {
                Text("没有已安装插件")
            } else {
                Menu("已安装插件") {
                    ForEach(model.plugins) { plugin in
                        Menu(plugin.name) {
                            let status = model.pluginStatus(for: plugin)
                            Text("状态：\(status.displayName)")
                            Text("版本：\(plugin.version)")
                            Divider()
                            Button("启用插件") {
                                Task { await model.setPluginEnabled(plugin, enabled: true) }
                            }
                            .disabled(!(status == .stopped || status == .error) || model.isOperationInProgress)
                            Button("停用插件") {
                                Task { await model.setPluginEnabled(plugin, enabled: false) }
                            }
                            .disabled(!(status == .running || status == .starting) || model.isOperationInProgress)
                        }
                    }
                }
            }
        }

        CommandGroup(after: .appInfo) {
            Divider()
            Button("检查 DeepSeek Harness 更新…") {
                model.checkForAppUpdates()
            }
        }

        CommandGroup(after: .windowArrangement) {
            Button("重启 DeepSeek Harness") {
                Task { await model.restart() }
            }
            .disabled(model.isOperationInProgress)
        }
    }
}
