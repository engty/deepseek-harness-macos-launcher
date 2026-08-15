import AppKit
import SwiftUI
import WebKit

@MainActor
struct HarnessWebView: NSViewRepresentable {
    let url: URL
    let onLoadError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedOrigin: url, onLoadError: onLoadError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
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

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var allowedOrigin: URL
        var onLoadError: (String) -> Void

        init(allowedOrigin: URL, onLoadError: @escaping (String) -> Void) {
            self.allowedOrigin = allowedOrigin
            self.onLoadError = onLoadError
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

            if targetURL.scheme == allowedOrigin.scheme,
               targetURL.host == allowedOrigin.host,
               targetURL.port == allowedOrigin.port {
                decisionHandler(.allow)
            } else if targetURL.scheme == "https",
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
                  targetURL.scheme == "https" else { return nil }
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
