# 返工方案 v2.1（已合并第二轮审查与执行前修正）

> v1 的问题：漏了 CI 打包阶段、并发修复方向写错、m3u8 支持范围过宽、两条验收标准测不了。
> v2.1 已修正。执行顺序：**PR-0 → PR-11，不许跳步**。
> 目标产物：能装到 iPad、能开网页、能下受支持的 fMP4 或 MPEG-TS/AES-128 HLS 视频、能离线播放、AI 能多轮操作页面。

---

## 0. 环境与硬约束

| 事项 | 事实 |
|---|---|
| 开发机 | Windows。**没有** Xcode / xcodebuild / swiftc |
| 编译 | GitHub Actions `macos-14`（工作流已放在 `.github/workflows/ios-build-unsigned.yml`） |
| 产物 | **未签名 `.ipa`**，签名在 iPad 上用 SideStore（免费 Apple ID） |
| CI 里 | 不配证书、不配描述文件、不用 `--allowProvisioningUpdates` |
| Bundle ID | **`com.yg.aibrowser`，永久固定** |
| 设备 | iPad，iPadOS 27.0.1，单设备自用 |

**七条不可违反的约束**：

1. 单 target，不加任何 Extension（免费账号只有 3 个 App 名额）
2. 不用 App Groups / Network Extension / Push / HealthKit（免费账号拿不到描述文件，编译直接失败）
3. 只用公有 API
4. 所有长任务可中断恢复（证书 7 天到期会杀进程）
5. 用户数据与 API Key **不存 Keychain**（换签名身份后条目失效）
6. 所有持久化数据带 `schemaVersion`，升级必须能读旧数据
7. 媒体请求必须带 `Referer` + 桌面 UA

---

## 1. PR-0：CI 打包链（已交付，先验证它能跑）

工作流已经写好：`.github/workflows/ios-build-unsigned.yml`。
**注意**：`scripts/build-simulator.sh` 现在只用于本地模拟器 Debug 构建，不是 iPad 构建入口；iPad 包只走本工作流。

工作流的关键步骤：

```
xcodegen generate
xcodebuild archive -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" EXPANDED_CODE_SIGN_IDENTITY=""
→ 校验 Info.plist（Bundle ID / ATS / FileSharing）；后台 URLSession 的生命周期在 PR-8 通过运行时回调验证，不用 UIBackgroundModes 作为代理断言。
→ Payload/*.app → zip → App-unsigned.ipa
→ upload artifact
```

其中 **Verify Info.plist 这一步不要删**。它挡的是最贵的一类错误：Info.plist 没生效，装上之后表现为「http 页面或媒体请求失败、文件 App 里看不见」，而你在 iPad 上根本看不出原因。后台下载是否恢复则由 PR-8 的 background URLSession 生命周期测试负责。

同时补 `.gitignore`：

```
Support/Info.plist
*.xcodeproj
DerivedData/
.build/
```

**PR-0 验收**：push 到 main，Actions 绿，artifact `unsigned-ipa` 里有 `App-unsigned.ipa`，`unzip -l` 能看到 `Payload/DeepSeekAIBrowser.app/`。

---

## 2. PR-1：project.yml 与 Bundle ID

现状问题：没有 `info:`、没设 `GENERATE_INFOPLIST_FILE`，所有 `INFOPLIST_KEY_*` 被忽略；Bundle ID 还是 `com.example.DeepSeekAIBrowser`。

**整份替换 `project.yml`：**

```yaml
name: DeepSeekAIBrowser
options:
  bundleIdPrefix: com.yg
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "5.0"
    ENABLE_USER_SCRIPT_SANDBOXING: "NO"

targets:
  DeepSeekAIBrowser:
    type: application
    platform: iOS
    sources:
      - path: DeepSeekAIBrowser
        excludes:
          - "Info.plist"
    info:
      path: Support/Info.plist
      properties:
        CFBundleDisplayName: AI浏览器
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        ITSAppUsesNonExemptEncryption: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.yg.aibrowser
        TARGETED_DEVICE_FAMILY: "1,2"
        GENERATE_INFOPLIST_FILE: "NO"
```

要点：
- `info.path` 指向 `Support/Info.plist`，在 sources 之外，避免 "Multiple commands produce Info.plist"
- `Support/Info.plist` 由 `xcodegen generate` 生成，**不提交**
- 当前用全局 `NSAllowsArbitraryLoads`，不再同时声明 `NSAllowsArbitraryLoadsInWebContent`，否则 URLSession 的 HTTP 媒体请求策略会被混淆
- 不把 `UIBackgroundModes` 当作 background URLSession 的成立条件；后台生命周期在 PR-8 实现并实测
- 删掉全部 `INFOPLIST_KEY_*` 行
- 签名相关的 `CODE_SIGNING_*` 不写进 project.yml，由 CI 命令行参数传（本地/CI 共用一个 yml）

**PR-1 验收**：CI 绿，且 Verify Info.plist 那一步全部 `ok`。

**两个已踩过的坑（照抄会直接红）**：

1. `SWIFT_VERSION` 合法值只有 `4.0 / 4.2 / 5.0 / 6.0`。写 `5.9` 会报
   `SWIFT_VERSION '5.9' is unsupported, supported versions are: 4.0, 4.2, 5.0, 6.0.`
2. **必须显式声明 scheme**。XcodeGen 不保证往 `xcshareddata` 写 `.xcscheme`，
   缺了它 CI 报 `does not contain a scheme named DeepSeekAIBrowser`：

```yaml
    scheme:
      build:
        targets:
          DeepSeekAIBrowser: all
      run:
        config: Debug
      profile:
        config: Release
      analyze:
        config: Debug
      archive:
        config: Release
```

项目里没有 test target，所以 scheme 里**不要**写 `test:` 段。

> 以上两点已直接修在项目的 `project.yml` 里，以该文件为准。

---

## 3. PR-2：并发隔离（v1 写错了，以此为准）

**v1 的错误**：说 `WKDownloadDelegate` 回调来自后台线程，所以要拆成"非隔离类"。
**实际**：WebKit 的 delegate 协议在 Swift 6 导入后标注了 `@MainActor`，回调属于主 actor 隔离范围。**现有代码 `@MainActor final class BrowserSession: ..., WKDownloadDelegate` 本身是合法的，不会产生隔离冲突。**

因此这一项降级为**可选的职责拆分**，不是编译修复。

**做法（二选一）**：

A. **先不动它**，让 PR-0 的 CI 跑一次。如果编译通过，就不改。（推荐）

B. 如果要拆，拆出来的代理**必须同样标 `@MainActor`**：

```swift
@MainActor
final class DownloadDelegateProxy: NSObject, WKDownloadDelegate {
    private let directory: URL
    private weak var manager: DownloadManager?

    init(directory: URL, manager: DownloadManager?) {
        self.directory = directory
        self.manager = manager
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        completionHandler(directory.appendingPathComponent(suggestedFilename))
    }

    func downloadDidFinish(_ download: WKDownload) {
        manager?.reload()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSLog("[download] failed: \(error.localizedDescription)")
    }
}
```

拆代理的正当理由是：减轻 `BrowserSession` 职责、集中管理下载目录、把完成事件交给 `DownloadManager`、**并强引用代理对象**（`WKDownload.delegate` 是 weak，代理必须由 `BrowserSession` 持有，否则回调丢失）。**不是因为线程问题。**

**PR-2 验收**：CI 编译通过；如果根本没改，此项直接关闭。

---

## 4. PR-3：ContentBlocker

现状：`Services/ContentBlocker.swift` 硬编码 4 条规则；`Resources/ContentBlockerRules.json` 存在但**从未被引用**；4 条规则全是 `url-filter` + `block`，一条 `css-display-none` 都没有，遮罩和弹窗一个都拦不住。

**要求**：

1. **文件名统一为 `DeepSeekAIBrowser/Resources/ContentBlockerRules.json`**（保持现有文件名，不要改成 `rules.json`）
2. 代码真正读这个文件，删掉硬编码字符串
3. **缓存 identifier 用规则内容的 sha256**，不要用固定的 `"default-ad-rules"`：

```swift
let hash = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
let identifier = "ad-rules-\(hash.prefix(16))"
if let cached = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: identifier) {
    list = cached
} else {
    list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
}
```

固定 identifier 的症状：改了 JSON、重新编译、规则不生效，而且**没有任何报错**。

4. 规则集必须包含 `css-display-none`：

```json
[
  {"trigger":{"url-filter":".*","if-domain":["*doubleclick.net","*googlesyndication.com","*googleadservices.com","*popads.net","*propellerads.com"]},"action":{"type":"block"}},
  {"trigger":{"url-filter":".*[\\\\/](ad|ads|adv|popunder)[-_\\\\/.].*","resource-type":["script","image","raw"]},"action":{"type":"block"}},
  {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"[class*='ad-overlay'],[id*='ad-mask'],[class*='admask'],div[class*='ad-mask']"}},
  {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".ad-close,.ad_close,.pop-close,[class*='AdClose'],[id*='AdClose']"}}
]
```

5. **不要出现 `ignore-previous-rules` 配 `if-domain: ["*"]`**——那会让拦截器反过来放行，且不报错
6. 编译失败要打日志，不要静默 `catch {}`

**已知边界**：`css-display-none` 只处理**页面加载时就能静态匹配到**的遮罩。JS 动态插入的弹窗必须靠 PR-4 或用户手动触发。这个边界不用改，但要知道。

**PR-3 验收**：改一次 JSON → 重新构建 → 规则变化生效；打开已知有遮罩的站点，遮罩消失。

---

## 5. PR-4：cleanPageLocally 重写

现状（`BrowserSession.swift` 58-80 行）：对 `document.querySelectorAll('body *')` **每个节点**调用 `getComputedStyle` + `getBoundingClientRect`。视频站几千节点 → 强制同步重排数千次 → 主线程卡死。判定条件还会误杀播放器控制层和登录框。

**v2 版脚本**（解决四个问题：全量遍历、button 无上限、漏嵌套、sticky 误杀，并且**返回可测的结构**）：

```javascript
(() => {
  const t0 = performance.now();
  const MAX_CONTAINERS = 400;
  const MAX_BUTTONS = 80;
  const viewport = innerWidth * innerHeight;
  let hidden = 0, clicked = 0, skippedVideo = 0;

  // ① 用 CSS 属性/类选择器粗筛：由选择器引擎完成，不触发重排
  const sel = [
    '[style*="position:fixed"]',
    '[style*="position: fixed"]',
    '[class*="modal"],[class*="mask"],[class*="overlay"],[class*="popup"],[class*="ad-"]'
  ].join(',');

  const cands = [];
  const raw = document.querySelectorAll(sel);
  for (let i = 0; i < raw.length && cands.length < MAX_CONTAINERS; i++) cands.push(raw[i]);

  for (const el of cands) {
    const st = getComputedStyle(el);
    if (st.position !== 'fixed') continue;                        // 去掉 sticky，那是正常布局
    if (st.display === 'none' || st.visibility === 'hidden') continue;
    if (el.querySelector('video,audio')) { skippedVideo++; continue; }   // 保护播放器
    const r = el.getBoundingClientRect();
    if (r.width * r.height < viewport * 0.2) continue;            // 只处理大面积遮挡
    el.style.setProperty('display', 'none', 'important');
    hidden++;
  }

  // ② 关闭按钮只在前一步的浮层内部找，且总量封顶
  let seen = 0;
  for (const box of cands) {
    if (seen >= MAX_BUTTONS) break;
    const btns = box.querySelectorAll('button,[role="button"],[class*="close"],[class*="Close"]');
    for (const b of btns) {
      if (seen++ >= MAX_BUTTONS) break;
      const label = (b.innerText || b.getAttribute('aria-label') || '').trim();
      if (!/^(关闭|跳过|close|skip|dismiss|知道了|×|✕)$/i.test(label)) continue;
      try { b.click(); clicked++; } catch (_) {}
    }
  }

  return JSON.stringify({
    changed: hidden + clicked,
    hidden, clicked,
    skippedVideoContainers: skippedVideo,
    candidates: cands.length,
    elapsedMs: Math.round(performance.now() - t0)
  });
})()
```

**返回结构的用途**：`evaluate()` 拿回 JSON 字符串，把 `elapsedMs` 和 `hidden` 显示在 UI 上。这样验收时能真实测量，而不是凭感觉说"不卡"。

**边界说明**：粗筛依赖 `style` 内联属性或常见 class 命名，命名怪异的站点会漏。这是**有意为之的取舍**——宁可漏，不要卡死。漏掉的交给 PR-6 的 AI 兜底（用户明确触发，不是自动）。

**PR-4 验收**：在真实视频站上点「清理页面」，返回 `elapsedMs < 300`、播放器仍可操作、无卡顿。

---

## 6. PR-5：API Key 与配置迁出 Keychain

**存储**改成带版本号的受保护文件 `Application Support/config/secret.json`：

```json
{ "schemaVersion": 1, "apiKey": "sk-..." }
```

写入时设置文件保护等级：

```swift
try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
```

**迁移规则**：
- 旧版 `KeychainStore` 读取逻辑**只保留一次**：启动时若新文件不存在且 Keychain 有值 → 写入新文件 → 之后不再读 Keychain
- 迁移完成后 Keychain 条目可以留着，但不再作为正式存储
- `KeychainStore.swift` 可以删，也可以只留迁移用的只读函数

**两条硬规则**：
1. **API Key 绝不能出现在「本次实际发送的提示词」预览里**（那会把它显示在屏幕上）
2. API Key 绝不能进日志

**PR-5 验收**：填 Key → 杀 App → 重开 → Key 还在；预览面板里看不到 Key；`os_log` / `NSLog` 里 grep 不到 `sk-`。

---

## 7. PR-6：MediaSniffer（弱引用代理是重点）

现状：`snapshot()` 只扫 `<video>/<source>` 元素，抓不到 XHR 里的 m3u8，也抓不到 `blob:`。真实视频站 90% 走 XHR。

**注入脚本**（`WKUserScript`，`.atDocumentStart`，`forMainFrameOnly: false`）：

```javascript
(function () {
  if (window.__aibSniff) return;
  window.__aibSniff = true;
  const HIT = /\.(m3u8|mp4|m4v|webm|ts)(\?|$)/i;
  const sent = new Set();

  function report(url, ct) {
    if (!url) return;
    const s = String(url);
    if (!HIT.test(s) && !/\/hls\/|\/playlist/i.test(s)) return;
    if (sent.has(s)) return;
    sent.add(s);
    try {
      window.webkit.messageHandlers.media.postMessage({
        url: s, pageURL: location.href, cookie: document.cookie || '', contentType: ct || ''
      });
    } catch (e) {}
  }

  // fetch
  const of = window.fetch;
  window.fetch = function (input) {
    try {
      report(input && input.url ? input.url : input);
      const p = of.apply(this, arguments);
      p.then(r => report(r.url, (r.headers && r.headers.get('content-type')) || '')).catch(() => {});
      return p;
    } catch (e) { return of.apply(this, arguments); }
  };

  // XHR
  const oo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) {
    try {
      report(u);
      this.addEventListener('load', () => {
        try { report(this.responseURL, this.getResponseHeader('content-type')); } catch (e) {}
      });
    } catch (e) {}
    return oo.apply(this, arguments);
  };

  // <video>.src
  const d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
  if (d && d.set) Object.defineProperty(HTMLMediaElement.prototype, 'src', {
    set(v) { try { report(v); } catch (e) {} return d.set.call(this, v); },
    get() { return d.get.call(this); },
    configurable: true
  });

  // createObjectURL
  const oc = URL.createObjectURL;
  URL.createObjectURL = function (o) {
    const u = oc.call(this, o);
    try { report(u); } catch (e) {}
    return u;
  };
})();
```

**原生侧必须做的两件事**：

1. **weak proxy**，否则 `WKUserContentController` 强引用 handler → `BrowserSession` 永不释放 → 内存泄漏 + 崩溃：

```swift
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}
```

2. **去重 + 上限 50 条**，并在 UI 上按站点分组显示

**PR-6 验收**：在一个真实视频站播放后，「识别视频」列表里出现 m3u8 或 mp4 的 URL，包含 pageURL 和 cookie。

---

## 8. PR-7 + PR-8：HLS 下载器与后台续传（接口必须一起设计）

**这两个 PR 分开提交，但接口必须先定。** v1 把它们当两个独立模块是错的。

### 8.1 明确的支持矩阵（收紧）

**支持**：
- HLS VOD，且有 `#EXT-X-ENDLIST`
- MPEG-TS 分片（`.ts`）
- `METHOD=NONE`
- `METHOD=AES-128`（IV 显式给出，或按 RFC 8216 用 Media Sequence Number 推导）
- 普通 HTTP/HTTPS
- 带页面提供的 Referer / Cookie / 桌面 UA
- **fMP4（有 `EXT-X-MAP`）**：拿 init segment + 所有 `moof/mdat` 顺序拼接即可

**明确不支持，并且必须报错退出，不要产出坏文件**：
- `SAMPLE-AES`、任何 DRM / FairPlay
- 直播流（无 `EXT-X-ENDLIST`）
- `EXT-X-BYTERANGE`（第一版）
- 多音轨合并（`EXT-X-MEDIA` 独立音轨）
- `EXT-X-DISCONTINUITY`（第一版遇到就提示可能音画不同步）
- `blob:` / MSE 内部拼装完成、没有可见媒体 URL 的视频

### 8.2 关于 fMP4 的更正

v1 和上一轮审查都说"fMP4 不能简单拼接"，**这不准确**：
拿到 `EXT-X-MAP` 的 init segment 后，`init + fragment₁ + fragment₂ + …` 按字节顺序拼接，本身就是一个合法的 fMP4 文件，`AVPlayer` 能直接播，**不需要重封装**。

反而是 **MPEG-TS 需要 remux**（`AVAssetExportSession` + `AVAssetExportPresetPassthrough`）才有顺滑 seek 和正确时长。

所以实现顺序建议：**先做 fMP4（更简单），再做 MPEG-TS**。判定分支：playlist 里有 `EXT-X-MAP` 且分片是 `.m4s`/`.mp4` → fMP4 路径；否则 → TS 路径。

### 8.3 后台下载不能用 Swift 并发循环

**禁止**这样写：

```swift
Task { for seg in segments { await download(seg) } }   // 进后台就被挂起
```

**必须**用 background `URLSession` + delegate 驱动，每个分片是一个独立 task，靠 `taskDescription` 映射回业务：

```swift
@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.yg.aibrowser.bg")
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()
    // taskDescription = "\(downloadID.uuidString)|\(segmentIndex)"
}
```

**模块拆分**：

```
DownloadManager
 ├─ BackgroundSessionCoordinator   后台 session 生命周期 + 事件重建
 ├─ HLSDownloadJob                 单个下载任务的编排（滑动窗口，同时 6 个分片）
 ├─ SegmentStateStore              分片状态持久化
 ├─ HLSPlaylistParser              master/media 解析 + 支持矩阵判定
 ├─ AES128Decryptor                CCCrypt AES-128-CBC
 └─ MediaAssembler                 TS remux / fMP4 拼接
```

**下载索引**（`Application Support/Downloads/downloads.json`）：

```json
{
  "schemaVersion": 1,
  "items": [
    {
      "downloadID": "…",
      "title": "…",
      "kind": "hls-ts | hls-fmp4 | direct",
      "playlistURL": "…",
      "referer": "…",
      "ua": "…",
      "totalSegments": 312,
      "segments": [{ "index": 12, "state": "finished", "path": "…", "retryCount": 1 }],
      "outputPath": "…",
      "state": "running | paused | finished | failed",
      "errorMessage": null
    }
  ]
}
```

**断点续传的实现顺序**：启动 → 读 `downloads.json` → 对 `state == running` 的任务，把 `state != finished` 的分片重新入队 → 只下缺的。

### 8.4 「杀 App」的准确含义（重要）

Apple 的行为分两种，**承诺要分开写**：

| 情况 | 后台传输 |
|---|---|
| 系统因内存/时间终止 App | 传输继续，重新拉起后通过 `handleEventsForBackgroundURLSession` 交付事件 |
| **用户从多任务界面强制划掉 App** | **传输被取消**，系统不会自动拉起 |

所以：

- 系统终止 → 重开 App 后能接着下，**这是承诺的**
- 用户强杀 → 不承诺后台继续，但重开后必须读 `downloads.json`，把未完成分片重新入队继续

实现上必须处理 `application(_:handleEventsForBackgroundURLSession:completionHandler:)`，并在里面保存 completionHandler、等所有事件处理完再调用。

**PR-7 验收**：给定一个受支持的 fMP4 VOD 或 AES-128 MPEG-TS VOD 测试流，能下完并生成可播放文件；遇到 BYTERANGE、DISCONTINUITY、多音轨、直播、DRM/SAMPLE-AES 时给出明确的不支持提示，不产出坏文件。

**PR-8 验收**：下载中让系统终止 App（不是手动划掉），重开后从已完成分片继续；手动强杀后重开，也能读取状态继续未完成分片。

---

## 9. PR-9：播放器

1. `AVPlayer` + 自绘控制条（播放/暂停、进度、±10s、倍速、全屏）
2. **不要用 `AVPlayerViewController`**
3. `AVAudioSession.setCategory(.playback)`，否则静音开关下没声音
4. 从 `Documents/Downloads/` 读本地文件
5. 按文件路径记住播放进度，下次续播

---

## 10. PR-10：DeepSeek 多轮 tool calling

### 10.1 消息格式（必须严格按 API）

```
user            →  assistant(tool_calls)  →  tool(tool_call_id)  →  assistant…
```

**硬规则**：
- **必须**把模型真实返回的 `assistant` 消息（含 `tool_calls` 数组和每个 `tool_call.id`）原样追加进上下文
- **绝不能**由客户端伪造一条 `assistant` tool call 插进去
- `tool` 消息必须带对应的 `tool_call_id`
- 若启用 thinking / reasoning 模型，必须把返回的 `reasoning_content` 原样回传后续请求，否则报错或效果劣化

### 10.2 模型名不要写死


当前代码写死 `deepseek-chat`。**不要把过时模型名当作 fallback**，改成：

1. 首次请求前 `GET https://api.deepseek.com/models`（带 Authorization）
2. 成功 → 用返回列表填充设置里的模型选择器，并保留用户当前选择（若仍可用）
3. 失败 → 保留已保存的模型；首次安装则使用代码中明确配置的当前默认模型，并在 UI 上说明"未能获取模型列表"
4. 请求返回 4xx 且错误信息提到 model → 提示用户换模型，不要静默失败
5. 不自动回落到 `deepseek-chat`；模型 ID 应允许用户手动编辑

### 10.3 额度控制（比 v1 更严）

```
maxSteps 默认 6（不是 10）
只有页面实际发生变化后才重新 snapshot（比较 location.href + document.body.innerText 长度 + 前 200 字符的 hash）
snapshot 正文截断到 6000 字符，可交互节点最多 60 个
相同页面摘要不重复发送
本地清理广告不调用 AI（走 PR-3 / PR-4）
start_download 必须由用户明确触发，AI 只能"建议"
单步超时 15s，整体可中断
```

**PR-10 验收**：说"关掉广告然后找到那个视频"，它自己走完；控制台能看到每步的 tool_call 和 tool 结果；额度消耗可见。

---

## 11. PR-11：ProfileStore

现状：只有一份配置、无 `schemaVersion`、导出只是把 JSON 显示在屏幕上、**没有导入**。

**要求**：

1. `ProfileStore: ObservableObject` → `[BehaviorProfile]` + `activeProfileID` + `[domain: profileID]`
2. 落盘 `Application Support/config/profiles.json`，带 `schemaVersion`
3. **迁移**：旧版是 `UserDefaults["behavior-profile"]`（单个对象）→ 首次启动读它，转成 `[BehaviorProfile]` 数组并写入新文件，然后不再读 UserDefaults
4. 导出：`.fileExporter` → 存 `.json` 到「文件」App
5. 导入：`.fileImporter` → 校验 `schemaVersion` → 按 ID 合并（ID 相同则覆盖，不同则追加）
6. 域名规则：当前 domain → 用哪套预设（提示词 + 是否自动清理 + 工具权限）
7. 「本次实际发送的提示词」预览：拼出 system prompt + 工具 schema + 页面摘要，**但把 API Key 排除**

**PR-11 验收**：导出到「文件」→ 卸载重装 → 导入 → 预设全部回来；旧版单份配置能自动迁移成一份预设。

---

## 12. 验收标准（重写，每条都能测）

| # | 场景 | 通过条件 |
|---|---|---|
| 1 | CI | Actions 绿，artifact 里有 `App-unsigned.ipa`，`Verify Info.plist` 全部 `ok` |
| 2 | 装机 | SideStore 装上，图标出现，打开不闪退 |
| 3 | 浏览 | 打开一个 **http**（非 https）站点能正常显示 |
| 4 | 广告 | 有遮罩弹窗的视频站，遮罩消失，播放器仍可操作 |
| 5 | 性能 | 同页点「清理页面」，返回 `elapsedMs < 300`，页面不冻结 |
| 6 | 嗅探 | 播放一个可嗅探的普通 HLS/MP4 视频后，「识别视频」出现 m3u8/mp4，带 pageURL + cookie |
| 7 | HLS 下载 | 给定 AES-128 MPEG-TS VOD 测试流，下完得到可播放 MP4（不是 3KB 文本） |
| 8 | 不支持类型 | BYTERANGE、DISCONTINUITY、多音轨、直播、DRM/SAMPLE-AES 给出明确提示，不产出坏文件 |
| 9 | 续传（系统终止） | 下载中让系统终止 App，重开后从已完成分片继续 |
| 10 | 续传（用户强杀） | 手动划掉 App 后重开，读状态并继续未完成分片 |
| 11 | 播放 | 下好的视频 App 内可播，有进度条和倍速，静音开关下有声 |
| 12 | AI 多轮 | 说"关广告并找视频"能自动走完，不需要分三次点按钮 |
| 13 | 额度 | 同一操作不重复发送相同页面摘要；`maxSteps` 到 6 停止 |
| 14 | 配置 | 导出到「文件」→ 卸载重装 → 导入 → 预设恢复 |
| 15 | 迁移 | 新版能读旧版 `UserDefaults["behavior-profile"]`；旧版没有 `downloads.json` 时创建空索引；新版产生的文件都带 `schemaVersion` |

---

## 13. 黑名单

- 不要加 Extension / App Groups / Network Extension / Push
- 不要提交 `.xcodeproj` 和 `Support/Info.plist`
- 不要把用户数据或 API Key 放 Keychain（仅允许一次性迁移读取）
- 不要用 `AVPlayerViewController`
- 不要遍历 `body *` 做广告判断
- 不要让 AI 监听每次 DOM 变化
- 不要用 `URLSession.shared` 做下载
- 不要用 `Task { for … }` 做后台分片下载
- 不要用固定 identifier 缓存 content rule list
- 不要在请求预览里显示 API Key
- 不要为 DRM / 网盘限速写任何代码
- 不要改 Bundle ID

---

## 14. 提交顺序（最终）

```
PR-0   CI archive + unsigned IPA 打包          ← 已交付文件，先跑通
PR-1   project.yml + Bundle ID + Info.plist
PR-2   并发隔离（先不动，CI 验证后决定）
PR-3   ContentBlocker 读 JSON + 哈希缓存 + css-display-none
PR-4   cleanPageLocally 重写（返回 elapsedMs）
PR-5   API Key 迁到受保护 JSON 文件
PR-6   MediaSniffer + weak handler proxy
PR-7   HLS 下载器（先 fMP4，后 MPEG-TS）
PR-8   后台 URLSession + 分片状态恢复
PR-9   PlayerView
PR-10  DeepSeek 多轮 tool calling + /models 探测
PR-11  ProfileStore + 迁移 + 导入导出
```

**PR-0 到 PR-5 全部通过之前，不要开始 PR-6 之后的工作。** 前六项是地基：没有可安装的包，后面写多少都是纸上作业。
