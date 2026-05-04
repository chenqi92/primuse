import ActivityKit
import Foundation
import UIKit
import PrimuseKit

@MainActor
@Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var currentActivity: Activity<PlaybackActivityAttributes>?

    /// 上一次完整 state — 让 updateLyrics / updateProgress 这类只改一两个
    /// 字段的更新不丢其他字段。
    private var lastState: PlaybackActivityAttributes.ContentState?

    /// 节流: ActivityKit 限速 (官方建议 < 1Hz, 实际能 ~2Hz, 超太多被系统
    /// 静默丢弃)。歌词行切换 + progress 更新 + isPlaying 都共用一个
    /// 节流通道。
    private var lastUpdateAt: Date = .distantPast
    private static let updateMinInterval: TimeInterval = 0.8
    /// 歌词变化优先 — 哪怕节流也立刻发, 否则用户看的歌词会慢半拍。
    private var lastLyricLine: String?

    /// App Group shared container URL
    private static let containerURL: URL? = {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier)
    }()

    // MARK: - Cover directory (via MetadataAssetStore)

    private static let artworkDir: URL = MetadataAssetStore.shared.artworkDirectoryURL

    // MARK: - Public API

    func startActivity(song: Song, isPlaying: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // 已有 activity (上一首歌的) — 先 end, 重启用新 attributes
        // (Activity.attributes 是 immutable, 换歌只能新开)
        if currentActivity != nil {
            Task { await endActivity() }
        }

        // Write cover image to App Group shared container
        let coverName = writeCoverToSharedContainer(song: song)

        let attributes = PlaybackActivityAttributes(
            songTitle: song.title,
            artistName: song.artistName ?? "",
            albumTitle: song.albumTitle ?? "",
            duration: song.duration,
            coverImageName: coverName
        )

        // start 时直接把 startedAt 设进初始 state, widget 第一帧渲染就能用
        // ProgressView(timerInterval:) 走自动 tick 路径; 之前先 nil 再异步
        // update, widget 第一帧拿到 nil 走静态分支, 跟实际进度永远对不上。
        let state = PlaybackActivityAttributes.ContentState(
            isPlaying: isPlaying,
            elapsedTime: 0,
            startedAt: isPlaying ? Date() : nil
        )

        let content = ActivityContent(state: state, staleDate: nil)

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            lastState = state
            lastLyricLine = nil
            lastUpdateAt = Date()
        } catch {
            plog("⚠️ Live Activity start failed: \(error.localizedDescription)")
        }
    }

    /// 进度 / 播放状态变化时调 — 内部计算 startedAt 锚点让 ProgressView
    /// 自动 tick, 不需要每秒 push elapsedTime (大幅省 ActivityKit 配额)。
    /// 实际只在 isPlaying 变化或 currentTime 跳变 (seek) 时需要 push。
    func updateActivity(isPlaying: Bool, elapsedTime: TimeInterval, nextSong: String? = nil) async {
        guard currentActivity != nil else { return }
        let prev = lastState
        var s = prev ?? PlaybackActivityAttributes.ContentState(isPlaying: isPlaying, elapsedTime: elapsedTime)
        s.isPlaying = isPlaying
        s.elapsedTime = elapsedTime
        // 锚点: isPlaying 时 = now - elapsed, ProgressView 从这个点开始往后跑;
        // 暂停时设 nil 让 UI 退化为静态显示。
        s.startedAt = isPlaying ? Date().addingTimeInterval(-elapsedTime) : nil
        if let nextSong { s.nextSongTitle = nextSong }

        // 跳过无意义的 update: isPlaying 没变 + startedAt 漂移 < 1.5s (正常 tick
        // 误差) + 没歌切。这种情况让 ProgressView 自己继续跑就行。
        if let prev,
           prev.isPlaying == s.isPlaying,
           prev.currentLyricLine == s.currentLyricLine,
           prev.nextSongTitle == s.nextSongTitle,
           let prevStart = prev.startedAt, let newStart = s.startedAt,
           abs(prevStart.timeIntervalSince(newStart)) < 1.5 {
            // 内部记录 lastState 但不发, 让 timerInterval 继续平滑跑
            lastState = s
            return
        }
        await pushUpdate(state: s, force: false)
    }

    /// 单独更新歌词字段, 其他字段沿用 lastState。歌词变化时立即发 (force),
    /// 让锁屏看到的歌词与音频同步。
    func updateLyrics(currentLine: String?, nextLine: String?) async {
        guard currentActivity != nil else { return }
        // 行没变就跳过 (避免每个 timer tick 都触发 push 浪费 ActivityKit 配额)
        if currentLine == lastLyricLine { return }
        lastLyricLine = currentLine
        var s = lastState ?? PlaybackActivityAttributes.ContentState(isPlaying: true, elapsedTime: 0)
        s.currentLyricLine = currentLine
        s.nextLyricLine = nextLine
        await pushUpdate(state: s, force: true)
    }

    func endActivity() async {
        guard let currentActivity else { return }
        nonisolated(unsafe) let activityToEnd = currentActivity
        self.currentActivity = nil
        self.lastState = nil
        self.lastLyricLine = nil

        let state = PlaybackActivityAttributes.ContentState(
            isPlaying: false,
            elapsedTime: 0
        )

        let content = ActivityContent(state: state, staleDate: nil)
        await activityToEnd.end(content, dismissalPolicy: .default)

        // Clean up cover file from shared container
        cleanupSharedCover()
    }

    /// 节流统一入口 — force=true 时跳过节流 (歌词行切换), 否则受限速控制。
    /// 节流期间的非 force 更新被丢弃, 不排队 (排队会让 elapsed/lyric 落后)。
    private func pushUpdate(state: PlaybackActivityAttributes.ContentState, force: Bool) async {
        guard let currentActivity else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastUpdateAt) < Self.updateMinInterval {
            // 静默丢弃, 但更新 lastState 让下一次 push 用最新值
            lastState = state
            return
        }
        lastState = state
        lastUpdateAt = now
        nonisolated(unsafe) let activityToUpdate = currentActivity
        let content = ActivityContent(state: state, staleDate: nil)
        await activityToUpdate.update(content)
    }

    // MARK: - Cover Image Handling

    /// Writes a downscaled cover image to the App Group shared container.
    /// Returns the filename if successful, nil otherwise.
    private func writeCoverToSharedContainer(song: Song) -> String? {
        guard let containerURL = Self.containerURL else { return nil }

        let store = MetadataAssetStore.shared

        // Try songID-based cache first (works with source path references)
        var coverData: Data?
        let hashedName = store.expectedCoverFileName(for: song.id)
        let hashedURL = Self.artworkDir.appendingPathComponent(hashedName)
        if FileManager.default.fileExists(atPath: hashedURL.path) {
            coverData = try? Data(contentsOf: hashedURL)
        }

        // Fallback: legacy local filename (no "/" or "://")
        if coverData == nil, let ref = song.coverArtFileName, !ref.isEmpty,
           !ref.contains("/"), !ref.contains("://") {
            let legacyURL = Self.artworkDir.appendingPathComponent(ref)
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                coverData = try? Data(contentsOf: legacyURL)
            }
        }

        guard let data = coverData, let originalImage = UIImage(data: data) else {
            return nil
        }

        // Downscale to 80×80 for Live Activity (Apple recommends ~84px max)
        let targetSize = CGSize(width: 80, height: 80)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resizedImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))

            // Center-crop to square
            let sourceAspect = originalImage.size.width / originalImage.size.height
            let drawRect: CGRect
            if sourceAspect > 1 {
                let scaledWidth = targetSize.height * sourceAspect
                let xOffset = (targetSize.width - scaledWidth) / 2
                drawRect = CGRect(x: xOffset, y: 0, width: scaledWidth, height: targetSize.height)
            } else {
                let scaledHeight = targetSize.width / sourceAspect
                let yOffset = (targetSize.height - scaledHeight) / 2
                drawRect = CGRect(x: 0, y: yOffset, width: targetSize.width, height: scaledHeight)
            }
            originalImage.draw(in: drawRect)
        }

        // Save as PNG (more reliable in Widget Extensions per Apple forums)
        guard let pngData = resizedImage.pngData() else { return nil }

        let sharedFileName = "live_activity_cover.png"
        let destinationURL = containerURL.appendingPathComponent(sharedFileName)

        do {
            try pngData.write(to: destinationURL, options: .atomic)
            return sharedFileName
        } catch {
            print("Failed to write cover to shared container: \(error)")
            return nil
        }
    }

    /// Removes the cover file from the shared container
    private func cleanupSharedCover() {
        guard let containerURL = Self.containerURL else { return }
        let fileURL = containerURL.appendingPathComponent("live_activity_cover.png")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
