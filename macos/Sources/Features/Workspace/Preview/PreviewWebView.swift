import SwiftUI
import WebKit

/// A SwiftUI wrapper around WKWebView for rendering local HTML content in the
/// workspace preview pane. Modeled after `Ghostty.InspectorViewRepresentable`
/// (Sources/Ghostty/Surface View/InspectorView.swift).
///
/// Security posture (NFR-5): the web view uses a non-persistent data store,
/// disables JavaScript, and only ever loads local HTML strings with a nil
/// base URL. It never accesses the network.
struct PreviewWebView: NSViewRepresentable {
    /// The full HTML document to render.
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Never persist any browsing data to disk.
        configuration.websiteDataStore = .nonPersistent()

        // The preview only renders static HTML, so JavaScript stays off.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)

        // The preview is a passive viewer; disallow any navigation gestures.
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false

        // Blend with the surrounding SwiftUI chrome instead of drawing an
        // opaque white page background.
        webView.underPageBackgroundColor = .clear

        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.loadedHTML = html
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload when the content actually changed to avoid flicker on
        // unrelated SwiftUI updates.
        guard context.coordinator.loadedHTML != html else { return }
        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.loadedHTML = html
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        /// The HTML most recently loaded into the web view.
        var loadedHTML: String?
    }
}
