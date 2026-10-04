import SwiftUI
import WebKit

/// Owns the WKWebView so toolbar actions (print, PDF) can reach it.
@MainActor
final class WebViewStore: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published private(set) var isLoading = true

    override init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        #if os(macOS)
        webView.allowsMagnification = true
        #else
        webView.scrollView.minimumZoomScale = 0.25
        webView.scrollView.maximumZoomScale = 5
        webView.isFindInteractionEnabled = true
        #endif
    }

    func load(html: String) {
        isLoading = true
        webView.loadHTMLString(html, baseURL: nil)
    }

    // Only the generated page itself may load; links open in the system browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .other {
            return .allow
        }
        if let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            #if os(iOS)
            await UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}

#if os(iOS)
struct WebView: UIViewRepresentable {
    let store: WebViewStore
    func makeUIView(context: Context) -> WKWebView { store.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
struct WebView: NSViewRepresentable {
    let store: WebViewStore
    func makeNSView(context: Context) -> WKWebView { store.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
