import SwiftUI

struct MediaSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if app.sniffer.candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没抓到媒体地址").font(.subheadline)
                            Text("""
                            视频站的播放器几乎都用 HLS 分片：m3u8 只在网络请求里出现，页面 DOM 中的 video src 是 blob: 假地址。

                            所以要先在网页里点一下播放、让分片真的开始加载，嗅探器才拿得到地址。
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
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
                Text(candidate.isHLS ? "HLS" : "文件")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(candidate.isHLS ? Color.orange.opacity(0.22) : Color.blue.opacity(0.16))
                    .clipShape(Capsule())
                Text(candidate.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(candidate.source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                let page = candidate.page.isEmpty ? app.browser.currentURL : candidate.page
                app.downloads.enqueue(urlString: candidate.url, pageURLString: page)
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
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
