import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Group {
            if let endpoint = model.endpointURL {
                HarnessWebView(url: endpoint) { error in
                    model.webViewDidFail(error)
                }
            } else {
                StartupView(model: model)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        // Keep the titlebar status outside SwiftUI's toolbar item grouping.
        // macOS 26 gives toolbar items a Liquid Glass capsule even when the
        // item is marked borderless. A native titlebar accessory preserves the
        // system traffic lights and title while leaving this status region
        // transparent and independently sized.
        .background {
            TitlebarStatusAccessory(content: AnyView(statusSummary))
                .frame(width: 0, height: 0)
        }
        .task {
            await model.startIfNeeded()
        }
    }

    private var statusSummary: some View {
        HStack(spacing: 12) {
            DiscountIndicator()

            if model.isBalanceConfigured {
                Button {
                    model.configureDeepSeekBalance(forcePrompt: true)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "creditcard")
                            .foregroundStyle(.secondary)
                        if let amount = model.balanceAmountDisplayText {
                            Text("余额")
                            Text(amount)
                                .foregroundStyle(balanceColor)
                        } else {
                            Text(model.balanceDisplayText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("点击更换 DeepSeek API Key")
            } else {
                Button {
                    model.configureDeepSeekBalance()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "creditcard")
                        Text(model.balanceDisplayText)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("配置 DeepSeek API Key")
            }

            if model.hasAvailableRuntimeUpdate {
                Button {
                    model.downloadLatestUpdate()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(model.isOperationInProgress)
                .help("下载 DeepSeek Harness 更新")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 16)
    }

    private var balanceColor: Color {
        switch model.balanceTone {
        case .healthy:
            return .green
        case .warning:
            return .yellow
        case .critical:
            return .red
        case .unknown:
            return .secondary
        }
    }
}

private struct TitlebarStatusAccessory: NSViewRepresentable {
    let content: AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeNSView(context: Context) -> WindowAnchorView {
        let view = WindowAnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowAnchorView, context: Context) {
        context.coordinator.update(content)
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    static func dismantleNSView(_ nsView: WindowAnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private var content: AnyView
        private weak var window: NSWindow?
        private weak var hostingView: NSHostingView<AnyView>?
        private var accessoryController: NSTitlebarAccessoryViewController?

        init(content: AnyView) {
            self.content = content
        }

        func update(_ content: AnyView) {
            self.content = content
            hostingView?.rootView = content
            resizeHostingView()
        }

        func attach(to window: NSWindow) {
            if self.window === window, accessoryController != nil {
                return
            }

            detach()

            let hostingView = NSHostingView(rootView: content)
            hostingView.setContentHuggingPriority(.required, for: .horizontal)
            hostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
            hostingView.frame = NSRect(x: 0, y: 0, width: 260, height: 30)

            let accessoryController = NSTitlebarAccessoryViewController()
            accessoryController.layoutAttribute = .right
            accessoryController.view = hostingView
            window.addTitlebarAccessoryViewController(accessoryController)

            self.window = window
            self.hostingView = hostingView
            self.accessoryController = accessoryController

            // The titlebar accessory is laid out before SwiftUI has measured
            // the hosted view. Refit once after the first layout so the
            // accessory remains content-sized without a fixed capsule.
            DispatchQueue.main.async { [weak self] in
                self?.resizeHostingView()
            }
        }

        private func resizeHostingView() {
            guard let hostingView else { return }
            hostingView.layoutSubtreeIfNeeded()
            let fittingSize = hostingView.fittingSize
            let width = max(fittingSize.width, 220)
            let height = max(fittingSize.height, 30)
            hostingView.setFrameSize(NSSize(width: width, height: height))
        }

        func detach() {
            if let accessoryController, let window {
                if let index = window.titlebarAccessoryViewControllers.firstIndex(where: {
                    $0 === accessoryController
                }) {
                    window.removeTitlebarAccessoryViewController(at: index)
                }
            }
            window = nil
            hostingView = nil
            accessoryController = nil
        }
    }
}

private final class WindowAnchorView: NSView {
    var onWindowChange: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowChange?(window)
        }
    }
}

private struct DiscountIndicator: View {
    @State private var now = Date()
    @State private var isShowingSchedule = false
    private let icon: NSImage?

    init() {
        if let url = Bundle.main.url(forResource: "DiscountIcon", withExtension: "svg") {
            icon = NSImage(contentsOf: url)
        } else {
            icon = nil
        }
    }

    private var period: DeepSeekDiscountPeriod {
        DeepSeekDiscountPeriod.current(at: now)
    }

    private var tint: Color {
        period == .peak ? .secondary : .green
    }

    var body: some View {
        Button {
            isShowingSchedule.toggle()
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(tint)
                } else {
                    Image(systemName: "percent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tint)
                }

                Text("折扣 \(period.multiplierText)")
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(tint)
        .accessibilityLabel("折扣 \(period.multiplierText)")
        .help("查看折扣时段")
        .popover(
            isPresented: $isShowingSchedule,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("折扣时段说明")
                    .font(.headline)

                Text("北京时间（UTC+8）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                Text("非折扣时段")
                    .font(.subheadline.weight(.semibold))
                Text("周一至周五 09:00–12:00、14:00–18:00")
                    .font(.callout)

                Text("其余时间为折扣时段，价格为高峰时段的一半。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 270, alignment: .leading)
            .padding(14)
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }
}

private struct StartupView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("DeepSeek Harness")
                    .font(.title2.weight(.semibold))
                Text(model.phase.title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if case .starting = model.phase {
                ProgressView()
                    .controlSize(.small)
                Text("首次安装或更新插件时，可能需要几分钟准备依赖。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(detailText)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560)

                HStack(spacing: 12) {
                    Button("Restart DeepSeek Harness") {
                        Task { await model.restart() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isOperationInProgress)

                    Button("Export Diagnostics") {
                        model.exportDiagnostics()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var detailText: String {
        switch model.phase {
        case .runtimeMissing:
            return "请将经过验证的 dsh Runtime 放入 App 的 runtime 目录，或在开发时设置 HARNESS_DSH_PATH 指向可执行的 dsh。主界面不会打开系统浏览器。"
        case .failed(let message):
            return message
        case .stopped:
            return "DeepSeek Harness 当前已停止。点击 Restart DeepSeek Harness 重新启动专用 App 窗口中的 Harness UI。"
        case .busy(let operation):
            return operation
        default:
            return "正在准备 Harness 专用窗口。"
        }
    }
}
