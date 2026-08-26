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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                statusSummary
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
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

private struct DiscountIndicator: View {
    @State private var now = Date()
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
        .font(.caption)
        .foregroundStyle(tint)
        .accessibilityLabel("折扣 \(period.multiplierText)")
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
