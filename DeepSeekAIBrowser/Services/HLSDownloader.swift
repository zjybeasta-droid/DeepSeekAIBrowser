import Foundation
import AVFoundation
import CommonCrypto

enum HLSError: LocalizedError {
    case liveStream
    case drm(String)
    case unsupported(String)
    case badPlaylist(String)
    case empty
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .liveStream:
            return "这是直播流（播放列表没有 EXT-X-ENDLIST），无法按文件下载。"
        case .drm(let detail):
            return "受 DRM 保护：\(detail)。Netflix / Disney+ 这类加密流拿不到可播放文件。"
        case .unsupported(let detail):
            return "暂不支持：\(detail)"
        case .badPlaylist(let detail):
            return "播放列表解析失败：\(detail)"
        case .empty:
            return "播放列表里没有任何分片。"
        case .http(let code):
            return "服务器返回 HTTP \(code)。多数情况是缺少 Referer 或 UA，被 CDN 拦了。"
        }
    }
}

/// AES-128 密钥缓存。同一个密钥会被所有分片复用，不能每片都重新请求。
private final class HLSKeyCache {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    func data(for url: URL) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[url.absoluteString]
    }

    func store(_ data: Data, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        storage[url.absoluteString] = data
    }
}

struct HLSKey {
    var uri: URL
    var iv: Data?
}

struct HLSWorker {
    struct Options {
        var referer: String = ""
        var userAgent: String = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        var concurrency: Int = 4
        var maxSegments: Int = 20000
        /// 从 WKWebView 的 WKWebsiteDataStore 抄过来的 Cookie。
        /// 不带这些，带防盗链的 CDN 会直接 403。
        var cookies: [HTTPCookie] = []
    }

    /// 按目标 URL 过滤出该带的 Cookie，拼成 Cookie 头。
    /// 域名用后缀匹配（.surrit.com 要能匹配 surrit.com 和子域），路径用前缀匹配。
    static func cookieHeader(for url: URL, cookies: [HTTPCookie]) -> String {
        guard let host = url.host?.lowercased() else { return "" }
        let path = url.path.isEmpty ? "/" : url.path
        let matched = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain.lowercased()
            guard !domain.isEmpty else { return false }
            let hostMatches = host == domain || host.hasSuffix("." + domain)
            guard hostMatches else { return false }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            return path.hasPrefix(cookiePath)
        }
        guard !matched.isEmpty else { return "" }
        return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    struct Outcome {
        var fileURL: URL
        var segmentCount: Int
        var fragmented: Bool
        var note: String
    }

    let options: Options
    private let session: URLSession
    private let keyCache = HLSKeyCache()

    init(options: Options) {
        self.options = options
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpMaximumConnectionsPerHost = max(2, options.concurrency + 1)
        // 不能开 waitsForConnectivity：系统判定"暂时没网"时会一直挂着不报错，
        // 表现就是任务永远停在"读取播放列表…"。宁可快速失败给出错误。
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - 对外入口

    func download(playlistURL: URL, workDir: URL, progress: @escaping (Double, String) -> Void) async throws -> Outcome {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        progress(0.02, "读取播放列表…")
        dlog("HLS 开始 playlist=\(playlistURL.absoluteString)")
        let media = try await resolveMediaPlaylist(startingAt: playlistURL)

        guard media.endList else {
            dlog("✗ 没有 EXT-X-ENDLIST，判定为直播流")
            throw HLSError.liveStream
        }
        guard !media.segments.isEmpty else {
            dlog("✗ 播放列表解析出 0 个分片")
            throw HLSError.empty
        }
        guard media.segments.count <= options.maxSegments else {
            throw HLSError.unsupported("分片数量 \(media.segments.count) 超出上限")
        }
        dlog("播放列表 OK: \(media.segments.count) 个分片, initMap=\(media.initMap == nil ? "无" : "有")")

        var initData: Data?
        if let map = media.initMap {
            progress(0.05, "下载初始化段…")
            initData = try await fetch(map)
        }

        let total = media.segments.count
        let batch = max(1, min(8, options.concurrency))
        var cursor = 0
        while cursor < total {
            let upper = min(cursor + batch, total)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in cursor..<upper {
                    group.addTask {
                        try await self.fetchSegment(index: index, media: media, workDir: workDir)
                    }
                }
                try await group.waitForAll()
            }
            cursor = upper
            let ratio = Double(cursor) / Double(total)
            progress(0.05 + ratio * 0.85, "分片 \(cursor)/\(total)")
        }

        progress(0.92, "合并分片…")
        let fragmented = (initData != nil)
        let merged = try merge(media: media, initData: initData, workDir: workDir, fragmented: fragmented)

        if fragmented {
            progress(0.99, "完成")
            return Outcome(fileURL: merged, segmentCount: total, fragmented: true, note: "fMP4 直接拼接")
        }

        progress(0.95, "转封装为 MP4…")
        let mp4 = workDir.appendingPathComponent("output.mp4")
        do {
            try await Self.remuxTS(merged, to: mp4)
            try? FileManager.default.removeItem(at: merged)
            progress(0.99, "完成")
            return Outcome(fileURL: mp4, segmentCount: total, fragmented: false, note: "TS 已转封装为 MP4")
        } catch {
            progress(0.99, "完成（保留 TS）")
            return Outcome(fileURL: merged, segmentCount: total, fragmented: false, note: "转封装失败，已保留 .ts：\(error.localizedDescription)")
        }
    }

    // MARK: - 播放列表

    struct MediaPlaylist {
        var segments: [(url: URL, key: HLSKey?)]
        var initMap: URL?
        var endList: Bool
    }

    private func resolveMediaPlaylist(startingAt url: URL) async throws -> MediaPlaylist {
        var current = url
        for level in 0..<4 {
            let text = try await fetchText(current)
            if let variant = Self.bestVariant(in: text, baseURL: current) {
                dlog("  第\(level + 1)层是主列表，选最高码率 → \(variant.absoluteString)")
                current = variant
                continue
            }
            let preview = text.components(separatedBy: .newlines).prefix(3).joined(separator: " | ")
            dlog("  第\(level + 1)层按媒体列表解析，开头: \(preview)")
            return try Self.parseMediaPlaylist(text, baseURL: current)
        }
        throw HLSError.badPlaylist("嵌套层级过深")
    }

    /// 主播放列表里挑码率最高的一路。
    static func bestVariant(in text: String, baseURL: URL) -> URL? {
        guard text.contains("#EXT-X-STREAM-INF") else { return nil }
        var bestBandwidth = -1
        var bestURL: URL?
        var pendingBandwidth = -1
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = attributes(from: String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                pendingBandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0
                continue
            }
            if line.hasPrefix("#") { continue }
            if let candidate = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                if pendingBandwidth > bestBandwidth {
                    bestBandwidth = pendingBandwidth
                    bestURL = candidate
                }
            }
            pendingBandwidth = -1
        }
        return bestURL
    }

    static func parseMediaPlaylist(_ text: String, baseURL: URL) throws -> MediaPlaylist {
        var segments: [(URL, HLSKey?)] = []
        var initMap: URL?
        var currentKey: HLSKey?
        var endList = false

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(from: String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = (attrs["METHOD"] ?? "NONE").uppercased()
                if method == "NONE" {
                    currentKey = nil
                } else if method == "AES-128" {
                    guard let uriText = attrs["URI"],
                          let keyURL = URL(string: uriText, relativeTo: baseURL)?.absoluteURL else {
                        throw HLSError.badPlaylist("AES-128 缺少 URI")
                    }
                    currentKey = HLSKey(uri: keyURL, iv: attrs["IV"].flatMap { parseIV($0) })
                } else {
                    throw HLSError.drm("加密方式 \(method)")
                }
                continue
            }

            if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(from: String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uriText = attrs["URI"] {
                    initMap = URL(string: uriText, relativeTo: baseURL)?.absoluteURL
                }
                continue
            }

            if line.hasPrefix("#EXT-X-BYTERANGE") {
                throw HLSError.unsupported("播放列表使用了 EXT-X-BYTERANGE")
            }

            if line.hasPrefix("#EXT-X-ENDLIST") {
                endList = true
                continue
            }

            if line.hasPrefix("#") { continue }

            guard let segmentURL = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
            segments.append((segmentURL, currentKey))
        }

        return MediaPlaylist(segments: segments, initMap: initMap, endList: endList)
    }

    /// `IV=0x0123456789ABCDEF0123456789ABCDEF`
    static func parseIV(_ text: String) -> Data? {
        var hex = text
        if hex.lowercased().hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        if hex.count % 2 == 1 { hex = "0" + hex }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        guard data.count == 16 else { return nil }
        return data
    }

    /// 解析 `BANDWIDTH=1000,CODECS="a,b",RESOLUTION=1x2` 这种属性串（引号内的逗号不能切）。
    static func attributes(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inQuotes = false
        var readingKey = true
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes && character == "=" {
                readingKey = false
                continue
            }
            if !inQuotes && character == "," {
                if !key.isEmpty { result[key] = value }
                key = ""
                value = ""
                readingKey = true
                continue
            }
            if readingKey { key.append(character) } else { value.append(character) }
        }
        if !key.isEmpty { result[key] = value }
        return result
    }

    // MARK: - 网络

    private func makeRequest(_ url: URL, range: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if !options.referer.isEmpty {
            request.setValue(options.referer, forHTTPHeaderField: "Referer")
            // Origin 必须是页面自己的源，不是 CDN 的源。
            // 之前写成 CDN 自己，等于告诉服务器"我来自 CDN"，反而更像爬虫。
            if let origin = URL(string: options.referer), let scheme = origin.scheme, let host = origin.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }
        let cookie = Self.cookieHeader(for: url, cookies: options.cookies)
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return request
    }

    /// 带硬超时的请求。URLSession 自己的超时在某些网络下不会按时触发，
    /// 这里再抢一个时钟，保证任务不会无限停在"读取播放列表"。
    private func fetchData(_ url: URL, timeout: UInt64 = 20, quiet: Bool = false) async throws -> Data {
        let request = makeRequest(url)
        if !quiet {
            let referer = options.referer.isEmpty ? "(空)" : options.referer
            let hasCookie = Self.cookieHeader(for: url, cookies: options.cookies).isEmpty ? "无" : "已带"
            dlog("GET \(url.absoluteString)")
            dlog("    Referer=\(referer)  Cookie=\(hasCookie)")
        }

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [session] in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    dlog("    ✗ 没有 HTTP 响应")
                    throw HLSError.badPlaylist("服务器没有返回 HTTP 响应")
                }
                if !quiet {
                    let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "(无)"
                    dlog("    ← HTTP \(http.statusCode)  \(data.count) B  \(mime)")
                }

                guard (200..<300).contains(http.statusCode) else {
                    // 把响应体开头打进日志：403 时通常是一段 HTML 说明，能看出是防盗链还是过期
                    let head = String(data: data.prefix(200), encoding: .utf8) ?? ""
                    dlog("    ✗ HTTP \(http.statusCode) \(url.lastPathComponent) 响应体开头: \(head.replacingOccurrences(of: "\n", with: " "))")
                    let tail = url.absoluteString.count > 90 ? String(url.absoluteString.suffix(90)) : url.absoluteString
                    throw HLSError.unsupported("HTTP \(http.statusCode)（\(tail)）")
                }
                return data
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                dlog("    ✗ 超时 \(timeout)s")
                throw HLSError.unsupported("请求超时 \(timeout)s，可能被 CDN 拦了或地址已过期")
            }
            guard let first = try await group.next() else {
                throw HLSError.badPlaylist("请求未返回")
            }
            group.cancelAll()
            return first
        }
    }

    private func fetch(_ url: URL, timeout: UInt64 = 20, quiet: Bool = true) async throws -> Data {
        try await fetchData(url, timeout: timeout, quiet: quiet)
    }

    private func fetch(_ url: URL, timeout: UInt64 = 20) async throws -> Data {
        try await fetchData(url, timeout: timeout)
    }

    private func fetchText(_ url: URL) async throws -> String {
        let data = try await fetchData(url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw HLSError.badPlaylist("无法解码文本")
        }
        return text
    }

    /// 单条请求是否属于"值得重试"的临时故障。
    /// 1875 个分片的任务里，Cloudflare 掐一两次连接是常态，
    /// 一次失败就整条任务报废是不可接受的。
    static func isTransient(_ error: Error) -> Bool {
        if let hls = error as? HLSError {
            if case .unsupported(let text) = hls {
                return text.contains("超时") || text.contains("HTTP 5") || text.contains("HTTP 429")
            }
            return false
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorCannotFindHost,
             NSURLErrorHTTPTooManyRedirects,
             NSURLErrorBadServerResponse:
            return true
        default:
            return false
        }
    }

    private func fetchSegment(index: Int, media: MediaPlaylist, workDir: URL) async throws {
        let destination = workDir.appendingPathComponent(String(format: "seg_%06d.bin", index))
        if let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int,
           size > 0 {
            return   // 上次已经下好，跳过 —— 这就是断点续传
        }

        let entry = media.segments[index]
        var payload = try await withRetry(index: index) {
            try await self.fetch(entry.url, timeout: 60)
        }

        if let key = entry.key {
            let keyData: Data
            if let cached = keyCache.data(for: key.uri) {
                keyData = cached
            } else {
                let fetched = try await withRetry(index: index, label: "密钥") {
                    try await self.fetch(key.uri, timeout: 30)
                }
                keyCache.store(fetched, for: key.uri)
                keyData = fetched
            }
            let iv = key.iv ?? Self.sequenceIV(index)
            payload = try Self.aes128Decrypt(payload, key: keyData, iv: iv)
        }

        try payload.write(to: destination, options: .atomic)
    }

    /// 最多 4 次尝试，退避 1s / 3s / 8s。
    /// "The network connection was lost" 属于临时故障，重试基本都能过。
    private func withRetry<T>(index: Int, label: String = "分片", body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch {
                attempt += 1
                if Task.isCancelled { throw CancellationError() }
                let transient = Self.isTransient(error)
                guard transient, attempt < 4 else { throw error }
                let delay = [1, 3, 8][min(attempt - 1, 2)]
                dlog("  ↻ \(label)#\(index) 第\(attempt)次失败（\(error.localizedDescription)），\(delay)s 后重试")
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
    }

    /// 没给 IV 时，HLS 规定用分片序号作为 16 字节大端整数。
    static func sequenceIV(_ sequence: Int) -> Data {
        var value = UInt64(sequence).bigEndian
        var data = Data(repeating: 0, count: 8)
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return data
    }

    static func aes128Decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16 else {
            throw HLSError.unsupported("AES-128 的 key / iv 长度不对")
        }
        var output = Data(count: data.count + 16)
        var moved = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBytes -> CCCryptorStatus in
            data.withUnsafeBytes { (inputBytes: UnsafeRawBufferPointer) -> CCCryptorStatus in
                key.withUnsafeBytes { (keyBytes: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    iv.withUnsafeBytes { (ivBytes: UnsafeRawBufferPointer) -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, data.count,
                            outputBytes.baseAddress, outputBytes.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw HLSError.unsupported("AES 解密失败（status=\(status)）")
        }
        return output.prefix(moved)
    }

    // MARK: - 合并

    private func merge(media: MediaPlaylist, initData: Data?, workDir: URL, fragmented: Bool) throws -> URL {
        let output = workDir.appendingPathComponent(fragmented ? "output.mp4" : "output.ts")
        try? FileManager.default.removeItem(at: output)
        FileManager.default.createFile(atPath: output.path, contents: nil)

        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        if let initData {
            try handle.write(contentsOf: initData)
        }
        for index in 0..<media.segments.count {
            let part = workDir.appendingPathComponent(String(format: "seg_%06d.bin", index))
            let data = try Data(contentsOf: part)
            try handle.write(contentsOf: data)
            try? FileManager.default.removeItem(at: part)
        }
        return output
    }

    /// MPEG-TS 按字节拼接后是合法 TS，但存成 .mp4 更容易在别的设备上播。
    /// 用 passthrough 只改容器、不重编码，几乎瞬时完成。
    static func remuxTS(_ input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw HLSError.unsupported("系统无法创建导出会话")
        }
        try? FileManager.default.removeItem(at: output)
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }

        guard exporter.status == .completed else {
            throw HLSError.unsupported(exporter.error?.localizedDescription ?? "转封装失败")
        }
    }
}
