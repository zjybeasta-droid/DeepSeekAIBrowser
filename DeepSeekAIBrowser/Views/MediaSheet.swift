import SwiftUI

struct MediaSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDiagnostics = false
    @State private var copiedURL = ""
    @State private var extracting = false

    /// 深度提取：翻页面源码、内联脚本、data-* 属性、播放器运行时对象。
    /// 专门对付"嗅探抓不到但页面上明明在播"的站。
    private func runDeepExtract() async {
        extracting = true
        let page = app.browser.currentURL
        let items = await app.browser.deepExtract()
        for (url, via) in items {
            app.sniffer.ingestExternal(url: url, via: via, page: page)
        }
        extracting = false
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("启用媒体嗅探", isOn: Binding(
                        get: { app.sniffer.isEnabled },
                        set: { app.sniffer.isEnabled = $0 }
                    ))
                    .font(.subheadline)

                    if !app.sniffer.isEnabled {
                        Text("已关闭。页面会回到完全正常的播放状态，但抓不到下载地址。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if app.sniffer.candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没抓到媒体地址").font(.subheadline)
                            Text("""
                            视频站的播放器几乎都用 HLS 分片：m3u8 只在网络请求里出现，页面 DOM 中的 video src 是 blob: 假地址。

                            所以要先在网页里点一下播放、让分片真的开始加载，嗅探器才拿得到地址。

                            如果点了播放还是没有，按上面的「深度提取」直接翻页面源码和播放器对象。
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(app.sniffer.candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                } header: {
                    HStack {
                        Text("嗅到的媒体（\(app.sniffer.candidates.count)）")
                        Spacer()
                        Button("清空列表") { app.sniffer.reset() }
                            .font(.caption)
                            .textCase(nil)
                    }
                }

                Section("下载任务（\(app.downloads.records.count)）") {
                    if app.downloads.records.isEmpty {
                        Text("还没有下载任务").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(app.downloads.records) { record in
                            recordRow(record)
                        }
                    }
                }
            }
            .navigationTitle("视频与下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await runDeepExtract() }
                    } label: {
                        Label(extracting ? "提取中…" : "深度提取", systemImage: "wand.and.stars")
                    }
                    .disabled(extracting)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Label("诊断", systemImage: "stethoscope")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsSheet().environmentObject(app)
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: MediaCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.displayName)
                .font(.subheadline)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(candidate.isMagnet ? "磁力" : (candidate.isHLS ? "HLS" : "文件"))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor(candidate).opacity(0.20))
                    .clipShape(Capsule())
                Text(candidate.isMagnet ? "BitTorrent" : candidate.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(candidate.source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if candidate.isMagnet {
                HStack(spacing: 8) {
                    Button {
                        UIPasteboard.general.string = candidate.url
                        copiedURL = candidate.url
                    } label: {
                        Label(copiedURL == candidate.url ? "已复制" : "复制磁力", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("iOS 无内置 BT 客户端，需复制到支持磁力的下载工具")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Button {
                    let page = candidate.page.isEmpty ? app.browser.currentURL : candidate.page
                    app.downloads.enqueue(urlString: candidate.url, pageURLString: page)
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func badgeColor(_ candidate: MediaCandidate) -> Color {
        if candidate.isMagnet { return .green }
        return candidate.isHLS ? .orange : .blue
    }

    @ViewBuilder
    private func recordRow(_ record: DownloadManager.Record) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.filename)
                .font(.subheadline)
                .lineLimit(2)

            if record.state == .running {
                ProgressView(value: record.progress)
                Text(record.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(stateText(record))
                    .font(.caption)
                    .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
            }

            HStack(spacing: 10) {
                if record.state == .running {
                    Button("暂停") { app.downloads.pause(record.id) }
                }
                if record.state == .queued {
                    Button("继续") { app.downloads.start(record.id) }
                }
                if record.state == .failed {
                    Button("重试") { app.downloads.retry(record.id) }
                }
                Button("删除", role: .destructive) { app.downloads.delete(record.id) }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.vertical, 4)
    }

    private func stateText(_ record: DownloadManager.Record) -> String {
        switch record.state {
        case .queued: return "排队中 · \(record.message)"
        case .running: return record.message
        case .finished: return "✅ \(record.message)"
        case .failed: return "❌ \(record.message)"
        case .cancelled: return "已取消"
        }
    }
}
