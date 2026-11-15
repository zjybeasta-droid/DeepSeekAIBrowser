import Foundation

/// App 内部诊断日志。
///
/// 为什么需要它：开发机是 Windows，没法连 LLDB、没法看 Xcode 控制台。
/// 所以把"每次网络请求 / 每次嗅探命中 / 每次状态变化"都记下来，
/// 显示在 App 里，用户截一张图就等于把运行时状态传出来了。
///
/// 只保留最近 500 行，超出丢弃最旧的，避免长期运行吃内存。
final class DiagnosticLog: ObservableObject {
    static let shared = DiagnosticLog()

    @Published private(set) var lines: [String] = []

    private let lock = NSLock()
    private var buffer: [String] = []
    private var lastPublish = Date.distantPast
    private let maxLines = 500
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ message: String) {
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] \(message)"

        lock.lock()
        buffer.append(line)
        if buffer.count > maxLines {
            buffer.removeFirst(buffer.count - maxLines)
        }
        let snapshot = buffer
        let shouldPublish = Date().timeIntervalSince(lastPublish) > 0.25
        if shouldPublish { lastPublish = Date() }
        lock.unlock()

        if shouldPublish {
            DispatchQueue.main.async { self.lines = snapshot }
        }
    }

    func snapshotText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffer.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        DispatchQueue.main.async { self.lines = [] }
    }

    /// 写到 Documents/diagnostic.txt，可通过「文件」App 取出来发给别人。
    @discardableResult
    func writeToDocuments(header: String) -> URL? {
        let text = header + "\n\n" + snapshotText()
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("diagnostic.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// 便捷写法，避免每处都写 DiagnosticLog.shared.log
func dlog(_ message: String) {
    DiagnosticLog.shared.log(message)
}

extension Sequence where Element: Hashable {
    /// 保序去重
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
