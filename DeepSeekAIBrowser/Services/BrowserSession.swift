import Foundation
import WebKit

@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    @Published var currentURL = ""
    @Published var isLoading = false
    @Published var lastError = ""

    /// AI 返回 download 动作时，交给下载管理器处理；不要让 webView 去导航。
    var onDownloadRequest: ((URL, String) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ value: String) {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate) else { lastError = "网址格式不正确"; return }
        webView.load(URLRequest(url: url))
    }

    /// 必须在第一次 load 之前调用，否则首屏的媒体请求会漏掉。
    func attachSniffer(_ sniffer: MediaSniffer) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: MediaSniffer.handlerName)
        controller.add(sniffer, name: MediaSniffer.handlerName)
        controller.addUserScript(sniffer.makeUserScript())
    }

    /// 深度提取：嗅探靠"看它请求了什么"，这里靠"翻它的家底"。
    ///
    /// 有些站的播放器把地址藏在 JSON、内联脚本、data-* 属性或 jwplayer/videojs 的
    /// 运行时对象里，网络还没发出请求就点不动，嗅探等于看不见。这个提取器按
    /// 台站常见的六种藏法逐个翻，返回 [(地址, 命中位置)]。
    func deepExtract() async -> [(String, String)] {
        let body = #"""
        const found = [];
        const seen = {};
        const add = (u, via) => {
          if (!u || typeof u !== 'string') return;
          u = u.trim();
          if (u.length < 12) return;
          if (!/^(https?:)?\/\//.test(u) && !/^magnet:/.test(u)) return;
          if (seen[u]) return;
          seen[u] = 1;
          found.push({ u: u, via: via });
        };
        const grab = (text, via) => {
          if (!text || typeof text !== 'string') return;
          const re = /(?:https?:)?\/\/[^"'\\\s<>]+?\.(?:m3u8|mpd|mp4|m4v|webm)(?:\?[^"'\\\s<>]*)?/g;
          let m; let n = 0;
          while ((m = re.exec(text)) !== null && n < 40) { add(m[0], via); n++; }
        };

        // 1) 重新拉一次自己的 HTML，服务端渲染的地址都在里面
        try {
          const resp = await fetch(location.href, { credentials: 'include', cache: 'no-store' });
          if (resp && resp.ok) grab(await resp.text(), 'page-refetch');
        } catch (e) {}

        // 2) 播放器 DOM 和 data-* 属性
        document.querySelectorAll('video, source').forEach((el) => {
          add(el.src, 'dom');
          add(el.currentSrc, 'dom');
          add(el.getAttribute('data-src'), 'dom-data');
        });
        const attrs = ['data-src', 'data-file', 'data-video', 'data-hls', 'data-mp4', 'data-url', 'data-source'];
        document.querySelectorAll('[data-src],[data-file],[data-video],[data-hls],[data-mp4],[data-url],[data-source]').forEach((el) => {
          attrs.forEach((a) => {
            const v = el.getAttribute(a);
            if (v && /m3u8|mp4|mpd/i.test(v)) add(v, 'attr:' + a);
          });
        });

        // 3) 播放器运行时对象
        const probe = (fn, via) => {
          try {
            const v = fn();
            if (v) { if (typeof v === 'string') add(v, via); else grab(String(v), via); }
          } catch (e) {}
        };
        probe(() => window.jwplayer && window.jwplayer().getPlaylistItem && window.jwplayer().getPlaylistItem().file, 'jwplayer');
        probe(() => window.jwplayer && window.jwplayer().getConfig().sources.map((s) => s.file).join(' '), 'jwplayer-sources');
        probe(() => window.videojs && window.videojs.getAllPlayers && window.videojs.getAllPlayers().map((p) => p.currentSrc()).join(' '), 'videojs');
        probe(() => window.videoUrl, 'global:videoUrl');
        probe(() => window.video_url, 'global:video_url');
        probe(() => window.streamUrl, 'global:streamUrl');
        probe(() => window.hlsUrl, 'global:hlsUrl');
        probe(() => window.hls && window.hls.url, 'hls');
        probe(() => window.player && window.player.src, 'player.src');
        probe(() => window.player && window.player.config && window.player.config.url, 'player.config');
        probe(() => {
          const el = document.querySelector('.dplayer');
          return el && el.dplayer && el.dplayer.video && el.dplayer.video.src;
        }, 'dplayer');
        probe(() => {
          const el = document.querySelector('video');
          return el && el.querySelectorAll && Array.from(el.querySelectorAll('source')).map((s) => s.src).join(' ');
        }, 'video-source');

        // 4) 内联脚本和 JSON 数据块
        document.querySelectorAll('script:not([src])').forEach((s) => grab(s.textContent, 'inline-script'));
        ['__NEXT_DATA__', '__NUXT__', 'player-config', 'video-data', 'app'].forEach((id) => {
          const el = document.getElementById(id);
          if (el) grab(el.textContent, 'data:' + id);
        });

        // 5) 整页源码兜底
        try { grab(document.documentElement.innerHTML.slice(0, 1500000), 'html-source'); } catch (e) {}

        return JSON.stringify(found.slice(0, 80));
        """#

        do {
            let value = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
            guard let text = value as? String,
                  let data = text.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                dlog("深度提取：没有拿到结果")
                return []
            }
            let items: [(String, String)] = raw.compactMap { item in
                guard let url = item["u"] as? String else { return nil }
                return (url, item["via"] as? String ?? "?")
            }
            dlog("=== 深度提取：\(items.count) 条 ===")
            for (url, via) in items {
                dlog("  [\(via)] \(url)")
            }
            if items.isEmpty {
                dlog("  页面里没有明文媒体地址。点一下播放，让它真的开始加载，再试一次。")
            }
            return items
        } catch {
            dlog("深度提取失败：\(error.localizedDescription)")
            return []
        }
    }

    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }

    /// 站点分析：把"这个页面是怎么播放的"一次性问清楚。
    ///
    /// 开发机在 Windows，访问不了这些站点，所以只能在设备上做侦察。
    /// 报告是纯文本，直接进诊断日志，用户截图就等于把现场传出来了。
    func probe() async -> String {
        let script = """
        (() => {
          const lines = [];
          const cut = (s, n) => (s || '-').slice(0, n);
          lines.push('URL: ' + location.href);
          lines.push('TITLE: ' + cut(document.title, 120));
          lines.push('READY: ' + document.readyState);

          const vids = Array.from(document.querySelectorAll('video'));
          lines.push('VIDEO(' + vids.length + ')');
          vids.slice(0, 5).forEach((v, i) => {
            lines.push('  [' + i + '] src=' + cut(v.src, 140) +
                       ' | cur=' + cut(v.currentSrc, 140) +
                       ' | rs=' + v.readyState +
                       ' | dur=' + (isFinite(v.duration) ? v.duration.toFixed(1) : '?') +
                       ' | paused=' + v.paused);
          });

          const srcs = Array.from(document.querySelectorAll('source'));
          lines.push('SOURCE(' + srcs.length + ')');
          srcs.slice(0, 5).forEach((s, i) => lines.push('  [' + i + '] ' + cut(s.src, 140) + ' type=' + cut(s.getAttribute('type'), 40)));

          const frames = Array.from(document.querySelectorAll('iframe'));
          lines.push('IFRAME(' + frames.length + ')');
          frames.slice(0, 8).forEach((f, i) => {
            let host = '';
            try { host = new URL(f.src, location.href).host; } catch (e) {}
            lines.push('  [' + i + '] host=' + host + ' | ' + cut(f.src, 150));
          });

          const scripts = Array.from(document.querySelectorAll('script[src]')).map(s => s.src);
          const hits = scripts.filter(u => /hls|player|jw|plyr|video|stream|embed|m3u8/i.test(u));
          lines.push('PLAYER-SCRIPTS(' + hits.length + '/' + scripts.length + ')');
          hits.slice(0, 8).forEach(u => lines.push('  ' + cut(u, 150)));

          let perf = [];
          try { perf = performance.getEntriesByType('resource') || []; } catch (e) {}
          const media = perf.map(e => e.name).filter(u => /\\.(m3u8|mpd|mp4|m4v|webm|mov|flv)(\\?|#|$)/i.test(u));
          lines.push('PERF-MEDIA(' + media.length + ' / ' + perf.length + ')');
          media.slice(0, 10).forEach(u => lines.push('  ' + cut(u, 170)));

          const magnets = Array.from(document.querySelectorAll('a[href^="magnet:"]')).length;
          lines.push('MAGNET-LINKS: ' + magnets);

          return lines.join('\\n');
        })()
        """
        do {
            let value = try await evaluate(script)
            let text = (value as? String) ?? "(分析无返回)"
            dlog("=== 页面分析 ===\n" + text)
            return text
        } catch {
            let message = "分析失败：\(error.localizedDescription)"
            dlog(message)
            return message
        }
    }

    // MARK: - 下载上下文

    /// 把 WebView 真实的 UA 和 Cookie 交给下载器。
    ///
    /// 这是必须的：WKWebView 的 Cookie 存在它自己的 WKWebsiteDataStore 里，
    /// 而 URLSession 用 HTTPCookieStorage.shared，两边完全不通。
    /// 带 Cookie 的播放器能拿到 200，裸奔的 URLSession 会被 CDN 判 403。
    func downloadContext() async -> (userAgent: String, cookies: [HTTPCookie]) {
        let store = webView.configuration.websiteDataStore.httpCookieStore

        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { list in
                continuation.resume(returning: list)
            }
        }

        var ua = ""
        if let value = try? await evaluate("navigator.userAgent"), let text = value as? String {
            ua = text
        }
        if ua.isEmpty {
            ua = webView.value(forKey: "userAgent") as? String ?? ""
        }

        dlog("下载上下文 UA=\(ua.isEmpty ? "(空)" : ua)")
        dlog("下载上下文 Cookie 共 \(cookies.count) 个：\(cookies.map { $0.domain }.uniqued().joined(separator: ", "))")
        return (ua, cookies)
    }

    func evaluate(_ javascript: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(javascript) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    func snapshot() async -> String {
        let script = """
        (() => {
          const text = (document.body?.innerText || '').slice(0, 9000);
          const nodes = Array.from(document.querySelectorAll('a,button,input,video,source,[role="button"]')).slice(0, 120).map((el, i) => ({
            i, tag: el.tagName,
            text: (el.innerText || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').slice(0, 180),
            href: el.href || '', src: el.currentSrc || el.src || '', type: el.type || ''
          }));
          return JSON.stringify({title: document.title, url: location.href, text, nodes});
        })()
        """
        do { return (try await evaluate(script) as? String) ?? "{}" }
        catch { return "{}" }
    }

    func cleanPageLocally() async {
        let script = """
        (() => {
          const viewport = innerWidth * innerHeight;
          const terms = /广告|推广|关闭|跳过|skip|close|dismiss|ad/i;
          let changed = 0;
          for (const el of Array.from(document.querySelectorAll('body *'))) {
            const style = getComputedStyle(el); const rect = el.getBoundingClientRect();
            const fixed = style.position === 'fixed' || style.position === 'sticky';
            const large = rect.width * rect.height > viewport * 0.12;
            const high = Number.parseInt(style.zIndex || '0', 10) > 20;
            const label = `${el.innerText || ''} ${el.getAttribute('aria-label') || ''} ${el.id || ''} ${el.className || ''}`;
            if (fixed && high && large && terms.test(label)) { el.style.setProperty('display','none','important'); changed += 1; }
          }
          for (const el of Array.from(document.querySelectorAll('button,[role="button"],a'))) {
            const label = `${el.innerText || ''} ${el.getAttribute('aria-label') || ''}`;
            if (/^(关闭|跳过|close|skip|dismiss)$/i.test(label.trim())) { el.click(); changed += 1; }
          }
          return changed;
        })()
        """
        _ = try? await evaluate(script)
    }

    func execute(_ action: BrowserAction) async throws {
        switch action.type {
        case "open_url": if let url = action.url { load(url) }
        case "click": try await click(selector: action.selector)
        case "type": try await type(text: action.text ?? "", selector: action.selector)
        case "scroll": _ = try await evaluate("window.scrollBy({top: \(action.amount ?? 600), behavior: 'smooth'});")
        case "hide":
            if let selector = action.selector {
                let value = String(data: try JSONSerialization.data(withJSONObject: selector), encoding: .utf8) ?? "\"\""
                _ = try await evaluate("document.querySelector(\(value))?.style.setProperty('display','none','important');")
            }
        case "close_popup": await cleanPageLocally()
        case "download": if let url = action.url, let target = URL(string: url) { onDownloadRequest?(target, currentURL) }
        case "wait": try await Task.sleep(for: .milliseconds(650))
        case "finish": break
        default: break
        }
    }

    private func click(selector: String?) async throws {
        guard let selector, !selector.isEmpty else { return }
        let value = String(data: try JSONSerialization.data(withJSONObject: selector), encoding: .utf8) ?? "\"\""
        _ = try await evaluate("document.querySelector(\(value))?.click();")
    }

    private func type(text: String, selector: String?) async throws {
        guard let selector, !selector.isEmpty else { return }
        let selectorValue = String(data: try JSONSerialization.data(withJSONObject: selector), encoding: .utf8) ?? "\"\""
        let textValue = String(data: try JSONSerialization.data(withJSONObject: text), encoding: .utf8) ?? "\"\""
        let script = "(() => { const el = document.querySelector(\(selectorValue)); if (!el) return false; el.focus(); el.value = \(textValue); el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); return true; })()"
        _ = try await evaluate(script)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        dlog("导航开始 \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url?.absoluteString ?? ""
        dlog("页面加载完成 \(currentURL)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
        dlog("✗ 页面加载失败 \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let canShow = navigationResponse.canShowMIMEType
        if !canShow {
            dlog("响应无法直接显示，转为下载 \(navigationResponse.response.url?.absoluteString ?? "?")")
        }
        decisionHandler(canShow ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        completionHandler(directory.appendingPathComponent(suggestedFilename))
    }

    func downloadDidFinish(_ download: WKDownload) {}
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { lastError = error.localizedDescription }
}
