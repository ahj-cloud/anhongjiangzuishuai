# 安洪江最帅（AnHongJiang）

bpz3.com（搜剧AI）的 iOS 原生客户端。SwiftUI 6 视图 + AVPlayer 播放器 + DLNA 投屏 + WKWebView 数据引擎。

## 目录

```
anhongjiang/
├─ project.yml                    # XcodeGen 工程描述
├─ AnHongJiang/
│  ├─ App/AnHongJiangApp.swift    # 入口、TabBar、横屏遮罩代理
│  ├─ UI/Theme.swift              # 配色/圆角/通用组件
│  ├─ Core/
│  │  ├─ Models.swift             # 数据模型 + JSON 归一化（FeedParser）
│  │  ├─ SiteEngine.swift         # 数据引擎：WKWebView 跑站点 JS，抓 /v1/* 响应
│  │  ├─ WebFallbackView.swift    # 网页兜底
│  │  └─ LibraryStore.swift       # 收藏/记录/进度，本地 JSON 原子写
│  ├─ Features/
│  │  ├─ Home/                    # 首页 + 轮播 + 海报卡片
│  │  ├─ Browse/                  # 频道、搜索
│  │  ├─ Detail/                  # 详情、选集
│  │  ├─ Player/                  # 播放器、控制层、横屏
│  │  ├─ Cast/                    # DLNA 发现与投屏
│  │  └─ Library/                 # 我的、历史、收藏、关于
│  └─ Resources/Info.plist
```

## 为什么不用直连 API

站点 `/v1/*` 全部要签名，请求头三件套：

```
x-ai-movie-timestamp: <ms>
x-ai-movie-nonce:     <32 位 hex>
x-ai-movie-signature: HMAC-SHA256(secret, "METHOD path?query ts nonce")
```

`secret` 内联在 `assets/movie-card-runtime-*.js` 里。但按该规则离线重算后服务端仍回
`invalid_request_signature`，说明线上校验因子不止这四项（换包或服务端另有密钥）。
所以 App 不碰签名，改由 `SiteEngine` 用 WKWebView 加载站点，在 `documentStart` 注入钩子
接管 `fetch` / `XMLHttpRequest`，把 `/v1/*` 的响应体原样捞回原生侧。
站点换密钥、加风控、改字段，App 都不用重新发版。

## 构建

```bash
# 一次性
brew install xcodegen

cd anhongjiang
xcodegen generate                       # 产出 AnHongJiang.xcodeproj

# 模拟器直接跑
xcodebuild -project AnHongJiang.xcodeproj \
  -scheme AnHongJiang \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -configuration Debug build

# 真机（需要自己的 Team）
xcodebuild -project AnHongJiang.xcodeproj \
  -scheme AnHongJiang \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  DEVELOPMENT_TEAM=<你的10位TeamID> \
  CODE_SIGN_STYLE=Automatic build
```

也可以直接 `open AnHongJiang.xcodeproj`，选模拟器 ⌘R。

## 没有 Mac 怎么出包

仓库自带 `.github/workflows/build-ipa.yml`，推到 GitHub 后 Actions 会自动跑
`macos-14` 上编译，产物是未签名的 `AnHongJiang-unsigned.ipa`：

```
Actions → build-ipa → Artifacts → AnHongJiang-unsigned-ipa
```

拿到 ipa 后两条路：

- 有开发者账号：Sideloadly / AltStore 用自己证书重签后安装，7 天或 1 年有效。
- 越狱或 TrollStore 设备：直接装，无需证书。

## 首次运行验收

1. 启动后首页应出现轮播图 + 若干横向海报栏，标题为「电视剧 / 动漫 / 综艺 / 电影」。
2. 点任一海报进详情，出现简介、选集网格。
3. 点「立即播放」进播放器：可拖进度、±10 秒、倍速、全屏（横屏）。
4. 右上角投屏 → 自动搜同一 Wi-Fi 下的电视，选中后电视开始播放。
5. 杀掉 App 重进，「我的 → 观看记录」保留上次进度。

第 1 步不出内容说明数据引擎没抓到包，检查方式见下节。

## 排障

数据引擎有调试口：

```swift
// 在任意 View 的 task 里临时加
let raw = try await SiteEngine.shared.evaluate("JSON.stringify((window.__bpzLog||[]).map(x=>x.url))")
print(raw ?? "空")
```

- 输出为空：注入脚本没生效，检查 `SiteEngine.captureJS` 是否被 CSP 拦（站点有 CSP，
  但 `WKUserScript` 走的是原生注入，不受 `script-src` 限制；若被拦，把
  `forMainFrameOnly` 改 `true` 重试）。
- 有 URL 但列表为空：`FeedParser` 的字段特征没命中，把原始 JSON 抓出来对一下
  `titleKeys` / `posterKeys` / `idKeys` 三张表即可，其他代码不用动。

## 换域名 / 换站点

只改一处：`Core/Models.swift` 里的

```swift
enum SiteConfig {
    static let origin = "https://bpz3.com"
    static let homePath = "/"
}
```

`Info.plist` 已放开 ATS（`NSAllowsArbitraryLoads`）与本地网络权限，换 http 源也能播。

## 已实现 / 未实现

- 已实现：首页轮播、分类横滑、频道网格、搜索、详情选集、HLS/MP4 播放、横屏全屏、
  倍速、DLNA 投屏、收藏、观看记录与断点、深浅色、网页兜底。
- 未实现：离线下载（HLS 分片解密依赖站点密钥，需在拿到播放授权后单独做）、
  弹幕、AirPlay（系统级，`AVPlayer` 已支持，无需额外代码）、账号登录同步。
