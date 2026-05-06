import Foundation
import CryptoKit
import PrimuseKit

/// 歌词翻译缓存 — 内存 dict + disk JSON。Apple Translation 离线翻译, 翻译
/// 速度快但仍 ~10ms / 行 + 触发系统语言模型加载, 翻过的存下来下次秒出。
///
/// Key 设计: SHA256(targetLang + "|" + sourceText), 16 hex chars 截断。
/// 不带 sourceLang 因为我们 nil 让 Translation 自动检测, 一样原文返回一样
/// 翻译, 即使源语言未指定也是确定性的。
@MainActor
final class LyricsTranslationCache {
    static let shared = LyricsTranslationCache()

    private struct Persisted: Codable {
        var entries: [String: String]  // key → translated text
        /// negative cache: key → 失败时的 Date。Apple Translation 对不支持的
        /// 语言对/全是目标语言的源文 throw "无法翻译", 是确定性失败,每次播
        /// 都重试白白吃 CPU。带 24h TTL 让 Apple 更新支持后能自动恢复。
        var negativeEntries: [String: Date]?
    }

    private var entries: [String: String] = [:]
    private var negativeEntries: [String: Date] = [:]
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    /// 内存条目上限 — 超过这个数量按插入顺序丢最早的 (简化 LRU)。
    private static let maxEntries = 5000
    /// 翻译失败的 negative cache 有效期。系统如果之后支持了, 24h 后会自动重试。
    private static let negativeTTL: TimeInterval = 24 * 3600

    private var insertionOrder: [String] = []

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Primuse/LyricsTranslation", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("cache.json")
        load()
    }

    /// 取一行的翻译。命中返回 translated, 未缓存返回 nil 让调用方触发翻译。
    func translation(for source: String, targetLang: String) -> String? {
        let k = Self.makeKey(text: source, targetLang: targetLang)
        return entries[k]
    }

    /// 这一行最近 24h 内是否被标记为"翻译失败"。命中就别再 session.translate,
    /// 系统大概率还会回同样的"无法翻译"。
    func isMarkedFailed(source: String, targetLang: String) -> Bool {
        let k = Self.makeKey(text: source, targetLang: targetLang)
        guard let when = negativeEntries[k] else { return false }
        if Date().timeIntervalSince(when) > Self.negativeTTL {
            negativeEntries[k] = nil
            return false
        }
        return true
    }

    /// 批量标记翻译失败行 — 一首歌 batch translate throw 后调一次, 比逐行
    /// markFailed 更省事。
    func markFailed(sources: [String], targetLang: String) {
        guard !sources.isEmpty else { return }
        let now = Date()
        for s in sources {
            let k = Self.makeKey(text: s, targetLang: targetLang)
            negativeEntries[k] = now
        }
        scheduleSave()
    }

    /// 写入翻译。同步写内存, debounced 写盘 (避免连续翻译多行频繁 IO)。
    func setTranslation(_ translated: String, for source: String, targetLang: String) {
        let k = Self.makeKey(text: source, targetLang: targetLang)
        if entries[k] == nil {
            insertionOrder.append(k)
            if insertionOrder.count > Self.maxEntries {
                let drop = insertionOrder.removeFirst()
                entries[drop] = nil
            }
        }
        entries[k] = translated
        scheduleSave()
    }

    /// 批量写入 — 翻译完一首歌的所有行后一次性调, 比逐行 setTranslation 少
    /// 触发 scheduleSave 多次。
    func bulkSet(_ pairs: [(source: String, translated: String)], targetLang: String) {
        for (s, t) in pairs {
            let k = Self.makeKey(text: s, targetLang: targetLang)
            if entries[k] == nil {
                insertionOrder.append(k)
            }
            entries[k] = t
        }
        // LRU 收割
        while insertionOrder.count > Self.maxEntries {
            let drop = insertionOrder.removeFirst()
            entries[drop] = nil
        }
        scheduleSave()
    }

    /// 清空所有翻译缓存 — 用户在 settings 里点 "Clear" 时。
    func clearAll() {
        entries.removeAll()
        insertionOrder.removeAll()
        negativeEntries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    var count: Int { entries.count }

    // MARK: - Private

    private static func makeKey(text: String, targetLang: String) -> String {
        let raw = "\(targetLang)|\(text)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func saveNow() {
        // 写盘前把过期的 negative entry 顺手清掉, 不然会无限增长。
        let cutoff = Date().addingTimeInterval(-Self.negativeTTL)
        negativeEntries = negativeEntries.filter { $0.value > cutoff }
        let snapshot = Persisted(entries: entries, negativeEntries: negativeEntries)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            plog("⚠️ LyricsTranslationCache save failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return
        }
        entries = decoded.entries
        insertionOrder = Array(entries.keys)  // load 时不维护精确顺序, 走 dict natural 顺序
        // 载入时筛掉超过 TTL 的 negative entry, 避免老条目永远占位。
        let cutoff = Date().addingTimeInterval(-Self.negativeTTL)
        negativeEntries = (decoded.negativeEntries ?? [:]).filter { $0.value > cutoff }
    }
}
