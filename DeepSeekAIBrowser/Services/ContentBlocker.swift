import Foundation
import WebKit

@MainActor
final class ContentBlocker: ObservableObject {
    @Published var isReady = false
    private var list: WKContentRuleList?

    func compile() async {
        let rules = """
        [
          {"trigger":{"url-filter":".*doubleclick.*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*googlesyndication.*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*adservice.*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":".*popunder.*"},"action":{"type":"block"}}
        ]
        """
        do {
            list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "default-ad-rules", encodedContentRuleList: rules)
            isReady = true
        } catch { isReady = false }
    }

    func attach(to webView: WKWebView) {
        guard let list else { return }
        webView.configuration.userContentController.add(list)
    }
}
