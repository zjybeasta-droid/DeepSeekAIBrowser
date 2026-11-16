import Foundation

/// 网络可达性自检。
///
/// 目的只有一个：把"打不开"拆成可判断的事实。
/// 三个目标依次探测 —— 对照组证明设备本身有网，目标站证明它是否可达，
/// 错误码直接指出是被 DNS 污染、被重置，还是 TLS 被掐。
enum NetCheck {
    struct Result {
        var label: String
        var detail: String
        var ok: Bool
    }

    static func run() async -> [Result] {
        var results: [Result] = []
        // 对照组：先证明这台设备能正常上网，避免把"没网"误判成"站点被墙"
        results.append(await probe(label: "对照 apple.com", urlString: "https://www.apple.com/"))
        results.append(await probe(label: "javrate.com", urlString: "https://javrate.com/"))
        results.append(await probe(label: "www.javrate.com", urlString: "https://www.javrate.com/"))
        return results
    }

    private static func probe(label: String, urlString: String) async -> Result {
        guard let url = URL(string: urlString) else {
            return Result(label: label, detail: "URL 无效", ok: false)
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            let mime = http?.value(forHTTPHeaderField: "Content-Type") ?? "-"
            let finalHost = response.url?.host ?? url.host ?? "-"
            return Result(
                label: label,
                detail: "HTTP \(code) · \(data.count) B · \(mime) · \(finalHost)",
                ok: (200..<400).contains(code)
            )
        } catch {
            let ns = error as NSError
            return Result(
                label: label,
                detail: "\(ns.domain) \(ns.code) \(ns.localizedDescription)\(hint(code: ns.code, domain: ns.domain))",
                ok: false
            )
        }
    }

    /// 把 URLSession 的错误码翻译成人能据此行动的结论
    private static func hint(code: Int, domain: String) -> String {
        guard domain == NSURLErrorDomain else { return "" }
        switch code {
        case -1003:
            return " → 域名解析失败，DNS 被污染或解析不到"
        case -1004:
            return " → 连不上服务器，端口被封或主机不存在"
        case -1005:
            return " → 连接被中断，典型网络层阻断特征"
        case -1009:
            return " → 设备没有网络"
        case -1200, -1202:
            return " → TLS 握手失败，证书被劫持或连接被重置"
        case -1001:
            return " → 超时，包被丢弃"
        default:
            return ""
        }
    }
}
