<p align="right"><strong>中文</strong> · <a href="README.en.md">English</a></p>

# Primuse (猿音)

原生 iOS / macOS / Apple TV 音乐播放器，支持从 NAS、媒体服务器、云盘及本地网络源串流播放，具备元数据刮削、歌词显示、跨设备同步和外部播放控制能力。

> 🎉 **现已上架 App Store** — 在中国区 App Store 搜索「猿音」即可免费下载体验。

<p align="center">
  <a href="https://apps.apple.com/cn/app/%E7%8C%BF%E9%9F%B3/id6761675450">
    <img src="https://img.shields.io/badge/App_Store-立即下载-007AFF?logo=apple&logoColor=white&style=for-the-badge" alt="Download on App Store"/>
  </a>
</p>

## 文档索引

- [中文说明](README.md) · [English README](README.en.md)
- [中文更新日志](CHANGELOG.md) · [English Changelog](CHANGELOG.en.md)
- [应用截图](#应用截图) · [macOS 桌面版](#macos-桌面版) · [Apple TV 版](#apple-tv-版)
- [功能特性](#功能特性) · [快速开始](#快速开始) · [自定义刮削源](#自定义刮削源)
- [项目结构](#项目结构) · [依赖包](#依赖包) · [架构](#架构)

## 应用截图

<p align="center">
  <img src="Docs/screenshots/ios/zh-Hans/01-home.jpg" width="160" alt="Primuse 首页"/>
  <img src="Docs/screenshots/ios/zh-Hans/02-appearance.jpg" width="160" alt="亮色与暗色外观"/>
  <img src="Docs/screenshots/ios/zh-Hans/03-songs.jpg" width="160" alt="歌曲资料库"/>
  <img src="Docs/screenshots/ios/zh-Hans/04-albums.jpg" width="160" alt="专辑浏览"/>
  <img src="Docs/screenshots/ios/zh-Hans/05-playlists.jpg" width="160" alt="歌单"/>
</p>
<p align="center">
  <img src="Docs/screenshots/ios/zh-Hans/06-search.jpg" width="160" alt="搜索结果"/>
  <img src="Docs/screenshots/ios/zh-Hans/07-now-playing.jpg" width="160" alt="正在播放"/>
  <img src="Docs/screenshots/ios/zh-Hans/08-lyrics.jpg" width="160" alt="同步歌词"/>
  <img src="Docs/screenshots/ios/zh-Hans/09-sources.jpg" width="160" alt="音乐源管理"/>
  <img src="Docs/screenshots/ios/zh-Hans/10-equalizer.jpg" width="160" alt="十段均衡器"/>
</p>

## macOS 桌面版

为 Mac 重新设计的原生桌面客户端，与 iOS 共享同一套音乐库、数据源与 iCloud 同步。

<table>
  <tr>
    <td align="center"><img src="Docs/screenshots/macos/zh-Hans/01-home.jpg" width="420" alt="macOS 首页"/><br/>桌面音乐中枢</td>
    <td align="center"><img src="Docs/screenshots/macos/zh-Hans/02-sources.jpg" width="420" alt="macOS 音乐源"/><br/>音乐源管理</td>
  </tr>
  <tr>
    <td align="center"><img src="Docs/screenshots/macos/zh-Hans/03-songs.jpg" width="420" alt="macOS 歌曲资料库"/><br/>完整歌曲资料库</td>
    <td align="center"><img src="Docs/screenshots/macos/zh-Hans/04-now-playing.jpg" width="420" alt="macOS 正在播放"/><br/>正在播放与同步歌词</td>
  </tr>
  <tr>
    <td align="center"><img src="Docs/screenshots/macos/zh-Hans/05-mini-player.jpg" width="420" alt="macOS 迷你播放器"/><br/>迷你播放器</td>
    <td align="center"><img src="Docs/screenshots/macos/zh-Hans/06-desktop-lyrics.jpg" width="420" alt="macOS 桌面歌词"/><br/>独立桌面歌词</td>
  </tr>
  <tr>
    <td align="center" colspan="2"><img src="Docs/screenshots/macos/zh-Hans/07-menu-bar.jpg" width="860" alt="macOS 菜单栏播放器"/><br/>菜单栏播放器与快捷控制</td>
  </tr>
</table>

### macOS 专属能力

- **原生桌面界面** — 自定义标题栏、可折叠侧边栏、底部播放控制条，专为大屏与鼠标/触控板设计
- **迷你播放器** — 可收起为浮窗小窗（NSPanel），内含歌词页与播放队列页
- **菜单栏播放器** — 状态栏弹出窗，随手控制播放
- **桌面歌词** — 独立悬浮歌词窗口，支持双行 / 单行 / 竖排与锁定点击穿透
- **外观自定义** — 主题、品牌色、应用图标切换，随专辑封面动态取色，浅色 / 深色模式
- **桌面小组件** — 正在播放、快速访问等 WidgetKit 小组件，设置内可预览全部尺寸
- **DLNA 投屏** — 发现局域网内的音响 / 电视并推送播放（CAST 面板）
- **系统媒体键 / 快捷键** — 支持 Mac 键盘媒体键与自定义播放快捷键
- **音频输出选择** — 在多个输出设备间切换
- **完整资料库工具** — 智能歌单编辑、重复歌曲清理、标签编辑、歌单导入、独立元数据刮削窗口
- **多屏播放** — 外接屏 Now Playing 大封面与大字歌词

其余多源串流、音质处理、元数据刮削、跨设备同步等能力与 iOS 一致，详见下方功能特性。

## Apple TV 版

在客厅大屏上播放整座曲库，与 iPhone / Mac 共享同一套音乐库、数据源与 iCloud 同步。

<table>
  <tr>
    <td align="center"><img src="Docs/screenshots/tv/zh-Hans/01-home.jpg" width="420" alt="Apple TV 首页"/><br/>大屏首页</td>
    <td align="center"><img src="Docs/screenshots/tv/zh-Hans/02-library.jpg" width="420" alt="Apple TV 资料库"/><br/>完整资料库</td>
  </tr>
  <tr>
    <td align="center"><img src="Docs/screenshots/tv/zh-Hans/03-playlists.jpg" width="420" alt="Apple TV 歌单"/><br/>歌单</td>
    <td align="center"><img src="Docs/screenshots/tv/zh-Hans/04-search.jpg" width="420" alt="Apple TV 搜索"/><br/>大屏搜索</td>
  </tr>
  <tr>
    <td align="center" colspan="2"><img src="Docs/screenshots/tv/zh-Hans/05-now-playing.jpg" width="860" alt="Apple TV 正在播放"/><br/>正在播放与同步歌词</td>
  </tr>
</table>

### Apple TV 专属能力

- **大屏整库浏览** — 专辑 / 艺术家 / 歌单 / 歌曲一览，Siri Remote 流畅操控，支持一键全部播放 / 随机播放整库
- **逐字歌词** — 满屏滚动的卡拉OK式歌词，支持原文 + 翻译，当前演唱行高亮
- **顶部展示（Top Shelf）** — 主屏聚焦应用时展示最近播放与推荐
- **多源直连** — NAS、自建服务器（Navidrome / Subsonic 等）、云盘可在 TV 上直接播放；部分源经 iPhone 中继
- **多设备同步** — 曲库、歌单、数据源与 iPhone / Mac 经 iCloud 实时同步
- **多语言界面** — 支持简体中文、繁体中文、英语、德语、法语、日语和韩语，跟随系统语言自动切换

其余多源串流、音质处理、跨设备同步等能力与 iOS 一致。

## 功能特性

- **多源串流** — 支持 Synology DSM、QNAP、绿联 UGOS、飞牛 fnOS、SMB/CIFS、WebDAV、SFTP、FTP、NFS、S3、UPnP/DLNA、Navidrome/Subsonic、Jellyfin、Emby、Plex、本地文件
- **云盘接入** — 支持 123 云盘、115、百度网盘、阿里云盘、Google Drive、OneDrive、Dropbox，云端歌曲可边下边播并按需缓存
- **播放引擎** — 基于 SFBAudioEngine，支持 FLAC、APE、WAV、MP3、AAC、Opus、DSD、TTA、WV 等格式，提供交叉淡入淡出、ReplayGain、睡眠定时、EQ、混响和压缩/限幅
- **DLNA 接收** — 可在同一 Wi-Fi 下作为 UPnP/AV MediaRenderer 被 VLC、群晖 Audio Station、Plex、Hi-Fi Cast 等控制点发现并投送音频
- **Apple Music 搜索** — 授权后可在搜索页同时查询 Apple Music 曲库，并通过系统播放器播放订阅内容
- **元数据刮削** — 内置 iTunes、MusicBrainz 和 LRCLIB 数据源，支持通过 JSON 配置导入自定义刮削源
- **可配置刮削源** — 用户可通过粘贴 JSON 配置或 URL 导入第三方元数据、封面、歌词数据源
- **Sidecar 回写** — 刮削的封面 (`-cover.jpg`) 和歌词 (`.lrc`) 自动写回 NAS
- **歌词体验** — 支持 LRC / 字级歌词、桌面歌词式外接屏显示、歌词翻译缓存和手动刮削校正
- **资料库管理** — 支持专辑/艺术家归类、普通歌单、智能歌单、M3U8/JSON 歌单导入导出、重复歌曲检测、最近删除
- **同步与统计** — 支持 iCloud CloudKit 同步源、歌单、播放历史和设置，提供听歌统计、年度报告、Last.fm / ListenBrainz scrobble
- **系统集成** — 支持实时活动、灵动岛、锁屏控制、主屏幕小组件、Control Widget、Apple Watch、CarPlay、Siri / Shortcuts、Spotlight 搜索、AirPlay、外接屏

## 环境要求

- **Xcode 16.0+**
- **Swift 6.0+**
- **iOS 18.0+** 部署目标，**watchOS 10.0+** Watch 目标
- macOS 构建环境（推荐 Apple Silicon）

## 快速开始

### 1. 克隆仓库

```bash
git clone git@github.com:chenqi92/primuse.git
cd primuse
```

### 2. 打开项目

```bash
open Primuse.xcodeproj
```

首次打开时 Xcode 会自动解析 Swift Package Manager 依赖，可能需要几分钟。

### 3. 配置签名

1. 在 Xcode 中打开 `Primuse.xcodeproj`
2. 在项目导航器中选择 **Primuse** 项目
3. 对每个 Target（**Primuse**、**PrimuseKit**、**PrimuseWidgetExtension**、**PrimuseActivityExtension**）：
   - 进入 **Signing & Capabilities**
   - 将 **Team** 修改为你的 Apple 开发者账号
   - Xcode 会自动生成描述文件
4. 若需要真机使用 DLNA 接收功能，请在 Apple Developer 后台为 App ID 开启 **Multicast Networking** 能力，并确保 provisioning profile 包含 `com.apple.developer.networking.multicast`

也可以修改 `project.yml` 中的 `DEVELOPMENT_TEAM` 后重新生成项目。

### 4. 配置本地密钥（可选）

复制 `Config/Secrets.local.xcconfig.example` 为 `Config/Secrets.local.xcconfig`，按需填入云盘 OAuth 或 Last.fm 默认 API key。该文件已被 git 忽略；留空时 Last.fm 会要求用户在设置里粘贴自己的 key。

### 5. 构建运行

选择目标设备/模拟器后按 `Cmd+R`，或使用命令行：

```bash
# 模拟器构建
xcodebuild -scheme Primuse \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build

# 真机构建（需要签名）
xcodebuild -scheme Primuse \
  -destination 'id=你的设备UDID' \
  build
```

### 6. 命令行安装到设备

```bash
# 安装
xcrun devicectl device install app \
  --device 你的设备UDID \
  ~/Library/Developer/Xcode/DerivedData/Primuse-*/Build/Products/Debug-iphoneos/Primuse.app

# 启动
xcrun devicectl device process launch \
  --device 你的设备UDID \
  com.welape.primuse
```

## 自定义刮削源

Primuse 支持通过 JSON 配置导入自定义元数据刮削源。每个配置文件描述了 API 端点、请求格式和 JavaScript 解析脚本。

### 配置格式

```json
{
  "id": "my-source",
  "name": "My Music Source",
  "version": 1,
  "icon": "music.note",
  "color": "#FF6600",
  "rateLimit": 500,
  "headers": {
    "User-Agent": "Mozilla/5.0"
  },
  "capabilities": ["metadata", "cover", "lyrics"],
  "sslTrustDomains": ["example.com"],
  "search": {
    "url": "https://api.example.com/search",
    "method": "GET",
    "params": { "q": "{{query}}", "limit": "{{limit}}" },
    "script": "var items = response.results || []; return items.map(function(s) { return {id: String(s.id), title: s.name, artist: s.artist, album: s.album, durationMs: s.duration, coverUrl: s.cover}; });"
  },
  "detail": { "url": "...", "method": "GET", "script": "..." },
  "cover": { "url": "...", "method": "GET", "script": "..." },
  "lyrics": { "url": "...", "method": "GET", "script": "..." }
}
```

### 导入方式

1. 打开 **设置 → 元数据刮削 → 导入刮削源**
2. 选择 **粘贴配置** 或 **从 URL 导入**
3. 导入后的源会出现在刮削源列表中，可拖动排序、启用/禁用

### JS 脚本规范

- `response`：已解析的 JSON 响应对象
- `responseText`：原始响应文本
- `externalId`：当前歌曲的外部 ID（detail/cover/lyrics 端点可用）
- `log(msg)`：调试日志输出

**search 脚本** 返回 `[{id, title, artist, album, durationMs, coverUrl}]`

**detail 脚本** 返回 `{title, artist, album, year, coverUrl, trackNumber, genres}`

**lyrics 脚本** 返回 `{lrcContent}` 或 `{plainText}`

**cover 脚本** 返回 `[{coverUrl, thumbnailUrl}]`

## 项目结构

```
primuse/
├── Primuse/                        # 主应用 Target
│   ├── App/                        # 应用入口、ContentView
│   ├── Services/
│   │   ├── Audio/                  # 播放引擎、解码器、均衡器
│   │   ├── Cloud/                  # iCloud / CloudKit 同步
│   │   ├── DLNA/                   # UPnP/AV Renderer 接收投送
│   │   ├── Library/                # 音乐库、数据库
│   │   ├── Metadata/               # 刮削器、资源存储、Sidecar 写入
│   │   │   └── Scrapers/           # 可配置刮削器、MusicBrainz、LRCLIB
│   │   ├── Playlist/               # 歌单导入导出
│   │   ├── Scrobble/               # Last.fm / ListenBrainz
│   │   ├── Sources/                # NAS、协议、媒体服务器、云盘连接器
│   │   └── Stats/                  # 听歌统计与年度报告
│   ├── Views/
│   │   ├── Home/                   # 首页（仪表盘）
│   │   ├── Library/                # 专辑、艺术家、歌曲、播放列表视图
│   │   ├── NowPlaying/             # 播放器、队列、刮削选项
│   │   ├── Search/                 # 搜索视图
│   │   ├── Settings/               # 设置、均衡器、刮削器配置
│   │   ├── Sources/                # 源管理、连接流程
│   │   └── Components/             # 可复用 UI 组件
│   ├── Resources/                  # 本地化（en、zh-Hans、zh-Hant、de、fr、ja、ko）、资源文件
│   └── Utilities/                  # 日志工具、扩展
├── PrimuseKit/                     # 共享框架（模型、协议）
│   └── Sources/PrimuseKit/Models/  # Song、Album、Artist、Playlist 等
├── PrimuseWidgetExtension/         # 主屏幕小组件
├── PrimuseActivityExtension/       # 灵动岛 / 实时活动
├── PrimuseWatch/                   # Apple Watch App
├── PrimuseWatchWidgets/            # Watch Complications
├── Config/                         # Entitlements、Info.plist 配置
└── project.yml                     # XcodeGen 项目定义
```

## 依赖包

| 包名 | 用途 |
|------|------|
| [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) | 音频解码（FLAC、APE、WV、TTA、DSD、MP3、AAC 等） |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite 数据库，音乐库持久化 |
| [AMSMB2](https://github.com/amosavian/AMSMB2) | SMB/CIFS 客户端，NAS 访问 |
| [FileProvider](https://github.com/amosavian/FileProvider) | FTP/WebDAV 文件操作 |
| [Citadel](https://github.com/orlandos-nl/Citadel) | SSH/SFTP 客户端 |
| [NFSKit](https://github.com/alexiscn/NFSKit) | NFS 客户端 |
| [swift-crypto](https://github.com/apple/swift-crypto) | 加密操作 |
| [swift-nio](https://github.com/apple/swift-nio) | 异步网络基础设施 |

系统框架还使用了 MusicKit、CloudKit、ActivityKit、WidgetKit、WatchConnectivity、CarPlay、MediaPlayer 和 Network.framework。

## 架构

### 音频管线

```
音源（本地 / NAS / 媒体服务器 / 云盘）
  → CloudPlaybackSource / StreamingDownloadDecoder / NativeAudioDecoder
  → SFBAudioEngine AudioDecoder
  → AVAudioConverter（采样率 / 格式转换）
  → AVAudioEngine（PlayerNode → Mixer → EQ → Compressor → Reverb → 输出）
```

### 元数据刮削

```
用户触发刮削
  → ScraperManager（按优先级依次尝试已启用的刮削源）
  → ConfigurableScraper（JSON 配置 + JavaScriptCore 解析）
  → 封面 + 歌词 + 元数据
  → SidecarWriteService → NAS（<歌曲名>-cover.jpg、<歌曲名>.lrc）
  → MetadataAssetStore → 本地缓存
```

### CI/CD

项目配置了 GitHub Actions 自动构建：

- **build**：每次 push/PR 自动触发模拟器构建验证（无需签名）
- **archive**：仅当 `main` 分支的版本号发生变化时，自动构建未签名 IPA 并上传为 Artifact
