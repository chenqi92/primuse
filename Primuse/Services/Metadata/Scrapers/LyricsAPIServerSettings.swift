import Foundation
import Observation
import PrimuseKit

/// 用户自填的歌词 API 服务器列表。
///
/// 故意存成独立的 UserDefaults 键，而不是塞进 `ScraperSettings.sources`：老版本 App
/// 解不出新的刮削源类型，会把那一行当 `.custom` 清掉再经 KVS 同步回来；独立键能让
/// 地址列表在跨版本同步中存活。
///
/// 这份 blob 会经 iCloud 键值同步明文漫游，所以只装地址：Authorization 凭据单独放
/// 钥匙串（`LyricsAPIServerCredentialStore`），`save` 落盘前一律抹掉。模型里的
/// `authorization` 字段留着是为了解出旧版本写进 blob 的凭据，好把它们搬进钥匙串。
struct LyricsAPIServerSettings: Codable, Sendable {
    static let defaultsKey = "primuse_lyrics_api_servers_v1"

    var servers: [LyricsAPIServer]

    init(servers: [LyricsAPIServer] = []) {
        self.servers = servers
    }

    /// 解不出来就返回空列表。只解码不补凭据：结果里的 `authorization` 要么是 nil，
    /// 要么是旧版本 blob 里残留、尚未搬进钥匙串的值。要凭据的走
    /// `LyricsAPIServerCredentialStore` 或 `hydratingCredentials()`。
    static func load(defaults: UserDefaults = .standard) -> LyricsAPIServerSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(LyricsAPIServerSettings.self, from: data)
        else { return LyricsAPIServerSettings() }
        return settings
    }

    /// 只把地址落盘：凭据不进会同步的 blob。
    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(strippingCredentials()) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// blob 里是否还带着旧版本写进去的凭据（本机升级前留下的，或别的老设备刚同步过来的）。
    var carriesLegacyCredentials: Bool {
        servers.contains { !($0.authorization ?? "").isEmpty }
    }

    func strippingCredentials() -> LyricsAPIServerSettings {
        var copy = self
        for index in copy.servers.indices {
            copy.servers[index].authorization = nil
        }
        return copy
    }

    /// 给界面用的完整模型：没带凭据的条目从钥匙串补回。blob 里还带着值的保持原样，
    /// 那是尚未搬家的旧数据，比钥匙串里的更新。
    func hydratingCredentials() -> LyricsAPIServerSettings {
        var copy = self
        for index in copy.servers.indices where (copy.servers[index].authorization ?? "").isEmpty {
            copy.servers[index].authorization =
                LyricsAPIServerCredentialStore.authorization(for: copy.servers[index].id)
        }
        return copy
    }

    /// id + address 拼成的稳定字符串，给 ScraperManager 的 cacheKey 用：
    /// 改了地址或顺序都会让刮削实例重建。凭据不在里面：刮削器每次请求时才从钥匙串取，
    /// 改了凭据不用换实例。
    var fingerprint: String {
        servers
            .map { [$0.id, $0.address].joined(separator: "\u{1F}") }
            .joined(separator: "\u{1E}")
    }
}

/// 歌词 API 服务器的 Authorization 凭据存取。地址列表经 iCloud 键值同步（明文），
/// 凭据不能跟着走：单独放钥匙串，「凭据」同步开关开着时走 iCloud 钥匙串，关着就只留
/// 本机，与 AI API key 同一套规矩（`KeychainService.setPassword` 里判定）。
/// 账户名只用服务器 id，跨设备同一条地址对应同一个钥匙串条目。
enum LyricsAPIServerCredentialStore {
    static func account(for serverID: String) -> String {
        "lyrics.apiServer.\(serverID).authorization"
    }

    static func authorization(for serverID: String) -> String? {
        KeychainService.getPassword(for: account(for: serverID))
    }

    /// 空白视为删除。
    @discardableResult
    static func save(_ authorization: String?, for serverID: String) -> Bool {
        let account = account(for: serverID)
        guard let trimmed = authorization?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return KeychainService.deletePassword(for: account) }
        return KeychainService.setPassword(trimmed, for: account)
    }

    @discardableResult
    static func remove(for serverID: String) -> Bool {
        KeychainService.deletePassword(for: account(for: serverID))
    }
}

@MainActor
@Observable
final class LyricsAPIServerStore {
    static let shared = LyricsAPIServerStore()

    /// 内存模型带着凭据供界面显示与编辑；`persist` 落盘前会抹掉。
    var servers: [LyricsAPIServer] { didSet { persist() } }

    private let defaults: UserDefaults
    @ObservationIgnored private var suppressPersist = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 先搬家再登记：登记时 CloudKVSSync 可能把本机 blob 推上云，推的必须是抹白后的。
        self.servers = Self.loadMigratingLegacyCredentials(defaults: defaults)

        CloudKVSSync.shared.register(key: LyricsAPIServerSettings.defaultsKey) { [weak self] in
            self?.reloadFromDefaults()
        }
    }

    private func reloadFromDefaults() {
        let loaded = Self.loadMigratingLegacyCredentials(defaults: defaults)
        guard loaded != servers else { return }
        suppressPersist = true
        defer { suppressPersist = false }
        servers = loaded
    }

    /// 读本机 blob；旧版本写在 blob 里的凭据搬进钥匙串，再把抹白的 blob 写回本机。
    /// 这里只写 UserDefaults、不 `markChanged`：搬家不是一次编辑，抹白的 blob 一推上去，
    /// 老设备会丢凭据、再把它写回来同步过来，两边打乒乓。
    /// 返回给界面用的完整模型（凭据从钥匙串补回）。
    private static func loadMigratingLegacyCredentials(defaults: UserDefaults) -> [LyricsAPIServer] {
        let stored = LyricsAPIServerSettings.load(defaults: defaults)
        if stored.carriesLegacyCredentials {
            var allSaved = true
            for server in stored.servers {
                guard let authorization = normalizedAuthorization(server.authorization) else { continue }
                if !LyricsAPIServerCredentialStore.save(authorization, for: server.id) {
                    allSaved = false
                    plog("⚠️ [LyricsAPI] credential migration failed for server \(server.id.prefix(8))…")
                }
            }
            // 有一条没写进钥匙串就先别抹本机 blob，下次读取再试；`save` 本来就不会把凭据落盘。
            if allSaved {
                stored.save(defaults: defaults)
                plog("🔐 [LyricsAPI] moved legacy credentials into the Keychain")
            }
        }
        return stored.hydratingCredentials().servers
    }

    /// 地址不合法返回 false；authorization 空白视为 nil；数量不封顶。
    @discardableResult
    func add(address: String, authorization: String?) -> Bool {
        guard let normalized = LyricsAPIServerPolicy.normalizedAddress(address) else { return false }
        let server = LyricsAPIServer(
            address: normalized,
            authorization: Self.normalizedAuthorization(authorization)
        )
        if let authorization = server.authorization,
           !LyricsAPIServerCredentialStore.save(authorization, for: server.id) {
            plog("⚠️ [LyricsAPI] credential save failed for server \(server.id.prefix(8))…; kept in memory only")
        }
        servers.append(server)
        return true
    }

    @discardableResult
    func update(id: String, address: String, authorization: String?) -> Bool {
        guard let index = servers.firstIndex(where: { $0.id == id }),
              let normalized = LyricsAPIServerPolicy.normalizedAddress(address)
        else { return false }
        var server = servers[index]
        let authorization = Self.normalizedAuthorization(authorization)
        // 凭据没变就别碰钥匙串：钥匙串暂时读不到时内存里是空的，用户只改地址不该把凭据删掉。
        if authorization != server.authorization,
           !LyricsAPIServerCredentialStore.save(authorization, for: id) {
            plog("⚠️ [LyricsAPI] credential save failed for server \(id.prefix(8))…; kept in memory only")
        }
        server.address = normalized
        server.authorization = authorization
        servers[index] = server
        return true
    }

    func remove(id: String) {
        LyricsAPIServerCredentialStore.remove(for: id)
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
