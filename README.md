# Primuse (猿音)

原生 iOS 音乐播放器，支持从 NAS、媒体服务器、云盘及本地网络源串流播放，具备元数据刮削、歌词显示、跨设备同步和外部播放控制能力。

> 🎉 **现已上架 App Store** — 在中国区 App Store 搜索「猿音」即可免费下载体验。

<p align="center">
  <a href="https://apps.apple.com/cn/app/%E7%8C%BF%E9%9F%B3/id6761675450">
    <img src="https://img.shields.io/badge/App_Store-立即下载-007AFF?logo=apple&logoColor=white&style=for-the-badge" alt="Download on App Store"/>
  </a>
</p>

## 应用截图

<p align="center">
  <img src="https://nas.allbs.cn:8888/cloudpic/2026/04/16e6b1d0cf490560a30dccfc66a1b92f.PNG" width="200"/>
  <img src="https://nas.allbs.cn:8888/cloudpic/2026/04/c69767db240b20945e2bf8053ec1c0fc.PNG" width="200"/>
  <img src="https://nas.allbs.cn:8888/cloudpic/2026/04/b9389f9bc599fd6bc7afad498f0fe88d.PNG" width="200"/>
  <img src="https://nas.allbs.cn:8888/cloudpic/2026/04/c34dddc9e8bf32dbc5f129e84201d986.PNG" width="200"/>
</p>
<p align="center">
  <img src="https://nas.allbs.cn:8888/cloudpic/2026/04/945ac954ae775990d3ffd92b3645b7ce.PNG" width="200"/>
  <img src="https://nas.allbs.cn:8888/cloudpic/2026/04/4ad53cb9feed2da77283888e94fb254d.PNG" width="200"/>
  <img src="https://nas.allbs.cn:8888/cloudpic/2026/04/84594ca1f8ec44463645bb77644f1db2.PNG" width="200"/>
</p>

## 功能特性

- **多源串流** — 支持 Synology DSM、QNAP、绿联 UGOS、飞牛 fnOS、SMB/CIFS、WebDAV、SFTP、FTP、NFS、S3、UPnP/DLNA、Jellyfin、Emby、Plex、本地文件
- **云盘接入** — 支持百度网盘、阿里云盘、Google Drive、OneDrive、Dropbox，云端歌曲可边下边播并按需缓存
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

### 5. 命令行安装到设备

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
│   ├── Resources/                  # 本地化（en、zh-Hans）、资源文件
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
