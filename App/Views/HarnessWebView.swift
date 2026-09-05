import AppKit
import SwiftUI
import WebKit

@MainActor
struct HarnessWebView: NSViewRepresentable {
    let url: URL
    let onLoadError: (String) -> Void
    var onStoreRequest: (([String]) async -> [String: Any])? = nil

    // dsh1024 provides its store as a remote iframe inside the local Harness
    // page. Keep the main document locked to the local runtime, but allow the
    // plugin's declared store origin in a subframe so the App window can host
    // the plugin UI without handing it off to a browser.
    private static let embeddedPluginOriginHosts = ["deepseek1024.com"]

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedOrigin: url, onLoadError: onLoadError, onStoreRequest: onStoreRequest)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addScriptMessageHandler(
            context.coordinator, contentWorld: .page, name: "launcherPluginStore"
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedOrigin = url
        context.coordinator.onLoadError = onLoadError
        context.coordinator.onStoreRequest = onStoreRequest
        // SwiftUI calls updateNSView whenever any observed launcher state
        // changes, including the once-per-minute balance value. The WebView
        // may currently be on Harness's Settings/Models route, so comparing
        // the full URL here would incorrectly reload the home page. Reload
        // only when the Harness origin itself changes (for example after a
        // process restart on a new port).
        guard let currentURL = webView.url,
              !Self.sharesOrigin(currentURL, url) else { return }
        webView.load(URLRequest(url: url))
    }

    static func sharesOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    static func isAllowedEmbeddedPluginOrigin(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return embeddedPluginOriginHosts.contains(host)
    }

    static func allowsStoreMessage(
        isMainFrame: Bool,
        origin: URL,
        allowedOrigin: URL,
        mainFrameURL: URL? = nil
    ) -> Bool {
        if isMainFrame {
            return ["127.0.0.1", "localhost", "::1"].contains(origin.host ?? "")
                && sharesOrigin(origin, allowedOrigin)
        }
        // The 1024 Store is rendered in a remote iframe inside the local
        // Harness document. The iframe may request a native install only when
        // its exact HTTPS origin is embedded by our local Runtime page.
        guard isAllowedEmbeddedPluginOrigin(origin),
              let mainFrameURL,
              sharesOrigin(mainFrameURL, allowedOrigin) else { return false }
        return true
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
        var allowedOrigin: URL
        var onLoadError: (String) -> Void
        var onStoreRequest: (([String]) async -> [String: Any])?

        init(allowedOrigin: URL, onLoadError: @escaping (String) -> Void,
             onStoreRequest: (([String]) async -> [String: Any])? = nil) {
            self.allowedOrigin = allowedOrigin
            self.onLoadError = onLoadError
            self.onStoreRequest = onStoreRequest
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            let securityOrigin = message.frameInfo.securityOrigin
            var origin = URLComponents()
            origin.scheme = securityOrigin.protocol
            origin.host = securityOrigin.host
            origin.port = securityOrigin.port
            guard message.name == "launcherPluginStore", let originURL = origin.url,
                  HarnessWebView.allowsStoreMessage(isMainFrame: message.frameInfo.isMainFrame,
                      origin: originURL, allowedOrigin: allowedOrigin, mainFrameURL: message.webView?.url),
                  let body = message.body as? [String: Any],
                  let arguments = body["arguments"] as? [String],
                  let onStoreRequest else {
                replyHandler(nil, "此页面不能调用启动器插件安装功能。")
                return
            }
            Task { @MainActor in
                replyHandler(await onStoreRequest(arguments), nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let targetURL = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if HarnessWebView.sharesOrigin(targetURL, allowedOrigin) {
                decisionHandler(.allow)
            } else if navigationAction.targetFrame?.isMainFrame == false,
                      HarnessWebView.isAllowedEmbeddedPluginOrigin(targetURL) {
                // Only a non-main-frame navigation may use this allowlist.
                // A remote top-level navigation still follows the existing
                // external-link policy below.
                decisionHandler(.allow)
            } else if targetURL.scheme?.lowercased() == "https",
                      navigationAction.navigationType == .linkActivated {
                // Only user-clicked external links may leave the dedicated App window.
                // Redirects and script navigations are denied to avoid silently handing
                // the Harness UI or credentials to the system browser.
                    NSWorkspace.shared.open(targetURL)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.navigationType == .linkActivated,
                  let targetURL = navigationAction.request.url,
                  targetURL.scheme?.lowercased() == "https" else { return nil }
            NSWorkspace.shared.open(targetURL)
            return nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadError(error.localizedDescription)
        }
    }
}
