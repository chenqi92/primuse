<p align="right"><strong>中文</strong> · <a href="CHANGELOG.en.md">English</a></p>

# Changelog
---

## [1.7.0] (build 20) - 2026-07-18

本版本范围从 `4a8937f9` 开始，聚焦大型曲库性能、首页与资料库体验，以及 iPhone、Mac 和 Apple TV 的跨平台适配。

### Added

- **首页模块自定义** —— 可显示、隐藏并调整“继续听”“快捷收藏”“为你推荐”“我的歌单”“常听艺术家”“最近添加”和听歌统计的顺序
- **快捷收藏与搜索** —— 可将专辑、艺术家或歌单固定为快捷收藏，编辑时可搜索，已选择项目集中展示以便快速取消
- **首次安装功能导览** —— 介绍云盘、NAS、Apple Music、元数据刮削、跨设备播放、App 图标和首页排版等核心能力
- **完整更新日志** —— 更新提示支持长内容展开、收起，较多的版本变更也能完整展示
- **GitHub 反馈入口** —— 在“关于”中可打开项目仓库或 Issues，便于更快查看和跟进问题

### Changed

- **NAS 支持状态** —— 绿联 UGOS 与飞牛 fnOS 等待厂商公开 API，当前标记为暂未开放且不再进入新增配置流程
- **123 云盘 OAuth 回调** —— 从 HTTPS 中转改为已登记的 App 深链直接回调，并严格校验 scheme、host、path 与 state
- **首页与资料库布局** —— 区分不同内容类型的卡片层级，重做资料库快捷收藏和歌曲、专辑、艺术家、歌单入口
- **MV 播放体验** —— 竖屏播放器中的视频区域更大，iPhone 进入全屏时自动横向显示，退出后恢复原方向
- **Apple Music 歌单显示** —— 禁用 Apple Music 同步或音乐源时隐藏只读镜像歌单，重新启用后可恢复
- **macOS 与 tvOS 适配** —— 完善多语言、品牌名称、Mac 设置界面和 Apple TV 导航、遥控器播放控制

### Fixed

- **歌曲标题** —— 扫描和标签回填优先采用音频内嵌标题，不再始终显示文件名
- **Spotlight 稳定性** —— 改用 ImageIO 在后台生成封面缩略图，修复 UIKit 图像渲染引发的闪退并降低峰值内存
- **tvOS 导航与播放控制** —— 修复筛选焦点、返回标签栏、全局播放暂停及远程命令的主线程问题

### Performance

- **扫描与标签读取** —— 批量提交曲库变更、降低进度发布与检查点写入频率，并将大型 JSON 编码移出主线程
- **首页与音乐源列表** —— 缓存首页快照、封面取色、来源歌曲分组和待回填计数，减少滚动时的重复遍历与视图刷新
- **大型曲库索引** —— 合并封面失效通知和扫描检查点写入，降低万首级曲库持续扫描时的主线程开销

---

## [1.6.4] (build 19) - 2026-07-14

### Added

- 支持无需账号的访客连接，并完善 SMB、S3、WebDAV 等来源的端口校验
- 支持独立音乐视频文件格式，解析并持久化 MV 时长
- 为 Jellyfin、Emby、Plex 增加服务器基础路径、服务器端元数据刷新和刮削结果回写
- 新增 4 款 App 图标主题

### Changed

- 优化刮削源导入和云存储连接流程
- 加强中文标题修复与媒体服务器扫描结果匹配

### Fixed

- 修复 Jellyfin、Emby 的认证、扫描和音频直连播放
- 修复 SSL 切换时默认端口不更新、设备信任令牌不同步等连接问题

---

## [1.6.3] (build 18) - 2026-07-08

### Added

- 没有可直接播放 URL 的音乐源也可通过渐进下载播放 MV
- MV 流式加载支持按需缓存、Range 请求与播放失败回退

### Fixed

- 修复 MV 全屏状态、缓存清理、音频回退和写入竞争等边界问题
- 统一 macOS App 产物名称，避免构建和安装时产生两个不同名称

---

## [1.6.2] (build 17) - 2026-06-15

### Added

- 支持本地文件夹整包导入，并完善重复导入和重装后的文件恢复
- 123 云盘接入第三方 OAuth 授权，支持封面与歌词回写
- 新增 MV sidecar 发现、独立播放模式、全屏控制和本地缓存
- 支持播放列表随机播放，并整理绿联 NAS 的实验性接口脚手架（非正式支持）

### Changed

- 重做音乐源软删除、缓存清理和元数据回填失败重试
- 加固云盘错误响应识别、本地源扫描、令牌刷新和多端删除同步

### Fixed

- 修复 CarPlay 崩溃与卡顿、音频路由崩溃和标签栏超限
- 修复续扫清空歌单、误 scrobble、随机上一首崩溃、crossfade 卡死等播放问题
- 修复 Plex/Subsonic 扫描中断、Synology 重扫丢元数据、百度令牌编码和缓存文件名碰撞
- 修复已删除音乐源被旧的跨设备快照重新创建

---

## [1.6.1] (build 15/16) - 2026-06-13

### Added

- Apple TV 端补全音乐源管理、直连播放、本机扫描元数据、搜索、歌词和多语言界面
- 云盘刮削结果可回写 OneDrive、Dropbox、Google Drive、百度网盘和阿里云盘
- 新增整源离线缓存、均衡器自定义预设和蜂窝网络回填提示
- 新增繁体中文，并补全德语、法语、日语、韩语本地化

### Changed

- 全平台改为从单一配置继承版本号，iOS、macOS、tvOS、watchOS 和扩展保持一致
- Apple TV 加入本地凭据输入、连接测试、整库播放、实时进度和更完整的 Siri Remote 交互
- 重构逐字歌词滚动、切句和高亮动效

### Fixed

- 修复 OneDrive 大文件播放中断、HTTP/3 限速、缓存无扩展名导致的播放失败
- 修复 Apple TV 曲库快照下载、解压、写盘、凭据同步及返回前台后的时序问题
- 加固 TLS 证书钉扎、SFTP 主机密钥校验、日志脱敏和 OAuth 源去重
- 修复 crossfade 静音截断、解码死循环、稀疏缓存丢弃和“跟随系统输出”失效
- 修复 Widget、Live Activity、Watch、tvOS、CarPlay 及多处列表性能问题

---

## [1.6.0] (build 12-14) - 2026-06-06

### Added

- Apple TV 正式加入项目，支持真实曲库、封面、播放队列、搜索和音乐源管理
- Apple TV 支持 Synology、S3、Navidrome/Subsonic、Jellyfin、Emby、Plex、主流云盘及手机中继
- 新增 iPhone “立即推送到 Apple TV”、局域网中继和音乐源二维码配置
- 新增 Apple TV Top Shelf、全幅视差图标和 Universal Purchase 配置
- 新增 Navidrome/Subsonic、115 网盘和 123 云盘音乐源

### Changed

- 曲库快照、音乐源和加密凭据通过 iCloud 在 iPhone、Mac 与 Apple TV 间同步
- 停用音乐源后，其歌曲不再出现在资料库、统计和播放结果中

### Fixed

- 修复 Apple TV 焦点裁切、空状态、搜索键盘、播放格式识别和自签名 NAS 播放
- 修复曲库快照使用 CKAsset 时在 tvOS 下载不稳定的问题

---

## [1.5.0] (build 11/12) - 2026-05-23

> `1.5.0` 先作为开发起点建立，随后在 macOS 与 tvOS 合并过程中重新对齐 build。

### Added

- 新增完整 DLNA Controller，可发现局域网设备、投送播放并保持后台会话
- 新增 iCloud 家庭共享流程，支持邀请、接受和共享数据库路由
- 资料库主页重新设计，支持歌单封面、歌单重排和“我喜欢的”快捷入口
- macOS 原生界面全面改版，加入主题、品牌色、App 图标、桌面小组件和独立播放器体验

### Changed

- macOS 对齐 Apple Music、DLNA 投屏、家庭共享和播放快捷键
- 歌单与最近播放查询改为索引读取，减少大型曲库中的重复遍历

### Fixed

- 修复 gapless 部分缓存导致的加载死循环、歌曲未播完提前切歌
- 修复重复歌曲扫描卡住界面、清理进度丢失和歌单操作卡顿
- 修复 macOS CloudKit 启动同步刷屏、桌面小组件加载和空间音频权限问题

---

## [1.4.0] (build 11) - 2026-05-23

### Added

- Apple Music 全面集成：资料库浏览、订阅内容播放、专属正在播放界面和“我喜欢的”系统歌单
- 艺术家详情页支持直接点选歌曲播放，专辑卡片改为自适应多列

### Changed

- 重写 DLNA SSDP 发现层，提高局域网设备发现成功率

### Fixed

- 未订阅 Apple Music 时阻止无效播放请求并给出正确状态

---

## [1.3.2] (build 10) - 2026-05-22

### Added

- 新增播放速度、Hi-Res 音质徽章和空间音频
- 搜索支持拼音、歌词匹配和命中片段展示
- 新增 Last.fm 相似歌曲、歌曲电台和发现推荐
- 新增离线音频下载、ReplayGain 标签持久化和受保护的 gapless 播放
- 智能歌单支持组合规则

### Fixed

- 修复旧中文元数据编码、刮削封面刷新、歌词搜索主线程阻塞
- 加强 DLNA/UPnP 兼容性、静音音量保持和 gapless/crossfade 竞争处理

---

## [1.3.1] (build 10) - 2026-05-18

### Added

- Siri 快捷指令、Watch 表盘复杂功能、锁屏与控制中心小组件
- 灵动岛交互按钮、Spotlight 搜索、iPad 横屏播放器和外接屏
- 歌曲标签编辑器、首次使用引导、VoiceOver 和 iPad 宽屏多列布局
- 跨设备 Handoff，可传递完整播放队列
- Apple Music 搜索和 DLNA MediaRenderer 接收器模式
- 频谱可视化、DLNA 音量同步、事件订阅和调试日志
- 新增日语、韩语、德语、法语本地化

### Fixed

- 将 FFT 从实时音频线程移到后台，避免音频线程阻塞
- 修复远程流时长探测、媒体服务器直连、LRCLIB 类型转换和 OAuth 刷新编码
- 加固 QNAP、S3、Last.fm 请求和 DLNA 协议兼容性，并整理绿联 NAS 的实验性接口脚手架

---

## [1.3.0] (build 9) - 2026-05-10

### Added

- 新增 Apple Watch 独立配套 App，支持资料库浏览和正在播放控制
- 新增智能歌单、年度音乐报告和听歌统计首页概览
- 首页加入“为你推荐”“常听艺术家”“今日精选”和模块显示开关
- 新增 App Store 更新提示、手动检查更新和通用空状态插图

### Performance

- 优化大型曲库扫描和批量删除，减少元数据回填期间的主线程卡顿
- 加速百度网盘标签读取，并支持后台持续和完成通知

### Fixed

- 修复刮削封面不同步、播放器死锁、队列重排重叠和来源删除同步

---

## [1.2.0] (build 8) - 2026-05-05

### Added

- NAS、SMB、SFTP、FTP、NFS 和云盘统一支持 Range 流式播放
- 新增元数据回填服务、多候选歌词缓存和歌词离线翻译
- 新增 Last.fm / ListenBrainz scrobble、听歌统计和重复歌曲检测
- 新增 M3U8 / Primuse JSON 歌单导入导出及 CarPlay 歌单页
- 新增字级歌词扫光、平滑切句和手动刮削覆盖语义

### Changed

- 缓存改为按需增长并纳入 LRU，区分预热、下载中和真实占盘空间

### Fixed

- Last.fm 改用 desktop auth flow，修复授权 403
- 修复稀疏缓存、半成品缓存收尾、歌词缓存降级和单曲播放结束白屏

---

## [1.1.1] (build 6) - 2026-05-03

### Added

- 新增 CloudKit 音乐源、歌单和资料库同步基础设施
- 新增专辑、艺术家详情页和缓存封面组件

### Fixed

- 修复 CloudKit 系统字段缓存，避免更新已有记录时冲突
- 修复 OAuth 回调及同步模型的兼容性问题

---

## [1.1.0] (build 5) - 2026-05-01

### Added

- 新增百度网盘、Dropbox、阿里云盘、WebDAV 和 FTP 音乐源
- 新增可导入的自定义刮削源配置与管理界面
- 新增 App 图标切换、歌词字体调整和云盘令牌管理
- 改进主屏幕小组件及其云端正在播放状态

### Changed

- 重构播放服务和依赖注入，改善云盘歌曲播放与队列管理

---

## [1.0.2] (build 4) - 2026-04-14

### Added

- 建立通用云盘 OAuth 授权与令牌刷新流程
- 新增内置云盘凭据配置和云存储连接界面
- 重做正在播放与快速访问小组件

### Fixed

- 优化云存储凭据读取和播放服务状态同步

---

## [1.0.1] (build 3) - 2026-04-13

### Added

- 新增均衡器、音频效果与相关设置入口

### Changed

- 重构 SSL 信任管理，移除硬编码域名配置
- 补全项目 entitlements、签名和构建配置

---

## [1.0.0] (build 1/2) - 2026-03-28

首个 iPhone / iPad 版本。

### Added

- 本地文件、Synology、SMB、SFTP、NFS、S3、WebDAV、媒体服务器等多音乐源资料库
- 基于 SFBAudioEngine 的播放引擎、播放队列、专辑与艺术家浏览
- 普通歌单、元数据刮削、封面和歌词缓存
- 首页最近播放与专辑推荐
- CarPlay、远程控制、网络发现和基础多语言支持

---

## 早期 macOS 独立版本记录

### [1.1.0] (build 2) - 2026-05

macOS 在 1.0.0 首发上线之后的稳定性和体验升级版本。引入了与 iOS 同步的若干关键修复,并对 Mac 平台特有的窗口、布局做了打磨。

#### Added

- **音乐源登录失败提示** —— 后台 connect() 失败(密码错 / 限流 / 网络挂)时弹出提示并引导重新输入密码,通过 `AddSourceView` 重新保存后立即刷新连接器
- **歌词翻译失败 negative cache** —— Apple Translation 对不支持的语言对会确定性 throw,加 24h TTL 标记后避免每次播放都重试白白吃 CPU
- **封面内容寻址存储** —— `MetadataAssets/content/<sha>.jpg` 共享物理内容,上层只存 41 字节 redirect 指针;同专辑 50 首歌从此共用一份 JPEG
- **content/ 自动驱逐** —— 启动时跑后台 GC 清理孤儿内容,加 500MB 上限按 mtime 驱逐最老
- **macOS 桌面歌词窗口 + 菜单栏控件** —— 沿用 1.0 引入的 macOS 平台基础设施,本版本继续打磨

#### Changed

- **macOS 资料库工具搬出设置** —— 重新扫描、重新刮削、清缓存等放到资料库自身的工具菜单,避免和系统设置混在一起
- **刮削 sheet 默认全屏** —— 与 NowPlaying 的处理一致;之前 `[.medium, .large]` 会把"自动 / 手动刮削"按钮挤到下方,用户以为功能消失
- **macOS 刮削走独立 NSWindow** —— 通过 `ScrapeWindowController` 打开原生窗口,带红绿黄交通灯,不再走 SwiftUI sheet

#### Fixed

- **应用修改卡死 + 闪退** —— `applySelectedChanges` 改为先 `performClose()` 再后台 Task 跑 `replaceSong` / sidecar 写盘,避免主线程阻塞导致用户感觉卡住
- **Synology 登录风暴 + DSM 自动封禁** —— `connect()` 加 `loginTask` 单飞,多个并发预取 / 解码同时催时只发起一次登录;之前 60+ 路并发被 407 限流后触发 DSM 「自动封禁」,即便密码对也得到 400 「用户名或密码错误」
- **SFTP `try!` 崩溃风险** —— `SSHClientSettings` 闭包内的 `try! Self.authenticationMethod(...)` 改为闭包外预算好直接捕获,任何让两次调用结果不同的边界情况(密钥文件中途变化等)不再 fatal
- **歌词翻译 partial 丢失** —— `for try await response in session.translate(batch:)` 中途 throw 时,已经回来的 partial response 不再被 catch 一并丢弃
- **`isLegacyLocalRef` 运算符优先级 bug** —— `&& ||` 没加括号导致任何 `.json` 后缀都返回 true;函数虽未被调用但已修补
- **macOS 字级歌词渲染断字** —— 修字级歌词在 macOS 上的 mask 扫光不连续问题
- **macOS 刮削后歌词不刷新** —— 刮削成功通过通知触发当前播放视图重新加载歌词

#### Performance

- **封面存储压缩 ~98%** —— 同专辑下原本 N 份独立 JPEG 现在共用一份内容文件,典型场景从 50 × 200KB 压缩到 1 × 200KB + 50 × 41B
- **Synology 登录单次** —— 同 sourceID 的并发 connect() 共享一个 in-flight task,从 60+ 次请求降到 1 次
- **取消刮削 apply 后的重复 metadata 刷新** —— `PrimuseApp.songReplacementToken` onChange 已经统一处理,移除 `NowPlayingView.onComplete` 里的重复 `syncSongMetadata` / `forceRefreshNowPlayingArtwork`

---

### [1.0.0] (build 1) - 2026-04

macOS 端首发版本。

#### Added

- 跨平台音乐播放、刮削、Sidecar 回写、资料库管理等核心功能与 iOS 端一致
- macOS 桌面歌词浮窗(`DesktopLyricsView`)
- 菜单栏控件(`MacMenuBarController`)
- macOS 三栏式主界面(Sidebar + 详情区 + 底部播放控制)
- 系统托盘 mini player
- macOS 全屏播放器视图
- 通过 primuse:// URL Scheme 完成 OAuth 回调
