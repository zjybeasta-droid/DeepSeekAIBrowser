import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @State private var address = "https://www.example.com"
    @State private var task = ""
    @State private var showSettings = false

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
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
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

                HStack {
                    Button("清理页面") { Task { await app.browser.cleanPageLocally() } }
                    Button("识别视频") { Task { await app.agent.run(task: "识别当前网页中的主视频和可用的官方下载入口，先不要下载。") } }
                    Button("下载") { Task { await app.agent.run(task: "在当前网页中找到用户可访问的视频下载入口并开始下载。") } }
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 8)
            }
            .navigationTitle("AI 浏览器")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(app) }
            .task {
                await app.blocker.compile()
                app.blocker.attach(to: app.browser.webView)
                app.browser.load(address)
            }
        }
    }
}
