# Primuse (猿音)

原生 iOS 音乐播放器，支持从 NAS 及网络源串流播放，具备元数据刮削、歌词显示和无缝播放功能。

## 功能特性

- **多源串流** — 支持 Synology DSM、SMB/CIFS、WebDAV、SFTP、FTP、NFS、Jellyfin、Plex
- **无缝播放** — 基于 SFBAudioEngine 的交叉淡入淡出，支持 FLAC、APE、WAV、MP3、AAC、Opus 等格式
- **元数据刮削** — 自动从外部来源B、QQ 音乐、外部来源A、咪咕、酷我、MusicBrainz、LRCLIB 获取封面、歌词和元数据
- **Sidecar 回写** — 刮削的封面 (`-cover.jpg`) 和歌词 (`.lrc`) 自动写回 NAS
- **专辑 & 艺术家封面** — 在线自动获取并本地缓存
- **实时活动** — 灵动岛和锁屏播放控制
- **小组件** — 主屏幕小组件快捷播放

## 环境要求

- **Xcode 26.0+**（已测试 26.4）
- **Swift 6.0+**
- **iOS 26.1+** 部署目标
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

也可以修改 `project.yml` 中的 `DEVELOPMENT_TEAM` 后重新生成项目。

### 4. 构建运行

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
  com.kkape.primuse
```

## 项目结构

```
primuse/
├── Primuse/                        # 主应用 Target
│   ├── App/                        # 应用入口、ContentView
│   ├── Services/
│   │   ├── Audio/                  # 播放引擎、解码器、均衡器
│   │   ├── Library/                # 音乐库、数据库
│   │   ├── Metadata/               # 刮削器、资源存储、Sidecar 写入
│   │   │   └── Scrapers/           # 外部来源B、QQ 音乐、外部来源A等
│   │   └── Sources/                # NAS 连接器、扫描器、设备发现
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

## 架构

### 音频管线

```
音源（NAS / 网络）
  → StreamingDownloadDecoder（远程）/ NativeAudioDecoder（已缓存）
  → SFBAudioEngine AudioDecoder
  → AVAudioConverter（采样率 / 格式转换）
  → AVAudioEngine（PlayerNode → 均衡器 → 混音器 → 输出）
```

### 元数据刮削

```
用户触发刮削
  → ScraperManager（按优先级依次尝试）
  → [外部来源B、QQ 音乐、外部来源A、酷我、咪咕、MusicBrainz、LRCLIB]
  → 封面 + 歌词 + 元数据
  → SidecarWriteService → NAS（<歌曲名>-cover.jpg、<歌曲名>.lrc）
  → MetadataAssetStore → 本地缓存
```

### CI/CD

项目配置了 GitHub Actions 自动构建：

- **build**：每次 push/PR 自动触发模拟器构建验证（无需签名）
- **archive**：main 分支自动构建未签名 IPA 并上传为 Artifact
