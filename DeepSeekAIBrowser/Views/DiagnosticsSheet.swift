import SwiftUI

/// 诊断面板：把 App 内部发生的事直接摊在屏幕上。
/// 开发机是 Windows，连不上 LLDB，所以这张屏幕就是唯一能看到运行时状态的地方。
struct DiagnosticsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var log = DiagnosticLog.shared
    @State private var copied = false
    @State private var exportedPath = ""

    private var header: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let lastURL = UserDefaults.standard.string(forKey: "browser.lastURL") ?? "(未记录)"
        return """
        AI浏览器 诊断信息
        版本: \(version) (\(build))
        设备: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        当前页: \(app.browser.currentURL.isEmpty ? "(无)" : app.browser.currentURL)
        上次页: \(lastURL)
        嗅探开关: \(app.sniffer.isEnabled ? "开" : "关")
        媒体候选: \(app.sniffer.candidates.count)
        下载任务: \(app.downloads.records.count)
        """
    }

    private var fullText: String {
        header + "\n\n--- 日志 ---\n" + log.snapshotText()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    Text(fullText.isEmpty ? "（暂无日志）" : fullText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(.secondarySystemBackground))

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = fullText
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制全部", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if let url = DiagnosticLog.shared.writeToDocuments(header: header) {
                            exportedPath = url.lastPathComponent
                        } else {
                            exportedPath = "写入失败"
                        }
                    } label: {
                        Label("导出文件", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        DiagnosticLog.shared.clear()
                        copied = false
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
                .padding(10)

                if !exportedPath.isEmpty {
                    Text("已写入 Documents/\(exportedPath)，可在「文件」App 里取出")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("诊断日志（\(log.lines.count) 行）")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // 打开面板就顺手 dump 一份 UA / Cookie 统计进日志，
                // 这样即使还没点下载也能看到下载器手上有什么凭证。
                _ = await app.browser.downloadContext()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
