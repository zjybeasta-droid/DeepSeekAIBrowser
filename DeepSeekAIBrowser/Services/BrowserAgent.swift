import Foundation

@MainActor
final class BrowserAgent: ObservableObject {
    @Published var isRunning = false
    @Published var status = ""

    private let browser: BrowserSession
    private let profileProvider: () -> BehaviorProfile
    private let apiKeyProvider: () -> String
    private let messageHandler: (String) -> Void

    init(browser: BrowserSession, profileProvider: @escaping () -> BehaviorProfile, apiKeyProvider: @escaping () -> String, messageHandler: @escaping (String) -> Void) {
        self.browser = browser
        self.profileProvider = profileProvider
        self.apiKeyProvider = apiKeyProvider
        self.messageHandler = messageHandler
    }

    func run(task: String) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let profile = profileProvider()
        do {
            if profile.autoCleanAds && task.lowercased().contains("广告") { await browser.cleanPageLocally() }
            let page = await browser.snapshot()
            status = "正在让 DeepSeek 判断页面…"
            let plan = try await DeepSeekClient(apiKey: apiKeyProvider()).makePlan(profile: profile, task: task, pageSnapshot: page)
            messageHandler(plan.message)
            guard profile.autoExecute else { status = "已生成操作计划，自动执行已关闭。"; return }
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
