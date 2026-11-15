import Foundation

@MainActor
final class BrowserAgent: ObservableObject {
    @Published var isRunning = false
    @Published var status = ""

    private let browser: BrowserSession
    private let profileProvider: () -> BehaviorProfile
    private let apiKeyProvider: () -> String
    private let mediaProvider: () -> [MediaCandidate]
    private let messageHandler: (String) -> Void

    init(browser: BrowserSession,
         profileProvider: @escaping () -> BehaviorProfile,
         apiKeyProvider: @escaping () -> String,
         mediaProvider: @escaping () -> [MediaCandidate],
         messageHandler: @escaping (String) -> Void) {
        self.browser = browser
        self.profileProvider = profileProvider
        self.apiKeyProvider = apiKeyProvider
        self.mediaProvider = mediaProvider
        self.messageHandler = messageHandler
    }

    func run(task: String) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let profile = profileProvider()
        do {
            if profile.autoCleanAds && task.lowercased().contains("广告") {
                await browser.cleanPageLocally()
            }

            // DOM 摘要 + 嗅探到的真实媒体地址。
            // 没有后者，模型只能看到 blob: 假地址，就会说"页面有入口但没有具体链接"。
            var page = await browser.snapshot()
            let media = mediaProvider()
            if !media.isEmpty {
                let lines = media.prefix(12).map { candidate -> String in
                    let kind = candidate.isHLS ? "HLS播放列表" : "直链文件"
                    return "- [\(kind)] \(candidate.url)"
                }.joined(separator: "\n")
                page += """


                === 以下是嗅探器从网络层直接捕获的媒体地址（真实可下载，优先使用，不要再去 DOM 里找链接）===
                \(lines)
                """
            }

            status = "正在让 DeepSeek 判断页面…"
            let plan = try await DeepSeekClient(apiKey: apiKeyProvider()).makePlan(profile: profile, task: task, pageSnapshot: page)
            messageHandler(plan.message)

            guard profile.autoExecute else {
                status = "已生成操作计划，自动执行已关闭。"
                return
            }

            for action in plan.actions.prefix(max(1, profile.maxActionsPerTask)) {
                if Task.isCancelled { break }
                status = "执行：\(action.type)"
                try await browser.execute(action)
                try await Task.sleep(for: .milliseconds(220))
            }
            status = "完成"
        } catch {
            status = error.localizedDescription
            messageHandler(error.localizedDescription)
        }
    }
}
