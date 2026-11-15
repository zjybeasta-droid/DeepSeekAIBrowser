# AGENTS.md — 接手这个项目前必读

> iPad 自用的 AI 浏览器。**不是要上架的 App**，一切按"自用能力最大化"来，不为 App Store 审核妥协。
> 当前阶段：PR-0 / PR-1 已通过，CI 能产出未签名 IPA。下一步 PR-3 → PR-5。

---

## 环境事实（先读这段，否则会走错路）

| 事项 | 事实 |
|---|---|
| 开发机 | **Windows**，没有 Xcode、xcodebuild、swiftc |
| 能不能本机编译 | **不能**。本机只写代码，编译一律走 CI |
| 编译在哪 | GitHub Actions，`.github/workflows/ios-build-unsigned.yml`，`runs-on: macos-15` |
| 工程怎么生成 | XcodeGen 从 `project.yml` 生成。**不要手改、不要提交 `.xcodeproj`** |
| 产物 | **未签名 `.ipa`**，签名在 iPad 上由 SideStore / Sideloadly 用免费 Apple ID 完成 |
| CI 里能不能加签名 | **不要加**。不要 p12、不要描述文件、不要 `--allowProvisioningUpdates` |
| 仓库 | public（macOS runner 在私有仓库按 10 倍扣额度，public 无限） |

> 关键因果：CI 不签名 → 免费账号 7 天证书 → 所有长任务必须可中断恢复。这条约束渗透到每一处设计。

---

## 踩过的坑（照抄会直接红）

1. **`runs-on: macos-14` 已下线**。任务排队后 3 秒被 cancelled，`runner_name` 为空，日志只有 22 字节。
   实测 `macos-15` 和 `macos-latest` 可用。**用 `macos-15`。**
2. **`SWIFT_VERSION` 合法值只有 `4.0 / 4.2 / 5.0 / 6.0`**。写 `5.9` 报
   `SWIFT_VERSION '5.9' is unsupported`。用 `"5.0"`。
3. **必须显式声明 scheme**。XcodeGen 不保证写 `.xcscheme`，缺了 CI 报
   `does not contain a scheme named DeepSeekAIBrowser`。项目无 test target，scheme 里不要写 `test:` 段。
4. **`NSAllowsArbitraryLoads` 和 `NSAllowsArbitraryLoadsInWebContent` 不能同时存在**。
   iOS 10+ 规定后者存在时前者被忽略 → URLSession 的 http 媒体请求回到 ATS 严格模式 →
   网页能开、视频下载全挂。CI 里有一条断言会在出现后者时直接失败。
5. **`Support/Info.plist` 是生成物**，已进 `.gitignore`，不要提交。CI 里先 `mkdir -p Support` 再 `xcodegen generate`。
6. **`Generate Xcode project` 那步会跑 `xcodebuild -list`**，把实际存在的 scheme 打进日志，别删这行。

---

## 硬约束（写代码时必须遵守）

1. **所有长任务可恢复**：下载持久化 `resumeData`，冷启动自动续传。证书 7 天到期系统会杀进程。
2. **不用付费 Capability**：App Groups / Network Extension / Push / HealthKit 一律不碰（免费账号拿不到描述文件，编译直接失败）。
3. **只用公有 API**。私有 API 会让任何签名渠道失效。
4. **单 target，不加 Extension**。免费账号同时只能装 3 个自签 App，Extension 也算。
5. **Bundle ID 固定 `com.yg.aibrowser`**。改名 = 沙盒重置 = 已下载的视频和全部设置消失。
6. **媒体请求必须带 `Referer` + 桌面 UA**，否则 CDN 直接 403。
7. **不加第三方 Swift 包**，除非确实省掉大量代码。
8. **用户数据与 API Key 不存 Keychain**（换签名身份后条目失效）。
9. **所有持久化数据带 `schemaVersion`**，升级必须能读旧数据。覆盖安装是常态，旧数据一定会在新版里出现。
10. **配置必须能全量导出/导入 JSON**（换号 = 换 team = 卸载重装 = 沙盒清空）。

---

## 目录结构

```
project.yml                          # XcodeGen 工程描述（唯一真相）
.github/workflows/ios-build-unsigned.yml
DeepSeekAIBrowser/
├── DeepSeekAIBrowserApp.swift       # @main + AppModel
├── Models/BehaviorProfile.swift     # 配置模型 + BrowserAction + AgentPlan
├── Services/
│   ├── BrowserSession.swift         # WKWebView 内核 + snapshot + cleanPageLocally + execute
│   ├── BrowserAgent.swift           # 单轮 agent（待改成多轮 tool calling）
│   ├── ContentBlocker.swift         # 规则硬编码 → 待改成读 JSON
│   ├── DeepSeekClient.swift         # /chat/completions
│   ├── DownloadManager.swift        # 只有 URLSession.shared.download，无 m3u8 / 无续传
│   └── KeychainStore.swift          # 待迁出
├── Views/
│   ├── ContentView.swift            # 地址栏 + WebView + AI 输入框
│   ├── BrowserView.swift            # UIViewRepresentable
│   └── SettingsView.swift           # 设置（导出只能看，无导入）
└── Resources/ContentBlockerRules.json   # 已打进包，但代码没读它
scripts/build-simulator.sh           # 只编模拟器，不是正式构建
```

---

## 当前状态

| 模块 | 状态 |
|---|---|
| CI 未签名 IPA 流水线 | ✅ 已通过，8 step 全绿，产物已验 |
| project.yml / Bundle ID / Info.plist | ✅ 已修并断言 |
| 浏览器内核 | 代码已编译通过，未真机验证 |
| ContentBlocker | ❌ 硬编码 4 条规则，无 `css-display-none`，JSON 未被读取 |
| cleanPageLocally | ❌ 遍历 `body *`，会卡死主线程，会误杀播放器 |
| API Key | ❌ 仍在 Keychain |
| m3u8 下载 | ❌ 完全没有 |
| 后台下载 / 续传 | ❌ 用 `URLSession.shared`，无 resumeData |
| 播放器 | ❌ 没有 |
| Agent 多轮 | ❌ 单轮，最多 8 个动作就结束 |
| 配置系统 | ❌ 单份、无 schemaVersion、无导入 |

---

## 任务顺序（别跳）

```
PR-3   ContentBlocker 读 JSON + 内容哈希 identifier + css-display-none
PR-4   cleanPageLocally 重写（CSS 粗筛 + 上限 + 返回 elapsedMs）
PR-5   API Key 迁到受保护 JSON 文件 + 一次性迁移
PR-6   MediaSniffer（fetch/XHR/video src/createObjectURL）+ weak message handler
PR-7   HLS 下载器（先 fMP4，后 MPEG-TS + AES-128）
PR-8   后台 URLSession + 分片状态恢复
PR-9   PlayerView
PR-10  DeepSeek 多轮 tool calling + /models 探测
PR-11  ProfileStore + 迁移 + 导入导出
```

**PR-3 到 PR-5 之前不要写 PR-6 之后的东西。** 前面是地基，后面是功能。

---

## 三条不可协商的边界

1. **DRM 视频下不下来**（Netflix/Disney+ 类），别浪费代码
2. **网盘限速在服务端**，客户端只能做多线程/续传，对直链有效，对网盘无效
3. **7 天要续签一次**，别设计"签名永久有效"的假设

---

## 黑名单

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
- 不要改 Bundle ID
- 不要提 TestFlight（要 $99 且 90 天过期）
- 不要问"是否需要 Mac"（本地没有编译器，构建走 CI）

---

## 验证方式

本机跑不了编译器。唯一有效的验证链：

```
push → Actions 绿 → artifact 出 App-unsigned.ipa
     → 下载解包检查 Payload/*.app + Info.plist + 二进制 arch
     → Sideloadly 签名装进 iPad → 真机跑验收
```

CI 里已有 `Verify Info.plist` 断言（Bundle ID / 文件共享 / 全局 ATS / 禁止 InWebContent）。
**这个断言不要删**——它挡的是"装上看不出原因、实际下载全挂"那类错误。
