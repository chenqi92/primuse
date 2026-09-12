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
/// - 磁盘读取 / 解码全部在后台线程 (Task.detached) 上跑, 只在攒够一批
///   后跳回 MainActor 调 MusicLibrary.updateLyricsText, 避免大库启动时
///   主线程被未命中扫描独占而卡 UI; 写入走 updateLyricsText, 避免为搜索
///   文本重建专辑/歌手索引。
/// - 失败的歌 (没缓存 / 解码失败) 不留任何痕迹, 下次启动如果 migration
///   key 被升版可以重跑。
@MainActor
@Observable
final class LyricsTextBackfillService {
    /// 升版号触发重跑。当前 v1 = 首次全量。
    private static let migrationKey = "primuse.lyricsTextBackfill.v1_initial"
    private static let batchSize = 50
    /// 解码分块仍然是 50 首 (一次后台 IO 的粒度), 但发布要攒够这么多首才
    /// 回主线程: `updateLyricsText` 每次都会整份拷 songs / visibleSongs,
    /// 每 50 首发一次等于整个迁移过程里每几百毫秒卡一下主线程。
    private static let publishBatchSize = 500

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
        // Stage 2b: 库还在准备时 `library.songs` 是空的, `run()` 会把"没有候选"
        // 当成迁移完成并永久写下标记位 —— 真正该解析的歌词从此再也不会进
        // FTS 索引。守卫放在入口, 后台 settle 与 macOS 的延后任务一起覆盖。
        guard library.isReady else {
            library.onReady { [weak self] in
                self?.startIfNeeded()
            }
            return
        }
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
        // 在 MainActor 上只做廉价的候选快照 (id + 文件名); 真正的磁盘读取 /
        // 解码在下面分 chunk 丢到后台, 避免几千首未命中缓存的歌在启动时独占
        // 主线程。
        let candidates: [Candidate] = library.songs.compactMap { song in
            guard song.lyricsText == nil, song.lyricsFileName?.isEmpty == false else { return nil }
            return Candidate(id: song.id, lyricsFileName: song.lyricsFileName)
        }
        // 二道闸: `startIfNeeded()` 之后到这里之间理论上不会翻回 `.preparing`,
        // 但写标记位是一次性的、不可逆的, 所以再确认一次。
        guard library.isReady else { return }
        guard !candidates.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
            return
        }

        // 循环本身留在可取消的 worker (MainActor) 上推进, 但把每个 chunk
        // 的磁盘读取 / 解码整批丢到后台线程, 每 chunk 只跨 actor 一次:
        // 既不在主线程上做 IO, 又能让 stop() 取消 worker 时立刻停下。
        // 取消时先把已经解码好的这一批发布出去: 发布批次是 500 首, 每次进
        // 后台都丢弃等于白读几百个歌词文件, 下次前台还要重读一遍。迁移标记位
        // 仍然只在跑完整轮之后才写, 没发布的歌 (lyricsText 仍是 nil) 下次启动
        // 会重新入选。
        var pending: [String: String] = [:]
        // indexedCount 只在这一批真的交给 updateLyricsText 时推进, 否则被取消
        // 的那几批会让进度虚报成"已入索引"。
        func publishPending() {
            guard !pending.isEmpty else { return }
            indexedCount += pending.count
            library.updateLyricsText(pending)
            pending.removeAll(keepingCapacity: true)
        }

        for start in stride(from: 0, to: candidates.count, by: Self.batchSize) {
            if Task.isCancelled {
                publishPending()
                return
            }
            let end = min(start + Self.batchSize, candidates.count)
            let chunk = Array(candidates[start..<end])

            let batch = await Self.decodeChunk(chunk)
            processedCount += chunk.count
            pending.merge(batch) { _, latest in latest }
            if Task.isCancelled {
                publishPending()
                return
            }
            if pending.count >= Self.publishBatchSize {
                publishPending()
            }
        }

        publishPending()
        if Task.isCancelled { return }
        UserDefaults.standard.set(true, forKey: Self.migrationKey)
    }

    /// 后台读取 / 解码一组候选歌词缓存, 返回 songID → 纯文本 (跳过未命中 /
    /// 空文本)。nonisolated + detached, 不碰主线程。
    private static func decodeChunk(_ chunk: [Candidate]) async -> [String: String] {
        await Task.detached(priority: .utility) { () -> [String: String] in
            let store = MetadataAssetStore.shared
            var batch: [String: String] = [:]
            batch.reserveCapacity(chunk.count)
            for candidate in chunk {
                guard let lines = store.cachedLyricsForSearch(
                    songID: candidate.id,
                    lyricsFileName: candidate.lyricsFileName
                ) else { continue }
                let text = lines
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                guard !text.isEmpty else { continue }
                batch[candidate.id] = text
            }
            return batch
        }.value
    }

    private struct Candidate: Sendable {
        let id: String
        let lyricsFileName: String?
    }
}
