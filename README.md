<p align="right"><strong>中文</strong> · <a href="README.en.md">English</a></p>

# Primuse（猿音）

<p align="center">
  <a href="https://testflight.apple.com/join/AjbPukaF">
    <img src="https://img.shields.io/badge/TestFlight-加入公测-0D96F6?logo=apple&logoColor=white&style=for-the-badge" alt="加入 Primuse TestFlight 公测"/>
  </a>
  <a href="https://apps.apple.com/cn/app/%E7%8C%BF%E9%9F%B3/id6761675450">
    <img src="https://img.shields.io/badge/App_Store-立即下载-007AFF?logo=apple&logoColor=white&style=for-the-badge" alt="在 App Store 下载"/>
  </a>
</p>

> **体验最新版本：** [加入 TestFlight 公测](https://testflight.apple.com/join/AjbPukaF)

Primuse 是面向 Apple 生态的原生多源音乐播放器。它把本地文件、NAS、媒体服务器、云盘和 Apple Music 汇入同一资料库与播放队列，并提供高保真解码、CUE 分轨、歌词与元数据、跨设备同步以及完整的系统播放控制。

正式版已在 App Store 上架。在中国区 App Store 搜索「猿音」，或使用上方按钮下载。

## 文档索引

- [中文说明](README.md) · [English README](README.en.md)
- [中文更新日志](CHANGELOG.md) · [English Changelog](CHANGELOG.en.md)
- [应用截图](#应用截图) · [macOS 桌面版](#macos-桌面版) · [Apple TV 版](#apple-tv-版) · [Apple Watch 与系统集成](#apple-watch-与系统集成)
- [音乐源](#音乐源) · [播放与格式](#播放与格式) · [歌词与元数据](#歌词与元数据) · [资料库与同步](#资料库与同步)
- [快速开始](#快速开始) · [自定义刮削源](#自定义刮削源) · [项目结构](#项目结构) · [架构](#架构)

## iPhone 与 iPad

- **自适应原生界面** — iPhone 使用标签式导航，iPad 提供分栏资料库和横屏双栏播放页，并支持多窗口场景
- **完整移动资料库** — 导入“文件”App 中的歌曲、连接远程来源、扫描目录，并在本地/NAS/云端之间统一搜索和管理歌单
- **随身播放器** — 在正在播放页切换封面、歌词和队列，查看格式信息、调整速度与音效、选择 AirPlay 输出并手动修正元数据
- **后台与系统控制** — 支持后台音频、锁屏/控制中心、耳机和蓝牙按键；iPhone 音量与系统输出音量保持一致

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

Mac 客户端采用原生桌面布局，并与 iPhone、iPad 和 Apple TV 共享资料库、音乐源、歌单与 iCloud 同步数据。

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

- **原生桌面界面** — 自定义标题栏、可折叠侧边栏、底部播放栏，以及面向大曲库优化的表格和搜索体验
- **迷你播放器与菜单栏播放器** — 在悬浮小窗、菜单栏弹窗和主窗口之间切换，随时查看歌词与队列
- **桌面歌词** — 独立悬浮歌词窗口，支持双行、单行、竖排、锁定和点击穿透
- **Apple Music / iTunes 资料库导入** — 读取 Mac 上 Music App 中可访问的歌曲和歌单；本地非 DRM 文件可直接播放
- **专业输出控制** — 选择音频输出设备，使用应用内音量，并可切换高保真或音效处理链
- **完整资料库工具** — 智能歌单、重复歌曲清理、标签编辑、歌单导入导出和独立批量刮削窗口
- **桌面小组件与多屏显示** — 正在播放、歌词、统计等 WidgetKit 小组件，以及外接屏大封面和大字歌词
- **DLNA 投送与系统控制** — 发现局域网播放器并投送，支持媒体键和自定义播放快捷键
- **外观自定义** — 浅色/深色模式、主题色、动态封面取色和多套应用图标

## Apple TV 版

Apple TV 客户端可以浏览整座曲库、直接连接多种音乐源，并通过 iCloud 或局域网从 iPhone 接收资料库、凭据和播放所需配置。

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

- **大屏整库浏览** — 浏览专辑、艺术家、歌曲和歌单，支持全部播放、整库随机播放与 Siri Remote 操作
- **来源直连与中继** — WebDAV、UPnP/DLNA、云盘和服务器源按各自协议解析；SMB、NFS、FTP 支持 TV 本机读取，其他部分来源可使用可选的 iPhone 局域网中继
- **扫码传输配置** — Apple TV 展示一次性二维码，iPhone 可在局域网内直接发送资料库快照、音乐源和加密凭据，不要求两台设备使用同一 Apple ID
- **凭据管理** — 支持 iCloud 同步、局域网配对传输，以及直接在 TV 上输入部分服务器账号
- **同步歌词** — 读取本地缓存、来源 Sidecar 或服务端歌词，显示逐行/逐字进度与翻译
- **顶部展示** — 在 tvOS 主屏展示最近播放和专辑内容，并通过深层链接回到对应内容
- **多语言界面** — 支持简体中文、繁体中文、英语、德语、法语、日语和韩语

> Apple TV 的可播放路径取决于来源类型、凭据和中继设置。DTS/DTS-CD 的 FFmpeg 兼容解码目前仅面向 iPhone、iPad 和 Mac。

## Apple Watch 与系统集成

- **Apple Watch 遥控器** — 显示封面、歌曲信息、当前歌词和播放进度，支持播放/暂停、上一首、下一首、拖动进度与队列选歌
- **表盘复杂功能** — 在表盘显示当前播放状态，并快速回到 Watch App
- **主屏幕小组件** — 提供正在播放、快速访问、歌词、听歌统计、音乐源和年度回顾等多种尺寸
- **控制中心组件** — 在 iOS 控制中心执行播放/暂停、随机播放、上一首和下一首
- **CarPlay** — 浏览最近播放、歌单、专辑与艺术家，并使用车载正在播放界面和系统语音控制
- **Siri 与快捷指令** — 通过 App Intents 和媒体意图控制播放、随机播放及切歌
- **Spotlight** — 索引歌曲、专辑和艺术家，从系统搜索直接打开内容
- **系统播放体验** — 支持锁屏/控制中心媒体控制、耳机与蓝牙按键、AirPlay、外接屏和系统媒体键

## 音乐源

| 类别 | 当前支持 |
|------|----------|
| NAS | Synology DSM、QNAP |
| 文件协议 | SMB/CIFS、WebDAV、FTP、SFTP、NFS、S3、UPnP/DLNA |
| 音乐服务器 | Subsonic、Navidrome、Airsonic、Gonic、飞牛音乐、道理鱼 |
| 媒体服务器 | Jellyfin、Emby、Plex |
| 云盘 | 123 云盘、115、百度网盘、阿里云盘、Google Drive、OneDrive、Dropbox |
| Apple 与本地 | iPhone/iPad 文件导入、Mac 本地文件夹、Apple Music 资料库与目录 |

- **统一扫描与浏览** — 文件型来源可选择目录，服务器型来源可扫描整库；支持后台扫描、断点恢复、增量更新和元数据回填
- **按需串流与缓存** — 支持 HTTP Range 的来源边下边播，可设置缓存容量、预热队列并自动清理
- **安全凭据** — 密码与 OAuth token 存入 Keychain；来源配置、账号和播放凭据可按平台通过 iCloud 或局域网安全传输
- **受信任连接** — 可为自有 NAS 配置受信任的 TLS 或 HTTP 主机，不会全局放开不安全网络访问
- **只读来源保护** — Subsonic 系、飞牛音乐、道理鱼、UPnP 和 Apple Music 等目录型来源不会删除远端文件；刮削结果仅写入本地缓存
- **可写 Sidecar** — 支持的可写来源可将封面和 LRC 歌词回写到音频旁边；不支持写回的来源保持只读

绿联 UGOS 与 fnOS 系统级文件 API 仍在等待厂商提供稳定公开接口，因此不作为已支持的 NAS 来源。飞牛音乐是独立的音乐服务直连，不依赖 fnOS 文件 API。

## 播放与格式

- **双解码路径** — 原生 SFBAudioEngine 负责高保真播放，FFmpeg 兼容路径处理原生解码器不支持或不稳定的格式
- **广泛格式支持** — 包括 MP3、AAC/M4A、ALAC、FLAC、WAV/AIFF、APE、WavPack、OGG/Opus、WMA、TTA、TAK、Musepack、Shorten、Speex、QOA、DSF/DFF，以及 AC-3、E-AC-3、MLP/TrueHD 等
- **CUE 分轨** — 读取 UTF-8、UTF-16 和 GB18030 编码的 `.cue`，按 `INDEX 01` 将整轨镜像展开为带独立标题、序号、时间边界和 ReplayGain 的虚拟歌曲
- **DTS 与 DTS-CD** — iPhone、iPad 和 Mac 支持 `.dts` / DTS-HD，以及 WAV 容器中的 DTS-CD 识别与兼容解码
- **DSD** — 支持自动、PCM 和 DoP 播放模式，可按设备能力选择路径
- **无缝与交叉淡化** — 提供 Gapless、1–12 秒 Crossfade、开头/结尾静音跳过和下一首预热；无缝与交叉淡化按设置互斥
- **播放调整** — ReplayGain（曲目/专辑）、0.5×–2.0× 变速不变调、输出采样率匹配、睡眠定时和播放队列预取
- **音效链** — 十段均衡器、空间音频与耳机头部跟踪、压缩/限幅、混响和实时可视化
- **音乐视频** — 识别同名 MP4/M4V/MOV Sidecar，也可将没有同名音频的视频作为独立 MV 播放
- **混合来源队列** — 本地、NAS、云盘、服务器和 Apple Music 可出现在同一可见队列中，由 Primuse 负责跨来源连续切歌

## 歌词与元数据

- **内嵌与 Sidecar** — 读取音频标签、专辑封面、同名/文件夹封面、`.lrc` 歌词和同名 MV
- **逐行与逐字歌词** — 支持标准 LRC、增强逐字时间标记、点击跳转、手动浏览后自动跟随，以及 iOS/macOS/tvOS/Watch 多端显示
- **离线歌词翻译** — 使用 Apple Translation 框架翻译并缓存结果，可选择目标语言和清理缓存
- **内置刮削源** — Apple Music/iTunes Search、MusicBrainz 和 LRCLIB，按来源能力获取标签、封面或歌词
- **智能候选排序** — 综合标题、艺术家、专辑和时长排序候选；手动刮削会提示匹配不确定性，避免误写同名版本
- **批量刮削反馈** — 提供开始确认、实时进度、取消、完成统计与失败原因；适合大曲库长任务
- **自定义刮削源** — 从 JSON 或 HTTPS URL 导入，支持 GET/POST、请求头、Cookie、限速、TLS 信任域、JavaScript 解析和逐字歌词能力声明

## 资料库与同步

- **统一资料库** — 按歌曲、专辑、艺术家、流派和来源浏览，支持拼音、歌词全文和组合条件搜索
- **歌单系统** — 普通歌单、智能歌单、快速收藏，以及 M3U8 / Primuse JSON 导入导出；导入时支持自动匹配、手动补配和未匹配 CSV
- **维护工具** — 重复歌曲检测、只读来源保护、最近删除恢复、标签编辑与来源级重新扫描
- **听歌统计** — 最近播放、播放次数、时长趋势、音乐性格与年度回顾，可显示在小组件中
- **Scrobble** — 支持 Last.fm 和 ListenBrainz，失败记录可重试
- **CloudKit 同步** — 可分别同步歌单、智能歌单、音乐源、云盘账号、刮削器设置、播放历史、统计和偏好设置
- **家庭共享** — 通过 CloudKit 分享普通歌单、智能歌单和家庭音乐源；个人收藏保持私有
- **Apple Music** — 同步用户资料库和歌单，搜索 Apple Music 目录；订阅内容由 MusicKit 播放，Mac 上已确认可读的非 DRM 本地项目不依赖订阅

## 环境要求

| 组件 | 最低要求 |
|------|----------|
| 开发工具 | Xcode 26.0+、Swift 6.0+、macOS 开发环境 |
| iPhone / iPad | iOS / iPadOS 18.0+ |
| Mac App | macOS 26.0+ |
| Apple TV | tvOS 17.0+ |
| Apple Watch | watchOS 10.0+ |

## 快速开始

### 1. 克隆并打开项目

```bash
git clone git@github.com:chenqi92/primuse.git
cd primuse
open Primuse.xcodeproj
```

首次打开时，Xcode 会解析 Swift Package Manager 依赖和仓库内置的 FFmpeg XCFramework。

### 2. 配置签名

1. 在 Xcode 中选择 **Primuse** 项目。
2. 为需要构建的 App 与扩展 Target 设置自己的 Apple Developer Team。
3. iOS 主 App、Widget、Activity、Watch App、Watch Widgets、macOS、tvOS 与 Top Shelf 使用不同的 Bundle/Entitlement 组合，建议保持 Xcode 的自动签名。
4. 真机使用 DLNA Renderer 时，需要在 Apple Developer 后台为 App ID 开启 Multicast Networking，并确保描述文件包含 `com.apple.developer.networking.multicast`。

也可以修改 `project.yml` 中的 `DEVELOPMENT_TEAM`，再通过 XcodeGen 重新生成工程。

### 3. 配置本地密钥（可选）

```bash
cp Config/Secrets.local.xcconfig.example Config/Secrets.local.xcconfig
```

按需填入云盘 OAuth 和 Last.fm 配置。`Config/Secrets.local.xcconfig` 已被 Git 忽略；未配置某项内置 OAuth 凭据时，对应服务可能需要开发者自己的客户端配置。

### 4. 构建与运行

```bash
# 通用 iOS 模拟器构建
xcodebuild -project Primuse.xcodeproj \
  -scheme Primuse \
  -destination 'generic/platform=iOS Simulator' \
  build

# Apple TV 模拟器构建
xcodebuild -project Primuse.xcodeproj \
  -scheme PrimuseTV \
  -destination 'generic/platform=tvOS Simulator' \
  build

# PrimuseKit 测试
swift test --package-path PrimuseKit
```

### 5. 开发工具

仓库提供统一的本地开发脚本：

```bash
# 交互式选择操作
scripts/primuse-dev.sh

# 查看可用的 iPhone / iPad
scripts/primuse-dev.sh devices

# 覆盖安装并保留 App 数据
scripts/primuse-dev.sh ios-overwrite

# 完全重装；脚本会要求输入 DELETE，设备上的 App 数据会被清除
scripts/primuse-dev.sh ios-clean

# 构建并启动 Mac App
scripts/primuse-dev.sh mac
```

真机构建前可运行 `scripts/check-apple-signing.sh`，提前检查证书私钥和 `codesign` 权限。

## 自定义刮削源

Primuse 可通过 JSON 配置描述搜索、详情、封面和歌词端点，并用 JavaScript 解析响应。导入前会显示域名、请求方式、能力、Cookie、TLS 信任域与敏感配置警告，确认后才保存。

### 配置示例

```json
{
  "id": "my-source",
  "name": "My Music Source",
  "version": 1,
  "icon": "music.note",
  "color": "#FF6600",
  "rateLimit": 500,
  "headers": {
    "User-Agent": "Primuse"
  },
  "capabilities": ["metadata", "cover", "lyrics", "lyricsWordLevel"],
  "search": {
    "url": "https://api.example.com/search",
    "method": "GET",
    "params": {
      "q": "{{query}}",
      "artist": "{{artist}}",
      "album": "{{album}}",
      "limit": "{{limit}}"
    },
    "script": "return (response.results || []).map(function (item) { return { id: String(item.id), title: item.title, artist: item.artist, album: item.album, durationMs: item.durationMs, coverUrl: item.coverUrl }; });"
  },
  "detail": {
    "url": "https://api.example.com/tracks/{{id}}",
    "method": "GET",
    "script": "return response;"
  },
  "cover": {
    "url": "https://api.example.com/tracks/{{id}}/covers",
    "method": "GET",
    "script": "return response.covers || [];"
  },
  "lyrics": {
    "url": "https://api.example.com/tracks/{{id}}/lyrics",
    "method": "GET",
    "script": "return { lrcContent: response.lrc, wordLevelLrc: response.wordLevelLrc, plainText: response.text };"
  }
}
```

### 导入与脚本约定

1. 打开 **设置 → 元数据刮削 → 导入刮削源**。
2. 粘贴 JSON 或 HTTPS 配置 URL。
3. 检查权限预览和安全警告，再确认导入。
4. 在刮削源列表中排序、启用、停用、编辑或配置 Cookie。

脚本可使用：

- `response`：已解析的 JSON 响应
- `responseText`：原始响应文本
- `externalId`：详情、封面和歌词端点的当前外部 ID
- `log(msg)`：调试日志

返回值约定：

- `search`：`[{id, title, artist, album, year, durationMs, coverUrl, trackNumber, genres}]`
- `detail`：`{title, artist, albumArtist, album, year, trackNumber, discNumber, durationMs, genres, coverUrl}`
- `cover`：`[{coverUrl, thumbnailUrl}]`
- `lyrics`：`{lrcContent, wordLevelLrc, plainText}`

不要导入来源不明的配置。自定义脚本会处理远程响应；Cookie、请求头、TLS 信任域和本地 secrets 都属于敏感权限。

## 项目结构

```text
primuse/
├── Primuse/                        # iOS 与 macOS 共用的主应用代码
│   ├── App/                        # App 入口、依赖装配、CarPlay 与外接屏 Scene
│   ├── Services/
│   │   ├── AppleMusic/             # MusicKit 目录、资料库与混合队列
│   │   ├── Audio/                  # 播放引擎、原生/FFmpeg 解码、缓存与音效
│   │   ├── Cloud/                  # CloudKit、家庭共享、跨端快照和凭据同步
│   │   ├── DLNA/                   # UPnP/AV Renderer 与投送
│   │   ├── Library/                # GRDB 资料库、扫描、Spotlight 与维护工具
│   │   ├── Metadata/               # 标签、Sidecar、刮削器和歌词翻译
│   │   ├── Relay/                  # iPhone 到 Apple TV 的局域网中继
│   │   ├── Sources/                # NAS、协议、服务器和云盘连接器
│   │   └── Watch/                  # WatchConnectivity 桥接
│   ├── Views/                      # iOS 与 macOS 界面
│   └── Resources/                  # 七种本地化、资源和隐私清单
├── PrimuseKit/                     # 跨 iOS/macOS/tvOS 共享模型、策略与流解析
├── PrimuseTV/                      # Apple TV App
├── PrimuseTopShelf/                # tvOS Top Shelf 扩展
├── PrimuseWatch/                   # Apple Watch App
├── PrimuseWatchShared/             # Watch App 与复杂功能共享模型
├── PrimuseWatchWidgets/            # Watch 表盘复杂功能
├── PrimuseWidgetExtension/         # iOS/macOS 小组件与控制中心组件
├── PrimuseActivityExtension/       # Live Activity 布局目标（当前未在主 App 启用）
├── Frameworks/FFmpeg/              # iOS/macOS FFmpeg XCFramework
├── Config/                         # Entitlements、xcconfig 与 Info 配置
├── scripts/                        # 构建、安装、签名、FFmpeg 与截图工具
└── project.yml                     # XcodeGen 工程定义与统一版本号
```

## 依赖包

| 包或框架 | 用途 |
|----------|------|
| [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) | 高保真音频解码与 DSD 支持 |
| FFmpeg 8.1（仓库内动态 XCFramework） | DTS/DTS-CD、多声道降混和兼容格式解码 |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite 资料库持久化 |
| [AMSMB2](https://github.com/amosavian/AMSMB2) | SMB/CIFS 客户端 |
| [FileProvider](https://github.com/amosavian/FileProvider) | FTP 与 WebDAV 文件操作 |
| [Citadel](https://github.com/orlandos-nl/Citadel) | SSH/SFTP 客户端 |
| [NFSKit](https://github.com/alexiscn/NFSKit) | NFS 客户端 |
| [swift-crypto](https://github.com/apple/swift-crypto) | 加密与签名操作 |
| [swift-nio](https://github.com/apple/swift-nio) | 异步网络基础设施 |

系统框架包括 MusicKit、CloudKit、AVFoundation、MediaPlayer、CarPlay、WidgetKit、WatchConnectivity、App Intents、Core Spotlight、Translation 和 Network.framework。

## 架构

### 音频管线

```text
本地 / NAS / 协议 / 媒体服务器 / 云盘
  → SourceManager / StreamResolver / Range Fetcher
  → CUE Segment 与缓存/预热策略
  → NativeAudioDecoder（SFBAudioEngine）或 FFmpegAudioDecoder
  → AVAudioConverter
  → AVAudioEngine（Player → Mixer → EQ / Dynamics / Reverb → Output）

Apple Music
  → MusicKit ApplicationMusicPlayer
  → Primuse 混合队列与系统 Now Playing 状态协调
```

### 元数据与歌词

```text
扫描来源
  → 文件标签 + Sidecar + CUE 展开
  → MetadataBackfillService
  → GRDB 资料库与 MetadataAssetStore

手动 / 自动 / 批量刮削
  → ScraperManager
  → 内置或 JSON + JavaScript 自定义刮削器
  → 标题/艺术家/专辑/时长候选排序
  → 本地缓存，或 SidecarWriteService 写回受支持来源
```

### 跨设备数据

```text
iPhone / iPad / Mac
  ↔ CloudKit：歌单、来源、设置、历史、统计、资料库快照
  ↔ iCloud Keychain / 加密凭据包
  ↔ Apple TV：CloudKit 同步或局域网二维码直传
  ↔ Apple Watch：WatchConnectivity 播放状态与控制命令
```

### CI/CD

- **Build** — GitHub Actions 手动工作流，执行品牌检查、Swift Package 解析和 iOS 模拟器构建；版本变化时可生成未签名 IPA Artifact
- **Release** — 手动归档、签名、导出 IPA，并可选择上传到 TestFlight

## 说明

Primuse 不提供音乐内容或云存储。你需要使用自己的文件、服务器和第三方账号；各服务的可用性取决于提供商、地区、账号权限和 API 状态。请遵守内容来源的服务条款和适用法律。
