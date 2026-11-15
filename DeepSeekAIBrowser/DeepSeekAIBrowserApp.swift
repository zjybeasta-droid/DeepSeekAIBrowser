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
    let blocker = ContentBlocker()
    lazy var agent: BrowserAgent = {
        BrowserAgent(
            browser: browser,
            profileProvider: { [weak self] in self?.profile ?? .default },
            apiKeyProvider: { [weak self] in self?.apiKey ?? "" },
            messageHandler: { [weak self] message in self?.lastAgentMessage = message }
        )
    }()

    init() {
        profile = BehaviorProfile.load()
        apiKey = KeychainStore.load(service: "DeepSeekAIBrowser", account: "api-key") ?? ""
    }

    func saveSettings() {
        profile.save()
        KeychainStore.save(apiKey, service: "DeepSeekAIBrowser", account: "api-key")
    }
}
