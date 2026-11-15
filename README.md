# DeepSeekAIBrowser

一个面向 iPad 的原生 AI 浏览器源码项目：

- WKWebView 浏览器
- DeepSeek API 行为配置
- AI 页面操作与多轮工具调用
- 本地内容拦截和页面清理
- 网页视频识别
- HLS 视频下载、断点恢复和离线播放（按 `REWORK.md` 的支持矩阵实现）

## 当前状态

项目正在按 [REWORK.md](REWORK.md) 的 PR-0 → PR-11 顺序返工。PR-0/PR-1 的目标是先让 CI 生成结构正确的未签名 iOS IPA；当前 Windows 工作区不执行 Xcode 编译，正式构建由 GitHub Actions 的 `macos-14` runner 完成。

当前仓库中的 Swift 源码仍包含初版实现。媒体嗅探、HLS 分片下载、后台恢复、多轮 tool calling 和配置迁移必须按返工方案逐项完成，不能把初版 Demo 当作已经交付的功能版本。

## GitHub Actions 构建

工作流文件：`.github/workflows/ios-build-unsigned.yml`。

触发 `main` 分支 push，或在 GitHub Actions 中手动运行工作流后，它会：

1. 安装 XcodeGen；
2. 根据 `project.yml` 生成 Xcode 项目和 `Support/Info.plist`；
3. 使用 `generic/platform=iOS` 生成未签名 archive；
4. 校验最终 App 中的 Bundle ID、ATS 和文件共享配置；
5. 打包 `Payload/*.app` 为 `App-unsigned.ipa`；
6. 上传名为 `unsigned-ipa` 的 artifact。

CI 不使用证书、描述文件或 `--allowProvisioningUpdates`。下载 artifact 后，再使用 SideStore 在 iPad 上完成签名和安装。

`scripts/build-simulator.sh` 只用于本地模拟器 Debug 构建，不会生成可安装的 iPad IPA。

## DeepSeek API

在 App 设置中输入自己的 API Key。模型 ID、API Key 存储方式以及多轮 tool calling 会按照 `REWORK.md` 中的 PR-5 和 PR-10 实现。API Key 属于个人自用配置，不应提交到仓库，也不应出现在请求预览中。

## 行为配置

行为配置用于编辑系统提示词、自动清理页面、工具权限、模型和任务步数。配置导入导出、域名映射、`schemaVersion` 和旧版迁移由 PR-11 完成。

## 下载范围

项目只处理网页明确提供、用户有权保存、且客户端能够正常访问的普通媒体。第一版按返工方案支持矩阵处理 HLS；不实现 DRM 绕过、会员绕过、网盘服务端限速绕过或 blob/MSE 录制。