# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式,版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

iOS 与 macOS 走独立的版本流(共用 bundle ID,App Store Connect 内是两条版本线),下方按平台分别列出。

---

## macOS

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

---

## iOS

### 历史版本

iOS 端版本号当前为 **1.2.0 (build 8)**。详见仓库 git log 中 `chore(release)` / `feat` / `fix` 系列 commit。

主要里程碑:
- **1.2.0** —— 元数据回填服务、音频播放服务架构升级、听歌统计「全部」时间范围移除
- **1.1.x** —— Last.fm 改用 desktop auth flow 修 403、字级歌词字内 mask 扫光、字级 / 行级歌词覆盖语义、字级歌词丝滑过渡
- **1.0.x** —— 初始上架、CarPlay 支持、播放列表导入导出
