import SwiftUI

struct ContentView: View {
    private enum ActiveSheet: String, Identifiable {
        case settings
        case media
        var id: String { rawValue }
    }

    @EnvironmentObject private var app: AppModel
    @State private var address = ""
    @State private var task = ""
    @State private var activeSheet: ActiveSheet?

    private static let lastURLKey = "browser.lastURL"
    private static let fallbackURL = "https://m.bing.com"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button("‹") { app.browser.goBack() }
                    Button("›") { app.browser.goForward() }
                    TextField("网址", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    Button("打开") { app.browser.load(address) }
                    Button { activeSheet = .settings } label: { Image(systemName: "gearshape") }
                }
                .padding(8)

                BrowserView(session: app.browser)
                    .overlay(alignment: .top) {
                        if app.browser.isLoading { ProgressView().padding(8).background(.thinMaterial).clipShape(Capsule()) }
                    }

                if !app.lastAgentMessage.isEmpty || !app.agent.status.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if !app.lastAgentMessage.isEmpty { Text(app.lastAgentMessage).font(.footnote) }
                        if !app.agent.status.isEmpty { Text(app.agent.status).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                }

                HStack(spacing: 8) {
                    TextField("让 AI 操作当前网页…", text: $task, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let value = task
                        task = ""
                        Task { await app.agent.run(task: value) }
                    } label: {
                        Image(systemName: app.agent.isRunning ? "stop.fill" : "paperplane.fill")
                    }
                    .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.agent.isRunning)
                }
                .padding(8)

                HStack(spacing: 8) {
                    Button("清理页面") { Task { await app.browser.cleanPageLocally() } }
                    Button("视频（\(app.sniffer.candidates.count)）") { activeSheet = .media }
                    Button("下载") { Task { await app.smartDownload() } }
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 8)
            }
            .navigationTitle("AI 浏览器")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .settings: SettingsView().environmentObject(app)
                case .media: MediaSheet().environmentObject(app)
                }
            }
            .task {
                await app.blocker.compile()
                app.blocker.attach(to: app.browser.webView)
                if address.isEmpty {
                    address = UserDefaults.standard.string(forKey: Self.lastURLKey) ?? Self.fallbackURL
                }
                app.browser.load(address)
            }
            .onChange(of: app.browser.currentURL) { _, newValue in
                guard !newValue.isEmpty else { return }
                // 记住最后停留的页面：下次冷启动直接回到这里，不再停在测试页
                UserDefaults.standard.set(newValue, forKey: Self.lastURLKey)
                if address != newValue { address = newValue }
            }
        }
    }
}
