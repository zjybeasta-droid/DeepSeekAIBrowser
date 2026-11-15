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
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = max(2, options.concurrency + 1)
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - 对外入口

    func download(playlistURL: URL, workDir: URL, progress: @escaping (Double, String) -> Void) async throws -> Outcome {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        progress(0.02, "读取播放列表…")
        let media = try await resolveMediaPlaylist(startingAt: playlistURL)

        guard media.endList else { throw HLSError.liveStream }
        guard !media.segments.isEmpty else { throw HLSError.empty }
        guard media.segments.count <= options.maxSegments else {
            throw HLSError.unsupported("分片数量 \(media.segments.count) 超出上限")
        }

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
        for _ in 0..<4 {
            let text = try await fetchText(current)
            if let variant = Self.bestVariant(in: text, baseURL: current) {
                current = variant
                continue
            }
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
        request.setValue("https://\(url.host ?? "")/", forHTTPHeaderField: "Origin")
        if !options.referer.isEmpty {
            request.setValue(options.referer, forHTTPHeaderField: "Referer")
        }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return request
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: makeRequest(url))
        guard let http = response as? HTTPURLResponse else { throw HLSError.badPlaylist("无响应") }
        guard (200..<300).contains(http.statusCode) else { throw HLSError.http(http.statusCode) }
        return data
    }

    private func fetchText(_ url: URL) async throws -> String {
        let data = try await fetch(url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw HLSError.badPlaylist("无法解码文本")
        }
        return text
    }

    private func fetchSegment(index: Int, media: MediaPlaylist, workDir: URL) async throws {
        let destination = workDir.appendingPathComponent(String(format: "seg_%06d.bin", index))
        if let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int,
           size > 0 {
            return   // 上次已经下好，跳过 —— 这就是断点续传
        }

        let entry = media.segments[index]
        var payload = try await fetch(entry.url)

        if let key = entry.key {
            let keyData: Data
            if let cached = keyCache.data(for: key.uri) {
                keyData = cached
            } else {
                let fetched = try await fetch(key.uri)
                keyCache.store(fetched, for: key.uri)
                keyData = fetched
            }
            let iv = key.iv ?? Self.sequenceIV(index)
            payload = try Self.aes128Decrypt(payload, key: keyData, iv: iv)
        }

        try payload.write(to: destination, options: .atomic)
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
                            outputBytes.baseAddress, output.count,
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
