import Foundation
import Observation
import PrimuseKit

/// 用户自填的歌词 API 服务器列表。
///
/// 故意存成独立的 UserDefaults 键，而不是塞进 `ScraperSettings.sources`：老版本 App
/// 解不出新的刮削源类型，会把那一行当 `.custom` 清掉再经 KVS 同步回来；独立键能让
/// 地址列表在跨版本同步中存活。
struct LyricsAPIServerSettings: Codable, Sendable {
    static let defaultsKey = "primuse_lyrics_api_servers_v1"

    var servers: [LyricsAPIServer]

    init(servers: [LyricsAPIServer] = []) {
        self.servers = servers
    }

    /// 解不出来就返回空列表。
    static func load(defaults: UserDefaults = .standard) -> LyricsAPIServerSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(LyricsAPIServerSettings.self, from: data)
        else { return LyricsAPIServerSettings() }
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// id + address + authorization 拼成的稳定字符串，给 ScraperManager 的 cacheKey 用：
    /// 改了地址、顺序或凭据都会让刮削实例重建。
    var fingerprint: String {
        servers
            .map { [$0.id, $0.address, $0.authorization ?? ""].joined(separator: "\u{1F}") }
            .joined(separator: "\u{1E}")
    }
}

@MainActor
@Observable
final class LyricsAPIServerStore {
    static let shared = LyricsAPIServerStore()

    var servers: [LyricsAPIServer] { didSet { persist() } }

    private let defaults: UserDefaults
    @ObservationIgnored private var suppressPersist = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.servers = LyricsAPIServerSettings.load(defaults: defaults).servers

        CloudKVSSync.shared.register(key: LyricsAPIServerSettings.defaultsKey) { [weak self] in
            self?.reloadFromDefaults()
        }
    }

    private func reloadFromDefaults() {
        let loaded = LyricsAPIServerSettings.load(defaults: defaults).servers
        guard loaded != servers else { return }
        suppressPersist = true
        defer { suppressPersist = false }
        servers = loaded
    }

    /// 地址不合法返回 false；authorization 空白视为 nil；数量不封顶。
    @discardableResult
    func add(address: String, authorization: String?) -> Bool {
        guard let normalized = LyricsAPIServerPolicy.normalizedAddress(address) else { return false }
        servers.append(LyricsAPIServer(
            address: normalized,
            authorization: Self.normalizedAuthorization(authorization)
        ))
        return true
    }

    @discardableResult
    func update(id: String, address: String, authorization: String?) -> Bool {
        guard let index = servers.firstIndex(where: { $0.id == id }),
              let normalized = LyricsAPIServerPolicy.normalizedAddress(address)
        else { return false }
        var server = servers[index]
        server.address = normalized
        server.authorization = Self.normalizedAuthorization(authorization)
        servers[index] = server
        return true
    }

    func remove(id: String) {
        servers.removeAll { $0.id == id }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        // 自己实现而不用 SwiftUI 的 MutableCollection.move，这个文件也编进 tvOS 的非界面层。
        let valid = fromOffsets.filter { servers.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { servers[$0] }
        var remaining = servers.enumerated()
            .filter { !valid.contains($0.offset) }
            .map(\.element)
        let clampedTarget = min(max(toOffset, 0), servers.count)
        let removedBeforeTarget = valid.filter { $0 < clampedTarget }.count
        let insertion = min(max(clampedTarget - removedBeforeTarget, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertion)
        servers = remaining
    }

    private static func normalizedAuthorization(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private func persist() {
        guard !suppressPersist else { return }
        LyricsAPIServerSettings(servers: servers).save(defaults: defaults)
        CloudKVSSync.shared.markChanged(key: LyricsAPIServerSettings.defaultsKey)
    }
}
