import Foundation

struct BehaviorProfile: Codable, Equatable {
    var name: String
    var model: String
    var systemPrompt: String
    var autoCleanAds: Bool
    var autoExecute: Bool
    var maxActionsPerTask: Int
    var temperature: Double

    static let `default` = BehaviorProfile(
        name: "默认浏览助手",
        model: "deepseek-chat",
        systemPrompt: """
你是一个运行在 iPad 浏览器内部的网页操作助手。你要理解当前网页，并通过提供的浏览器动作完成用户任务。

优先目标：
1. 保持用户当前页面和视频播放器可用；
2. 关闭遮挡内容的广告、弹窗和无关标签页；
3. 只在页面明确提供可访问的文件链接或官方下载入口时建议下载；
4. 已授权的普通浏览动作可以连续执行，遇到登录、验证码、支付、删除或不确定操作时停下来说明。

你必须返回 JSON，不要输出 Markdown。格式：
{"message":"简短说明","actions":[{"type":"...","selector":"...","text":"...","url":"...","amount":0}]}

可用动作：open_url、click、type、scroll、hide、close_popup、download、wait、finish。
selector 使用 CSS 选择器；不确定时使用空 selector 并先返回 finish。
""",
        autoCleanAds: true,
        autoExecute: true,
        maxActionsPerTask: 8,
        temperature: 0.2
    )

    static func load() -> BehaviorProfile {
        guard let data = UserDefaults.standard.data(forKey: "behavior-profile"),
              let value = try? JSONDecoder().decode(BehaviorProfile.self, from: data) else { return .default }
        return value
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "behavior-profile")
    }

    func exportedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

struct BrowserAction: Codable {
    var type: String
    var selector: String?
    var text: String?
    var url: String?
    var amount: Double?
}

struct AgentPlan: Codable {
    var message: String
    var actions: [BrowserAction]
}
