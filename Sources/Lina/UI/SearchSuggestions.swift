import AppKit
import SwiftUI
import WebKit

/// Google's Search Suggestions chip for a grounded answer. Google's terms say it must be shown as sent,
/// with its own styling, next to the answer. Tapping a suggestion opens Google Search in the browser.
struct SearchSuggestionsView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.page(html), baseURL: nil)
        context.coordinator.html = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadHTMLString(Self.page(html), baseURL: nil)
    }

    /// Google's snippet already carries its own styles for light and dark; this only removes the page margin.
    static func page(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}</style>
        </head><body>\(html)</body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html = ""

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The snippet itself loads inline; every link it holds opens in the writer's browser.
            guard action.navigationType == .linkActivated || action.targetFrame == nil,
                  let url = action.request.url else { return .allow }
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}
