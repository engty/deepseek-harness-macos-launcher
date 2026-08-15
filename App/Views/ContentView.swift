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
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.phase.isReady ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(model.runtimeVersion.map { "DeepSeek Harness \($0)" } ?? "DeepSeek Harness")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }

                    Divider()
                        .frame(height: 15)

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
                        Divider()
                            .frame(height: 15)
                        Button {
                            model.downloadLatestUpdate()
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .help("下载 DeepSeek Harness 更新")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .task {
            await model.startIfNeeded()
        }
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
                        Task { await model.start() }
                    }
                    .buttonStyle(.borderedProminent)

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
