import Foundation
import Observation
import PrimuseKit

/// 用户自填的评论 API 服务器列表。
///
/// 独立 UserDefaults 键 + CloudKVS 同步，与 `LyricsAPIServerSettings` 一致：
/// 落盘与同步的 JSON 仅存名称、地址与开关，`Authorization` 凭据一律隔离在钥匙串
/// (`CommentAPIServerCredentialStore`) 中，落盘前强制剥离。
struct CommentAPIServerSettings: Codable, Sendable {
    static let defaultsKey = "primuse_comment_api_servers_v1"

    var servers: [CommentAPIServer]

    init(servers: [CommentAPIServer] = []) {
        self.servers = servers
    }

    static func load(defaults: UserDefaults = .standard) -> CommentAPIServerSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(CommentAPIServerSettings.self, from: data)
        else { return CommentAPIServerSettings() }
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(strippingCredentials()) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func strippingCredentials() -> CommentAPIServerSettings {
        var copy = self
        for index in copy.servers.indices {
            copy.servers[index].authorization = nil
        }
        return copy
    }

    func hydratingCredentials() -> CommentAPIServerSettings {
        var copy = self
        for index in copy.servers.indices where (copy.servers[index].authorization ?? "").isEmpty {
            copy.servers[index].authorization =
                CommentAPIServerCredentialStore.authorization(for: copy.servers[index].id)
        }
        return copy
    }

    var fingerprint: String {
        servers
            .map { [$0.id, $0.name, $0.address, $0.isEnabled ? "1" : "0"].joined(separator: "\u{1F}") }
            .joined(separator: "\u{1E}")
    }
}

/// 评论 API 服务的 Authorization 凭据存取（钥匙串隔离，不进明文 UserDefaults/KVS）。
enum CommentAPIServerCredentialStore {
    static func account(for serverID: String) -> String {
        "comments.apiServer.\(serverID).authorization"
    }

    static func authorization(for serverID: String) -> String? {
        KeychainService.getPassword(for: account(for: serverID))
    }

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
final class CommentAPIServerStore {
    static let shared = CommentAPIServerStore()

    /// 内存模型含凭据供界面编辑；落盘时自动剥离。
    var servers: [CommentAPIServer] { didSet { persist() } }

    /// 供监听配置变化的缓存/视图使用。
    private(set) var revision: UInt = 0

    private let defaults: UserDefaults
    private let registersCloudSync: Bool
    @ObservationIgnored private var suppressPersist = false

    init(defaults: UserDefaults = .standard, registersCloudSync: Bool = true) {
        self.defaults = defaults
        self.registersCloudSync = registersCloudSync
        self.servers = Self.loadHydrated(defaults: defaults)

        if registersCloudSync {
            CloudKVSSync.shared.register(key: CommentAPIServerSettings.defaultsKey) { [weak self] in
                self?.reloadFromDefaults()
            }
        }
    }

    /// 当前启用且地址合法的评论源（按列表优先级排序）。
    var enabledServers: [CommentAPIServer] {
        servers.filter { $0.isEnabled && CommentAPIServerPolicy.normalizedAddress($0.address) != nil }
    }

    /// 仅在至少有一个启用且地址合法的评论源时返回 true；否则全端隐藏查看评论入口。
    var hasEnabledServers: Bool {
        !enabledServers.isEmpty
    }

    private func reloadFromDefaults() {
        let loaded = Self.loadHydrated(defaults: defaults)
        guard loaded != servers else { return }
        suppressPersist = true
        defer { suppressPersist = false }
        servers = loaded
        revision &+= 1
        Task { await SongCommentService.shared.clearCache() }
    }

    private static func loadHydrated(defaults: UserDefaults) -> [CommentAPIServer] {
        CommentAPIServerSettings.load(defaults: defaults).hydratingCredentials().servers
    }

    @discardableResult
    func add(name: String, address: String, authorization: String?, isEnabled: Bool = true) -> Bool {
        guard let normalized = CommentAPIServerPolicy.normalizedAddress(address) else { return false }
        let server = CommentAPIServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            address: normalized,
            authorization: Self.normalizedAuthorization(authorization),
            isEnabled: isEnabled
        )
        if let authorization = server.authorization,
           !CommentAPIServerCredentialStore.save(authorization, for: server.id) {
            plog("⚠️ [CommentsAPI] credential save failed for server \(server.id.prefix(8))…")
        }
        servers.append(server)
        return true
    }

    @discardableResult
    func update(id: String, name: String, address: String, authorization: String?, isEnabled: Bool? = nil) -> Bool {
        guard let index = servers.firstIndex(where: { $0.id == id }),
              let normalized = CommentAPIServerPolicy.normalizedAddress(address)
        else { return false }
        var server = servers[index]
        let authorization = Self.normalizedAuthorization(authorization)
        if authorization != server.authorization,
           !CommentAPIServerCredentialStore.save(authorization, for: id) {
            plog("⚠️ [CommentsAPI] credential save failed for server \(id.prefix(8))…")
        }
        server.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        server.address = normalized
        server.authorization = authorization
        if let isEnabled { server.isEnabled = isEnabled }
        servers[index] = server
        return true
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        guard servers[index].isEnabled != enabled else { return }
        servers[index].isEnabled = enabled
    }

    func remove(id: String) {
        CommentAPIServerCredentialStore.remove(for: id)
        servers.removeAll { $0.id == id }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
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
        revision &+= 1
        CommentAPIServerSettings(servers: servers).save(defaults: defaults)
        if registersCloudSync {
            CloudKVSSync.shared.markChanged(key: CommentAPIServerSettings.defaultsKey)
            Task { await SongCommentService.shared.clearCache() }
        }
    }
}

/// 纯本地评论隐藏与作者屏蔽存储（仅存本机 UserDefaults，不上传外部服务器）。
@MainActor
@Observable
final class SongCommentModerationStore {
    static let shared = SongCommentModerationStore()
    static let defaultsKey = "primuse.comments.moderation.v1"

    private(set) var moderation: SongCommentModeration
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(SongCommentModeration.self, from: data) {
            self.moderation = decoded
        } else {
            self.moderation = SongCommentModeration()
        }
    }

    var hiddenCommentCount: Int { moderation.hiddenCommentIDs.count }
    var blockedAuthorCount: Int { moderation.blockedAuthorKeys.count }
    var isEmpty: Bool { moderation.isEmpty }

    func hideComment(id: String) {
        var next = moderation
        next.hideComment(id: id)
        apply(next)
    }

    func blockAuthor(key: String, displayName: String) {
        var next = moderation
        next.blockAuthor(key: key, displayName: displayName)
        apply(next)
    }

    func unblockAuthor(key: String) {
        var next = moderation
        next.unblockAuthor(key: key)
        apply(next)
    }

    func clearHiddenComments() {
        var next = moderation
        next.clearHiddenComments()
        apply(next)
    }

    func clearAll() {
        apply(SongCommentModeration())
    }

    func filter(_ items: [SongCommentItem]) -> [SongCommentItem] {
        moderation.filter(items)
    }

    func filter(_ page: SongCommentsPage) -> SongCommentsPage {
        moderation.filter(page)
    }

    private func apply(_ next: SongCommentModeration) {
        guard next != moderation else { return }
        moderation = next
        if next.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
