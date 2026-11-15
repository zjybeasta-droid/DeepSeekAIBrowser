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
        profile = BehaviorProfile.load()
        apiKey = KeychainStore.load(service: "DeepSeekAIBrowser", account: "api-key") ?? ""

        // 嗅探脚本必须在第一次 load 之前注入，否则首屏的媒体请求会漏掉。
        browser.attachSniffer(sniffer)
        browser.onDownloadRequest = { [weak self] url, page in
            self?.downloads.enqueue(urlString: url.absoluteString, pageURLString: page)
        }
        downloads.resumeInterrupted()
    }

    func saveSettings() {
        profile.save()
        KeychainStore.save(apiKey, service: "DeepSeekAIBrowser", account: "api-key")
    }

    /// 「下载」按钮的主路径：嗅探器已经拿到地址就直接下，不再让 AI 去 DOM 里找。
    /// 只有完全没抓到媒体时才退回让 AI 分析页面。
    func smartDownload() async {
        let candidates = sniffer.candidates
        if let best = candidates.first(where: { $0.isHLS }) ?? candidates.first {
            let page = best.page.isEmpty ? browser.currentURL : best.page
            if let id = downloads.enqueue(urlString: best.url, pageURLString: page) {
                lastAgentMessage = "已加入下载：\(best.displayName)"
                _ = id
                return
            }
        }
        lastAgentMessage = "当前页面还没抓到媒体地址，让 AI 找一下入口…"
        await agent.run(task: "在当前页面找到可播放的主视频，提示用户先播放以触发加载。不要编造文件链接。")
    }
}
