import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var filename: String
        var state: String = "等待"
    }

    @Published private(set) var items: [Item] = []

    func enqueue(_ url: URL) {
        let item = Item(url: url, filename: url.lastPathComponent.isEmpty ? "video" : url.lastPathComponent)
        items.append(item)
        update(id: item.id, state: "下载中")
        Task {
            do {
                let (temporary, _) = try await URLSession.shared.download(from: url)
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(item.filename)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                update(id: item.id, state: "完成：\(destination.lastPathComponent)")
            } catch { update(id: item.id, state: "失败：\(error.localizedDescription)") }
        }
    }

    private func update(id: UUID, state: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }
}
