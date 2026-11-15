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

    var displayName: String {
        if let comps = URLComponents(string: url) {
            let last = (comps.path as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        return url
    }

    var isHLS: Bool { kind == "hls" }
}

/// 注入页面脚本，钩住 fetch / XHR / performance / video 元素，
/// 把发现的可下载媒体通过 WKScriptMessageHandler 回传原生侧。
final class MediaSniffer: NSObject, ObservableObject, WKScriptMessageHandler {
    static let handlerName = "mediaSniffer"
    static let maxItems = 60

    @Published private(set) var candidates: [MediaCandidate] = []

    // MARK: - 注入脚本

    /// 必须在 webView.load 之前加到 userContentController。
    func makeUserScript() -> WKUserScript {
        // 用 raw string：JS 里的正则反斜杠不需要再转义一层。
        let js = #"""
        (function () {
          if (window.__ygSnifferInstalled) { return; }
          window.__ygSnifferInstalled = true;

          var seen = {};
          var MEDIA_RE = /\.(m3u8|mpd|mp4|m4v|webm|mov|flv|ts)(\?|#|$)/i;

          function kindOf(u) {
            if (/\.m3u8(\?|#|$)/i.test(u)) { return 'hls'; }
            if (/\.mpd(\?|#|$)/i.test(u)) { return 'dash'; }
            return 'file';
          }

          function post(raw, source) {
            if (!raw || typeof raw !== 'string') { return; }
            var s = raw.trim();
            if (!s) { return; }
            if (s.indexOf('blob:') === 0 || s.indexOf('data:') === 0) { return; }

            var abs;
            try { abs = new URL(s, location.href).href; } catch (e) { return; }
            if (!MEDIA_RE.test(abs)) { return; }
            if (seen[abs]) { return; }
            seen[abs] = 1;

            try {
              window.webkit.messageHandlers.mediaSniffer.postMessage({
                url: abs,
                kind: kindOf(abs),
                source: source,
                page: location.href
              });
            } catch (e) {}
          }

          // 1) 已经发生过的网络请求。这是最可靠的一路：
          //    能捞到脚本注入之前就加载完的流，也能捞到 hls.js 内部的请求。
          function scanPerformance() {
            try {
              var list = performance.getEntriesByType('resource') || [];
              for (var i = 0; i < list.length; i++) { post(list[i].name, 'perf'); }
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

          // 4) DOM 里的 video / source
          function scanDom() {
            try {
              var els = document.querySelectorAll('video, audio, source');
              for (var i = 0; i < els.length; i++) {
                var el = els[i];
                post(el.src, 'dom');
                post(el.currentSrc, 'dom');
                if (el.querySelectorAll) {
                  var inner = el.querySelectorAll('source');
                  for (var j = 0; j < inner.length; j++) { post(inner[j].src, 'dom'); }
                }
              }
            } catch (e) {}
          }

          function scanAll() { scanPerformance(); scanDom(); }

          scanAll();
          setTimeout(scanAll, 600);
          setTimeout(scanAll, 1800);
          setTimeout(scanAll, 4000);
          setTimeout(scanAll, 9000);

          // 定时扫 5 分钟就停，避免长期占 CPU
          var ticks = 0;
          var timer = setInterval(function () {
            ticks += 1;
            scanAll();
            if (ticks > 75) { clearInterval(timer); }
          }, 4000);

          try {
            var observer = new MutationObserver(function () { scanDom(); });
            observer.observe(document.documentElement || document, {
              childList: true,
              subtree: true,
              attributes: true,
              attributeFilter: ['src']
            });
          } catch (e) {}
        })();
        """#
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - 收集

    func reset() {
        DispatchQueue.main.async { self.candidates = [] }
    }

    func add(_ candidate: MediaCandidate) {
        if let index = candidates.firstIndex(where: { $0.url == candidate.url }) {
            // 已知地址，只更新来源，避免列表被同一个流刷屏
            if candidates[index].source != candidate.source { return }
            return
        }
        candidates.insert(candidate, at: 0)
        if candidates.count > Self.maxItems {
            candidates.removeLast(candidates.count - Self.maxItems)
        }
        sortCandidates()
    }

    private func sortCandidates() {
        candidates.sort { lhs, rhs in
            if lhs.isHLS != rhs.isHLS { return lhs.isHLS }
            return lhs.foundAt > rhs.foundAt
        }
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
        DispatchQueue.main.async { self.add(candidate) }
    }
}
