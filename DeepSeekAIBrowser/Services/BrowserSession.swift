import Foundation
import WebKit

@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    @Published var currentURL = ""
    @Published var isLoading = false
    @Published var lastError = ""

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ value: String) {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate) else { lastError = "网址格式不正确"; return }
        webView.load(URLRequest(url: url))
    }

    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }

    func evaluate(_ javascript: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(javascript) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    func snapshot() async -> String {
        let script = """
        (() => {
          const text = (document.body?.innerText || '').slice(0, 9000);
          const nodes = Array.from(document.querySelectorAll('a,button,input,video,source,[role="button"]')).slice(0, 120).map((el, i) => ({
            i, tag: el.tagName,
            text: (el.innerText || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').slice(0, 180),
            href: el.href || '', src: el.currentSrc || el.src || '', type: el.type || ''
          }));
          return JSON.stringify({title: document.title, url: location.href, text, nodes});
        })()
        """
        do { return (try await evaluate(script) as? String) ?? "{}" }
        catch { return "{}" }
    }

    func cleanPageLocally() async {
        let script = """
        (() => {
          const viewport = innerWidth * innerHeight;
          const terms = /广告|推广|关闭|跳过|skip|close|dismiss|ad/i;
          let changed = 0;
          for (const el of Array.from(document.querySelectorAll('body *'))) {
            const style = getComputedStyle(el); const rect = el.getBoundingClientRect();
            const fixed = style.position === 'fixed' || style.position === 'sticky';
            const large = rect.width * rect.height > viewport * 0.12;
            const high = Number.parseInt(style.zIndex || '0', 10) > 20;
            const label = `${el.innerText || ''} ${el.getAttribute('aria-label') || ''} ${el.id || ''} ${el.className || ''}`;
            if (fixed && high && large && terms.test(label)) { el.style.setProperty('display','none','important'); changed += 1; }
          }
          for (const el of Array.from(document.querySelectorAll('button,[role="button"],a'))) {
            const label = `${el.innerText || ''} ${el.getAttribute('aria-label') || ''}`;
            if (/^(关闭|跳过|close|skip|dismiss)$/i.test(label.trim())) { el.click(); changed += 1; }
          }
          return changed;
        })()
        """
        _ = try? await evaluate(script)
    }

    func execute(_ action: BrowserAction) async throws {
        switch action.type {
        case "open_url": if let url = action.url { load(url) }
        case "click": try await click(selector: action.selector)
        case "type": try await type(text: action.text ?? "", selector: action.selector)
        case "scroll": _ = try await evaluate("window.scrollBy({top: \(action.amount ?? 600), behavior: 'smooth'});")
        case "hide":
            if let selector = action.selector {
                let value = String(data: try JSONSerialization.data(withJSONObject: selector), encoding: .utf8) ?? "\"\""
                _ = try await evaluate("document.querySelector(\(value))?.style.setProperty('display','none','important');")
            }
        case "close_popup": await cleanPageLocally()
        case "download": if let url = action.url, let target = URL(string: url) { webView.load(URLRequest(url: target)) }
        case "wait": try await Task.sleep(for: .milliseconds(650))
        case "finish": break
        default: break
        }
    }

    private func click(selector: String?) async throws {
        guard let selector, !selector.isEmpty else { return }
        let value = String(data: try JSONSerialization.data(withJSONObject: selector), encoding: .utf8) ?? "\"\""
        _ = try await evaluate("document.querySelector(\(value))?.click();")
    }

    private func type(text: String, selector: String?) async throws {
        guard let selector, !selector.isEmpty else { return }
        let selectorValue = String(data: try JSONSerialization.data(withJSONObject: selector), encoding: .utf8) ?? "\"\""
        let textValue = String(data: try JSONSerialization.data(withJSONObject: text), encoding: .utf8) ?? "\"\""
        let script = "(() => { const el = document.querySelector(\(selectorValue)); if (!el) return false; el.focus(); el.value = \(textValue); el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); return true; })()"
        _ = try await evaluate(script)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isLoading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false; currentURL = webView.url?.absoluteString ?? "" }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false; lastError = error.localizedDescription }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        completionHandler(directory.appendingPathComponent(suggestedFilename))
    }

    func downloadDidFinish(_ download: WKDownload) {}
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { lastError = error.localizedDescription }
}
