import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    enum Kind: String, Codable {
        case hls
        case file
    }

    enum State: String, Codable {
        case queued
        case running
        case finished
        case failed
        case cancelled
    }

    struct Record: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var urlString: String
        var pageURLString: String
        var filename: String
        var kind: Kind
        var state: State = .queued
        var progress: Double = 0
        var receivedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var message: String = ""
        var createdAt: Date = Date()
        var savedRelativePath: String?

        var isActive: Bool { state == .running || state == .queued }
    }

    static let schemaVersion = 1
    static let userAgent = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    @Published private(set) var records: [Record] = []

    private let session: URLSession
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - 目录

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var downloadsDirectory: URL {
        documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    private var workRoot: URL {
        downloadsDirectory.appendingPathComponent(".work", isDirectory: true)
    }

    private var indexURL: URL {
        downloadsDirectory.appendingPathComponent("index.json")
    }

    private func workDirectory(for id: UUID) -> URL {
        workRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - 生命周期

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 3600
        // 关掉 waitsForConnectivity，否则断网时任务会一直挂着不报错
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
        loadIndex()
    }

    /// 冷启动时把上次没跑完的任务接上。证书到期被杀进程后，这一步是续传的关键。
    func resumeInterrupted() {
        for record in records where record.state == .running {
            update(record.id) { $0.state = .queued; $0.message = "已排队，准备续传" }
        }
        for record in records where record.state == .queued {
            start(record.id)
        }
    }

    // MARK: - 入队

    @discardableResult
    func enqueue(urlString: String, pageURLString: String, preferredName: String? = nil) -> UUID? {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        if let existing = records.first(where: { $0.urlString == urlString && $0.isActive }) {
            return existing.id
        }

        let kind: Kind = urlString.lowercased().contains(".m3u8") ? .hls : .file
        let name = Self.makeFilename(url: url, kind: kind, preferredName: preferredName)

        let record = Record(
            urlString: urlString,
            pageURLString: pageURLString,
            filename: name,
            kind: kind,
            message: "等待开始"
        )
        records.insert(record, at: 0)
        saveIndex()
        start(record.id)
        return record.id
    }

    // MARK: - 控制

    func start(_ id: UUID) {
        guard runningTasks[id] == nil,
              let record = records.first(where: { $0.id == id }),
              record.state == .queued || record.state == .failed else { return }

        update(id) { $0.state = .running; $0.message = "开始下载"; $0.progress = 0 }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id)
        }
        runningTasks[id] = task
    }

    func pause(_ id: UUID) {
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
        update(id) { $0.state = .queued; $0.message = "已暂停，可继续" }
        saveIndex()
    }

    func resume(_ id: UUID) {
        update(id) { if $0.state == .queued { $0.message = "继续下载" } }
        start(id)
    }

    func retry(_ id: UUID) {
        update(id) { $0.state = .queued; $0.message = "重试"; $0.progress = 0 }
        start(id)
    }

    func delete(_ id: UUID) {
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
        if let record = records.first(where: { $0.id == id }), let path = record.savedRelativePath {
            try? FileManager.default.removeItem(at: documentsDirectory.appendingPathComponent(path))
        }
        try? FileManager.default.removeItem(at: workDirectory(for: id))
        records.removeAll { $0.id == id }
        saveIndex()
    }

    func clearFinished() {
        for record in records where record.state == .finished || record.state == .failed || record.state == .cancelled {
            delete(record.id)
        }
    }

    // MARK: - 执行

    private func run(id: UUID) async {
        defer { runningTasks[id] = nil }
        guard let record = records.first(where: { $0.id == id }) else { return }

        do {
            let produced: URL
            switch record.kind {
            case .hls:
                produced = try await runHLS(record: record)
            case .file:
                produced = try await runDirect(record: record)
            }

            try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            let destination = uniqueDestination(named: record.filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: produced, to: destination)
            try? FileManager.default.removeItem(at: workDirectory(for: id))

            let relative = destination.path.replacingOccurrences(of: documentsDirectory.path + "/", with: "")
            update(id) {
                $0.state = .finished
                $0.progress = 1
                $0.message = "已保存：\(destination.lastPathComponent)"
                $0.savedRelativePath = relative
            }
            saveIndex()
        } catch is CancellationError {
            update(id) { $0.state = .queued; $0.message = "已暂停" }
            saveIndex()
        } catch {
            update(id) {
                $0.state = .failed
                $0.message = error.localizedDescription
            }
            saveIndex()
        }
    }

    private func runHLS(record: Record) async throws -> URL {
        guard let url = URL(string: record.urlString) else {
            throw HLSError.badPlaylist("URL 无效")
        }
        let directory = workDirectory(for: record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let worker = HLSWorker(options: HLSWorker.Options(
            referer: record.pageURLString,
            userAgent: Self.userAgent,
            concurrency: 4
        ))

        let outcome: HLSWorker.Outcome
        do {
            outcome = try await worker.download(playlistURL: url, workDir: directory) { ratio, text in
                Task { @MainActor [weak self] in
                    self?.updateProgress(id: record.id, ratio: ratio, message: text)
                }
            }
        } catch {
            // 把失败的地址尾巴带上，否则用户没法告诉我具体是哪个流出的问题
            let tail = record.urlString.count > 90 ? String(record.urlString.suffix(90)) : record.urlString
            throw HLSError.unsupported("\(error.localizedDescription) ← \(tail)")
        }

        if !outcome.note.isEmpty {
            Task { @MainActor [weak self] in
                self?.update(record.id) { $0.message = outcome.note }
            }
        }
        return outcome.fileURL
    }

    private func runDirect(record: Record) async throws -> URL {
        guard let url = URL(string: record.urlString) else {
            throw HLSError.badPlaylist("URL 无效")
        }
        let directory = workDirectory(for: record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partURL = directory.appendingPathComponent("partial.bin")

        var received: Int64 = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: partURL.path),
           let size = attributes[.size] as? NSNumber {
            received = size.int64Value
        }
        if received > 0 {
            updateProgress(id: record.id, ratio: 0, message: "从 \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) 处续传")
        }

        let chunk: Int64 = 4 * 1024 * 1024
        var total: Int64 = 0

        while true {
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://\(url.host ?? "")/", forHTTPHeaderField: "Origin")
            if !record.pageURLString.isEmpty {
                request.setValue(record.pageURLString, forHTTPHeaderField: "Referer")
            }
            request.setValue("bytes=\(received)-\(received + chunk - 1)", forHTTPHeaderField: "Range")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HLSError.badPlaylist("无响应")
            }
            if http.statusCode == 416 { break }
            guard (200..<300).contains(http.statusCode) else {
                throw HLSError.http(http.statusCode)
            }

            if http.statusCode == 200 {
                // 服务器不支持 Range，一次给了整份文件。已有半截必须先清掉，否则会重复拼接。
                if received > 0 {
                    try? FileManager.default.removeItem(at: partURL)
                    received = 0
                }
                total = http.expectedContentLength > 0 ? http.expectedContentLength : Int64(data.count)
            } else if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                      let totalText = contentRange.split(separator: "/").last,
                      let parsed = Int64(totalText) {
                total = parsed
            }

            try append(data, to: partURL)
            received += Int64(data.count)

            let ratio = total > 0 ? min(1, Double(received) / Double(total)) : 0
            updateProgress(
                id: record.id,
                ratio: ratio,
                message: total > 0
                    ? "\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                    : ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            )

            if http.statusCode == 200 { break }
            if data.isEmpty { break }
            if total > 0 && received >= total { break }
            if Int64(data.count) < chunk { break }
        }

        guard FileManager.default.fileExists(atPath: partURL.path) else {
            throw HLSError.empty
        }
        return partURL
    }

    private func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func uniqueDestination(named name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = downloadsDirectory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let filename = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = downloadsDirectory.appendingPathComponent(filename)
            counter += 1
        }
        return candidate
    }

    // MARK: - 状态

    private func update(_ id: UUID, _ body: (inout Record) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index])
    }

    private func updateProgress(id: UUID, ratio: Double, message: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].progress = max(0, min(1, ratio))
        records[index].message = message
    }

    // MARK: - 持久化

    private struct IndexFile: Codable {
        var schemaVersion: Int
        var records: [Record]
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let file = try? JSONDecoder().decode(IndexFile.self, from: data) else {
            records = []
            return
        }
        // 旧版本数据只做最小兼容：schemaVersion 小于当前值时字段缺失用默认值兜住。
        records = file.records
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            let file = IndexFile(schemaVersion: Self.schemaVersion, records: records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            // 索引写失败不影响已下载的文件本身
        }
    }

    // MARK: - 文件名

    static func makeFilename(url: URL, kind: Kind, preferredName: String?) -> String {
        var base = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if base.isEmpty {
            base = (url.path as NSString).lastPathComponent
        }
        if base.isEmpty { base = "video" }

        // 去掉查询串残留和非法字符
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        base = base.components(separatedBy: illegal).joined(separator: "_")

        // 统一用扩展名收敛，避免出现 movie.mp4.mp4
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension.lowercased()
        let videoExtensions = ["mp4", "m4v", "mov", "webm", "ts", "flv", "mkv"]

        var result: String
        if kind == .hls {
            // HLS 合并后一律是 mp4
            result = "\(stem).mp4"
        } else if videoExtensions.contains(ext) {
            result = base
        } else if ext.isEmpty {
            result = "\(base).mp4"
        } else {
            result = "\(stem).mp4"
        }

        if result.count > 120 {
            let suffix = (result as NSString).pathExtension
            let head = (result as NSString).deletingPathExtension
            result = String(head.prefix(110)) + (suffix.isEmpty ? "" : "." + suffix)
        }
        return result
    }
}
