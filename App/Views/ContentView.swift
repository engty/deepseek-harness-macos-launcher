import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        ZStack {
            Group {
                if let endpoint = model.endpointURL {
                    HarnessWebView(url: endpoint, onLoadError: { error in
                        model.webViewDidFail(error)
                    }, onStoreRequest: { arguments in
                        await model.handlePluginStoreRequest(arguments)
                    })
                } else {
                    StartupView(model: model)
                }
            }

            if let stage = model.runtimeUpdateStage {
                RuntimeUpdateProgressView(stage: stage)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        // Keep the titlebar status outside SwiftUI's toolbar item grouping.
        // macOS 26 gives toolbar items a Liquid Glass capsule even when the
        // item is marked borderless. A native titlebar accessory preserves the
        // system traffic lights and title while leaving this status region
        // transparent and independently sized.
        .background {
            ZStack {
                TitlebarStatusAccessory(
                    content: AnyView(titlebarLeadingContent),
                    layoutAttribute: .left,
                    minimumWidth: 0,
                    hidesWindowTitle: true
                )
                TitlebarStatusAccessory(
                    content: AnyView(statusSummary),
                    layoutAttribute: .right,
                    minimumWidth: 0,
                    hidesWindowTitle: false
                )
            }
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
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 18, height: 18)
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
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .help("点击更换 DeepSeek API Key")
            } else {
                Button {
                    model.configureDeepSeekBalance()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "creditcard")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 18, height: 18)
                        Text(model.balanceDisplayText)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .help("配置 DeepSeek API Key")
            }

        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 8)
    }

    private var runtimeUpdateControl: some View {
        Group {
            if model.hasAvailableRuntimeUpdate {
                Button {
                    model.downloadLatestUpdate()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(model.isOperationInProgress)
                .help(model.runtimeUpdateHelpText)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var titlebarLeadingContent: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("DeepSeek Harness")
                    .font(.system(size: 14, weight: .semibold))

                if let version = model.runtimeVersion, !version.isEmpty {
                    Text(version)
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)

            runtimeUpdateControl
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 8)
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

private struct RuntimeUpdateProgressView: View {
    let stage: RuntimeUpdateStage

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tint)

            Text("正在升级 DeepSeek Harness")
                .font(.headline)

            ProgressView(value: stage.fraction)
                .progressViewStyle(.linear)
                .frame(width: 280)

            Text("阶段 \(stage.rawValue)/\(RuntimeUpdateStage.totalSteps)：\(stage.message)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(26)
        .frame(minWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 18)
    }
}

private struct TitlebarStatusAccessory: NSViewRepresentable {
    let content: AnyView
    let layoutAttribute: NSLayoutConstraint.Attribute
    let minimumWidth: CGFloat
    let hidesWindowTitle: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            content: content,
            layoutAttribute: layoutAttribute,
            minimumWidth: minimumWidth,
            hidesWindowTitle: hidesWindowTitle
        )
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
        private let layoutAttribute: NSLayoutConstraint.Attribute
        private let minimumWidth: CGFloat
        private let hidesWindowTitle: Bool
        private weak var window: NSWindow?
        private weak var hostingView: NSHostingView<AnyView>?
        private var accessoryController: NSTitlebarAccessoryViewController?

        init(
            content: AnyView,
            layoutAttribute: NSLayoutConstraint.Attribute,
            minimumWidth: CGFloat,
            hidesWindowTitle: Bool
        ) {
            self.content = content
            self.layoutAttribute = layoutAttribute
            self.minimumWidth = minimumWidth
            self.hidesWindowTitle = hidesWindowTitle
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

            if hidesWindowTitle {
                window.titleVisibility = .hidden
            }

            let hostingView = NSHostingView(rootView: content)
            hostingView.setContentHuggingPriority(.required, for: .horizontal)
            hostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
            hostingView.frame = NSRect(x: 0, y: 0, width: 260, height: 30)

            let accessoryController = NSTitlebarAccessoryViewController()
            accessoryController.layoutAttribute = layoutAttribute
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
            let width = max(fittingSize.width, minimumWidth)
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
                if hidesWindowTitle {
                    window.titleVisibility = .visible
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
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(tint)
                }

                Text("折扣 \(period.multiplierText)")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 14, weight: .medium))
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
