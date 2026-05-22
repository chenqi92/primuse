import Foundation
import PrimuseKit

/// 一次性 backfill: 把已缓存到本地的 .lrc / Primuse JSON 歌词解析成纯文本,
/// 写入 Song.lyricsText, 让 FTS5 的 songsFts 表能对歌词内容做全文搜索。
///
/// 触发: 启动后 PrimuseApp 调 `startIfNeeded()`。完成后 UserDefaults
/// 写标记位, 后续启动直接跳过。新歌歌词在 LyricsLoader / 刮削写入时
/// 会顺手填 lyricsText (后续小改, 让新歌也进索引)。
///
/// 设计权衡:
/// - 不读远端 NAS / 云盘 .lrc, 只读 MetadataAssetStore 本地 JSON 缓存,
///   避免 backfill 触发大量网络 IO。
/// - 单线程 MainActor, 每 50 首 yield 一次让 UI 喘气; 不用 detached, 否则
///   要绕一圈线程切换, 且 replaceSongs 必须回 main 才安全。
/// - 失败的歌 (没缓存 / 解码失败) 不留任何痕迹, 下次启动如果 migration
///   key 被升版可以重跑。
@MainActor
@Observable
final class LyricsTextBackfillService {
    /// 升版号触发重跑。当前 v1 = 首次全量。
    private static let migrationKey = "primuse.lyricsTextBackfill.v1_initial"
    private static let batchSize = 50

    private let library: MusicLibrary
    private(set) var isRunning: Bool = false
    private(set) var processedCount: Int = 0
    private(set) var indexedCount: Int = 0

    private var worker: Task<Void, Never>?

    init(library: MusicLibrary) {
        self.library = library
    }

    /// 已经跑过就直接 noop。可在 app launch 调用, 廉价。
    func startIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migrationKey),
              !isRunning,
              worker == nil else { return }
        isRunning = true
        processedCount = 0
        indexedCount = 0
        worker = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        isRunning = false
    }

    private func run() async {
        defer {
            isRunning = false
            worker = nil
        }
        let store = MetadataAssetStore.shared
        let candidates = library.songs.filter {
            $0.lyricsText == nil && ($0.lyricsFileName?.isEmpty == false)
        }
        guard !candidates.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
            return
        }

        var batch: [Song] = []
        batch.reserveCapacity(Self.batchSize)
        for song in candidates {
            if Task.isCancelled { return }
            processedCount += 1
            guard let lines = store.cachedLyricsForSearch(
                songID: song.id,
                lyricsFileName: song.lyricsFileName
            ) else { continue }
            let text = lines
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !text.isEmpty else { continue }
            var updated = song
            updated.lyricsText = text
            batch.append(updated)
            indexedCount += 1

            if batch.count >= Self.batchSize {
                library.replaceSongs(batch)
                batch.removeAll(keepingCapacity: true)
                await Task.yield()
            }
        }
        if !batch.isEmpty {
            library.replaceSongs(batch)
        }
        UserDefaults.standard.set(true, forKey: Self.migrationKey)
    }
}
