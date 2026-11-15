import SwiftUI

@main
struct DeepSeekAIBrowserApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profile: BehaviorProfile
    @Published var apiKey: String
    @Published var lastAgentMessage = ""

    let browser = BrowserSession()
    let downloads = DownloadManager()
    let sniffer = MediaSniffer()
    let blocker = ContentBlocker()

    lazy var agent: BrowserAgent = {
        BrowserAgent(
            browser: browser,
            profileProvider: { [weak self] in self?.profile ?? .default },
            apiKeyProvider: { [weak self] in self?.apiKey ?? "" },
            mediaProvider: { [weak self] in self?.sniffer.candidates ?? [] },
            messageHandler: { [weak self] message in self?.lastAgentMessage = message }
        )
    }()

    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        dlog("=== 启动 AI浏览器 \(version) (\(build)) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) ===")

        profile = BehaviorProfile.load()
        apiKey = KeychainStore.load(service: "DeepSeekAIBrowser", account: "api-key") ?? ""
        dlog("API Key: \(apiKey.isEmpty ? "未设置" : "已设置(\(apiKey.count) 字符)")")

        // 嗅探脚本必须在第一次 load 之前注入，否则首屏的媒体请求会漏掉。
        browser.attachSniffer(sniffer)
        dlog("嗅探器已挂载")
        browser.onDownloadRequest = { [weak self] url, page in
            self?.downloads.enqueue(urlString: url.absoluteString, pageURLString: page)
        }
        // 让下载器能用 WebView 的真实 UA 和 Cookie。
        // 不搬这两样，带防盗链的 CDN 必定 403（WKWebView 与 URLSession 的 Cookie 存储不通）。
        downloads.contextProvider = { [weak self] in
            guard let self else { return (DownloadManager.userAgent, []) }
            return await self.browser.downloadContext()
        }
        downloads.resumeInterrupted()
        dlog("下载索引恢复完成，任务数 \(downloads.records.count)")
    }

    func saveSettings() {
        profile.save()
        KeychainStore.save(apiKey, service: "DeepSeekAIBrowser", account: "api-key")
    }

    /// 「下载」按钮的主路径：嗅探器已经拿到地址就直接下。
    /// 没抓到时给明确提示，不再让 AI 去 DOM 里空找 —— 那样只会消耗额度并给出误导结论。
    func smartDownload() async {
        let candidates = sniffer.candidates
        guard let best = candidates.first(where: { $0.isHLS }) ?? candidates.first else {
            lastAgentMessage = "当前页面还没抓到媒体地址。请先在网页里点一下播放，让它真的开始加载，然后再点下载。"
            return
        }
        let page = best.page.isEmpty ? browser.currentURL : best.page
        if downloads.enqueue(urlString: best.url, pageURLString: page) != nil {
            lastAgentMessage = "已加入下载：\(best.displayName)"
        } else {
            lastAgentMessage = "这个地址无法下载（不是 http/https，或已在下载队列里）。"
        }
    }
}
