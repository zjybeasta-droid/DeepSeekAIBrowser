import SwiftUI
import WebKit

struct BrowserView: UIViewRepresentable {
    @ObservedObject var session: BrowserSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
