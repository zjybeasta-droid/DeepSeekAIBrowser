import Foundation
import WebKit

/// 内容拦截器。
///
/// 之前这里把规则硬编码在源码里，`Resources/ContentBlockerRules.json` 打进包却从没被读过——
/// 改规则等于改代码。现在改成读包内 JSON，并用内容哈希做 identifier：
/// 规则一变 identifier 就变，不会拿到 WebKit 缓存里的旧规则。
@MainActor
final class ContentBlocker: ObservableObject {
    @Published var isReady = false
    @Published var ruleCount = 0
    @Published var status = "未加载"

    private var list: WKContentRuleList?

    private static let fallbackRules = """
    [
      {"trigger":{"url-filter":".*doubleclick\\\\..*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*googlesyndication\\\\..*"},"action":{"type":"block"}}
    ]
    """

    func compile() async {
        let json = Self.loadRulesJSON()
        let identifier = "rules-" + Self.hash(json)

        if let cached = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: identifier) {
            list = cached
            isReady = true
            ruleCount = json.components(separatedBy: "\"trigger\"").count - 1
            status = "已加载（缓存）\(ruleCount) 条"
            dlog("拦截规则命中缓存 \(identifier)")
            return
        }

        do {
            let compiled = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            )
            list = compiled
            isReady = true
            ruleCount = json.components(separatedBy: "\"trigger\"").count - 1
            status = "已编译 \(ruleCount) 条"
            dlog("拦截规则编译成功 \(identifier)，约 \(ruleCount) 条")
        } catch {
            // 整份规则编不过就退回最小集合：宁可有两条用，也不要一条都不用
            dlog("✗ 拦截规则编译失败：\(error.localizedDescription)，退回最小规则集")
            if let minimal = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "rules-fallback",
                encodedContentRuleList: Self.fallbackRules
            ) {
                list = minimal
                isReady = true
                ruleCount = 2
                status = "编译失败，已退回 2 条基础规则"
            } else {
                isReady = false
                status = "拦截不可用"
            }
        }
    }

    func attach(to webView: WKWebView) {
        guard let list else { return }
        webView.configuration.userContentController.add(list)
    }

    // MARK: - 资源

    private static func loadRulesJSON() -> String {
        guard let url = Bundle.main.url(forResource: "ContentBlockerRules", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dlog("⚠️ 包内没有 ContentBlockerRules.json，使用最小规则集")
            return fallbackRules
        }
        return text
    }

    /// 简易稳定哈希：规则文件一改，identifier 就变，避免 WebKit 返回旧规则。
    private static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return String(value, radix: 16)
    }
}
