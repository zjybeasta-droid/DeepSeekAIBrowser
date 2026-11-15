import Foundation
import WebKit

/// 页面上被请求到的媒体地址。
/// 关键点：视频站的播放器普遍用 hls.js，`<video src>` 是 `blob:` 假地址，
/// 真实 m3u8 只存在于 XHR / performance 记录里。只读 DOM 永远找不到，必须钩网络层。
struct MediaCandidate: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var url: String
    /// "hls"（m3u8 播放列表）或 "file"（可直下的整文件）
    var kind: String
    /// 来源：perf / fetch / xhr / dom
    var source: String
    /// 发现它时所在页面，下载时当 Referer 用
    var page: String
    var foundAt: Date = Date()

    var host: String { URL(string: url)?.host ?? "" }

    var isHLS: Bool { kind == "hls" }
    var isMagnet: Bool { kind == "magnet" }

    var displayName: String {
        if isMagnet {
            // magnet:?xt=urn:btih:HASH&dn=文件名&tr=...
            if let range = url.range(of: "dn=") {
                let rest = url[range.upperBound...]
                let name = rest.split(separator: "&").first.map(String.init) ?? ""
                if !name.isEmpty {
                    return name.removingPercentEncoding ?? name
                }
            }
            if let range = url.range(of: "btih:") {
                return "磁力 " + url[range.upperBound...].prefix(12) + "…"
            }
            return "磁力链接"
        }
        if let comps = URLComponents(string: url) {
            let last = (comps.path as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        return url
    }
}

/// 注入页面脚本，钩住 fetch / XHR / performance / video 元素，
/// 把发现的可下载媒体通过 WKScriptMessageHandler 回传原生侧。
///
/// 性能红线（v0.2.0 踩过）：绝对不要把 .ts / .m4s 分片当成候选。
/// 一个视频播放会触发几百个分片请求，每个都推到 SwiftUI 会让主线程瘫痪，
/// 表现就是"视频打不开 / 黑屏 / 一直转圈"。
final class MediaSniffer: NSObject, ObservableObject, WKScriptMessageHandler {
    static let handlerName = "mediaSniffer"
    static let maxItems = 40
    /// 单个页面最多接收多少条桥消息，超了就停，防止异常站点刷爆
    static let maxBridgeMessages = 150

    /// 外部开关。关掉后仍会注入脚本，但原生侧不再收集，UI 立刻安静下来。
    @Published var isEnabled = true
    @Published private(set) var candidates: [MediaCandidate] = []

    private var pending: [MediaCandidate] = []
    private var knownURLs = Set<String>()
    private var isFlushScheduled = false
    private var bridgeMessageCount = 0

    // MARK: - 注入脚本

    /// 必须在 webView.load 之前加到 userContentController。
    func makeUserScript() -> WKUserScript {
        // 用 raw string：JS 里的正则反斜杠不需要再转义一层。
        let js = #"""
        (function () {
          if (window.__ygSnifferInstalled) { return; }
          window.__ygSnifferInstalled = true;

          var seen = {};
          var posted = 0;
          var MAX_POST = 150;
          // 只认"整份媒体"和播放列表。分片（ts / m4s）、密钥、字幕一律不认。
          var MEDIA_RE = /\.(m3u8|mpd|mp4|m4v|webm|mov|flv)(\?|#|$)/i;
          var SEGMENT_RE = /\.(ts|m4s|aac|vtt|key)(\?|#|$)/i;

          function kindOf(u) {
            if (/\.m3u8(\?|#|$)/i.test(u)) { return 'hls'; }
            if (/\.mpd(\?|#|$)/i.test(u)) { return 'dash'; }
            return 'file';
          }

          function post(raw, source) {
            if (posted >= MAX_POST) { return; }
            if (!raw || typeof raw !== 'string') { return; }
            var s = raw.trim();
            if (!s) { return; }
            if (s.indexOf('blob:') === 0 || s.indexOf('data:') === 0) { return; }

            // 磁力链接：不是可下载的 URL，但用户能复制到别处用
            if (s.indexOf('magnet:?') === 0) {
              if (seen[s]) { return; }
              seen[s] = 1;
              posted += 1;
              try {
                window.webkit.messageHandlers.mediaSniffer.postMessage({
                  url: s,
                  kind: 'magnet',
                  source: source,
                  page: location.href
                });
              } catch (e) {}
              return;
            }

            // 先做便宜的字符串判断，绝大多数资源在这里就被淘汰，
            // 不再构造 URL 对象 —— 视频页的资源条目能有几千条。
            if (SEGMENT_RE.test(s)) { return; }
            if (!MEDIA_RE.test(s)) { return; }

            var abs;
            try { abs = new URL(s, location.href).href; } catch (e) { return; }
            if (seen[abs]) { return; }
            seen[abs] = 1;
            posted += 1;

            try {
              window.webkit.messageHandlers.mediaSniffer.postMessage({
                url: abs,
                kind: kindOf(abs),
                source: source,
                page: location.href
              });
            } catch (e) {}

            // 预热：首播慢的一大半时间花在 DNS + TCP + TLS 握手上。
            // 这里提前把连接建好，播放器真正请求分片时直接复用。
            warm(abs, kindOf(abs));
          }

          var warmed = {};
          function warm(url, kind) {
            try {
              if (kind !== 'hls') { return; }
              var origin;
              try { origin = new URL(url, location.href).origin; } catch (e) { return; }
              if (warmed[origin]) { return; }
              warmed[origin] = 1;

              var link = document.createElement('link');
              link.rel = 'preconnect';
              link.href = origin;
              link.crossOrigin = 'anonymous';
              (document.head || document.documentElement).appendChild(link);

              // 顺手把播放列表拉进缓存，播放器再要时就是命中
              try { fetch(url, { credentials: 'include' }).catch(function () {}); } catch (e) {}
            } catch (e) {}
          }

          // 1) 已经发生过的网络请求。最可靠的一路：
          //    能捞到脚本注入之前加载完的流，也能捞到 hls.js 内部的请求。
          function scanPerformance() {
            try {
              var list = performance.getEntriesByType('resource') || [];
              var start = list.length > 2500 ? list.length - 2500 : 0;
              for (var i = start; i < list.length; i++) { post(list[i].name, 'perf'); }
            } catch (e) {}
          }

          // 2) fetch
          try {
            var rawFetch = window.fetch;
            if (rawFetch) {
              window.fetch = function () {
                try {
                  var first = arguments[0];
                  post(typeof first === 'string' ? first : (first && first.url), 'fetch');
                } catch (e) {}
                return rawFetch.apply(this, arguments);
              };
            }
          } catch (e) {}

          // 3) XMLHttpRequest —— hls.js / dash.js 走的就是这条
          try {
            var rawOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function (method, url) {
              try { post(url, 'xhr'); } catch (e) {}
              return rawOpen.apply(this, arguments);
            };
          } catch (e) {}

          // 4) DOM 里的 video / source（只在扫描时读，不挂 MutationObserver）
          function scanDom() {
            try {
              var els = document.querySelectorAll('video, audio, source');
              for (var i = 0; i < els.length; i++) {
                var el = els[i];
                post(el.src, 'dom');
                post(el.currentSrc, 'dom');
                // 很多站的播放器默认 preload=none，用户点了才去拉。
                // 改成 auto 会让首帧来得更快。
                if (el.tagName === 'VIDEO' && el.preload !== 'auto') {
                  try { el.preload = 'auto'; } catch (e) {}
                }
              }
            } catch (e) {}
          }

          // 5) 磁力链接。这类站点通常每条视频配一个 magnet，
          //    iOS 上没有 BT 客户端能直接吃，但抓出来能让用户复制到别处。
          function scanMagnets() {
            try {
              var links = document.querySelectorAll('a[href^="magnet:"]');
              for (var i = 0; i < links.length && i < 20; i++) {
                post(links[i].getAttribute('href') || links[i].href, 'dom');
              }
            } catch (e) {}
            try {
              var text = (document.body && document.body.innerText) || '';
              if (text.indexOf('magnet:') >= 0) {
                var found = text.match(/magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,40}[^\s"'<>]*/g);
                if (found) {
                  for (var j = 0; j < found.length && j < 10; j++) { post(found[j], 'text'); }
                }
              }
            } catch (e) {}
          }

          function scanAll() { scanPerformance(); scanDom(); scanMagnets(); }

          scanAll();
          setTimeout(scanAll, 700);
          setTimeout(scanAll, 2000);
          setTimeout(scanAll, 5000);
          setTimeout(scanAll, 10000);

          // 低速轮询，6 秒一次，最多 60 次（约 6 分钟）后自动停。
          // v0.2.0 用的 MutationObserver + 4 秒轮询 + .ts 命中，会把主线程拖死。
          var ticks = 0;
          var timer = setInterval(function () {
            ticks += 1;
            scanAll();
            if (ticks > 60) { clearInterval(timer); }
          }, 6000);
        })();
        """#
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - 收集

    func reset() {
        DispatchQueue.main.async {
            self.candidates = []
            self.pending = []
            self.knownURLs = []
            self.bridgeMessageCount = 0
        }
    }

    /// 从桥接线程调度过来，必须在主线程执行。
    fileprivate func accept(_ candidate: MediaCandidate) {
        guard isEnabled else { return }
        guard bridgeMessageCount < Self.maxBridgeMessages else { return }
        bridgeMessageCount += 1

        if knownURLs.contains(candidate.url) { return }
        knownURLs.insert(candidate.url)
        dlog("嗅探命中 [\(candidate.kind)/\(candidate.source)] \(candidate.url)")
        pending.append(candidate)
        scheduleFlush()
    }

    /// 关键：桥消息可能每秒来几十条，但 UI 每 0.6 秒最多更新一次。
    /// 这样 SwiftUI 不会因为持续 @Published 变化而把 WKWebView 拖死。
    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        isFlushScheduled = false
        guard !pending.isEmpty else { return }

        var merged = candidates
        merged.append(contentsOf: pending)
        pending.removeAll()

        merged.sort { lhs, rhs in
            if lhs.isHLS != rhs.isHLS { return lhs.isHLS }
            return lhs.foundAt > rhs.foundAt
        }
        if merged.count > Self.maxItems {
            merged.removeLast(merged.count - Self.maxItems)
        }
        candidates = merged
    }

    /// 给 AI 用的纯文本摘要。有了这段，模型才不会说"页面没有具体链接"。
    func contextForAgent() -> String {
        guard !candidates.isEmpty else { return "（尚未嗅探到任何媒体地址，可提示用户先播放视频再重试）" }
        return candidates.prefix(12).map { item in
            "- \(item.isHLS ? "HLS播放列表" : "直链文件") | \(item.url)"
        }.joined(separator: "\n")
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let url = body["url"] as? String,
              !url.isEmpty else { return }

        let candidate = MediaCandidate(
            url: url,
            kind: (body["kind"] as? String) ?? "file",
            source: (body["source"] as? String) ?? "dom",
            page: (body["page"] as? String) ?? ""
        )
        DispatchQueue.main.async { self.accept(candidate) }
    }
}
