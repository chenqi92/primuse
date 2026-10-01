import Foundation
import PrimuseKit

/// 用 Plex 账号绑定的源，服务器换了公网 IP、换了内网地址，或者好友重新分享后换了专属 token，
/// 都靠重新问一遍 plex.tv 跟上。启动后、回到前台时各查一次，每个源至少隔半小时。
///
/// 只改 Plex 自己给的那几种地址（见 `PlexServerLinkRefreshPolicy`），用户自己填的反代域名不动。
@MainActor
final class PlexServerLinkRefresher {
    private static let cooldown: TimeInterval = 30 * 60
    /// 启动后稍等一下再查：别和首屏抢网络，但要赶在服务器目录检查（4 秒）之前。
    private static let launchDelay: Duration = .seconds(1)

    private let sourcesStore: SourcesStore
    private let sourceManager: SourceManager
    private var lastAttemptAt: [String: Date] = [:]
    private var inFlightSourceIDs: Set<String> = []
    private var client: PlexAccountClient?
    private var didScheduleLaunch = false

    init(sourcesStore: SourcesStore, sourceManager: SourceManager) {
        self.sourcesStore = sourcesStore
        self.sourceManager = sourceManager
    }

    func startColdLaunchRefresh() {
        guard !didScheduleLaunch else { return }
        didScheduleLaunch = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            await self?.refreshLinkedSources()
        }
    }

    func applicationDidBecomeActive() {
        guard didScheduleLaunch else { return }
        Task { @MainActor [weak self] in
            await self?.refreshLinkedSources()
        }
    }

    private func refreshLinkedSources() async {
        let linked = sourcesStore.sources.filter {
            $0.type == .plex && $0.isEnabled && $0.plexServerIdentifier?.isEmpty == false
        }
        for source in linked {
            await refresh(source)
        }
    }

    private func refresh(_ source: MusicSource) async {
        guard let serverID = source.plexServerIdentifier,
              !inFlightSourceIDs.contains(source.id) else { return }
        let now = Date()
        if let last = lastAttemptAt[source.id], now.timeIntervalSince(last) < Self.cooldown { return }
        guard case let .found(accountToken) = KeychainService.passwordLookup(
            for: PlexAccountAPI.accountTokenKeychainAccount(sourceID: source.id)
        ), !accountToken.isEmpty else { return }

        lastAttemptAt[source.id] = now
        inFlightSourceIDs.insert(source.id)
        defer { inFlightSourceIDs.remove(source.id) }

        let servers: [PlexResource]
        do {
            servers = try await accountClient().servers(accountToken: accountToken)
        } catch {
            plog("⚠️ Plex link refresh failed source=\(source.id.prefix(8))… error=\(error)")
            return
        }
        guard let resource = servers.first(where: { $0.clientIdentifier == serverID }) else {
            plog("🎞️ Plex link refresh: server no longer listed source=\(source.id.prefix(8))…")
            return
        }
        // 请求途中源可能被改过、删掉或改绑了别的服务器，以现在的那一行为准。
        guard let current = sourcesStore.source(id: source.id),
              current.plexServerIdentifier == serverID else { return }

        let configuration = PlexServerLinkRefreshPolicy.refreshedConfiguration(
            current: current.effectiveConnectionConfiguration,
            routes: PlexServerConnectionPlanner.routes(for: resource)
        )
        let storedToken: String?
        switch KeychainService.passwordLookup(for: source.id) {
        case let .found(token): storedToken = token
        case .notFound: storedToken = nil
        case .temporarilyUnavailable, .failed:
            // 读不到现在的 token 就别去覆盖它，只更新线路。
            storedToken = resource.accessToken
        }
        let token = PlexServerLinkRefreshPolicy.refreshedToken(current: storedToken, resource: resource)
        guard configuration != nil || token != nil else { return }

        if let token {
            do {
                try sourceManager.credentialsWillChange(for: source.id)
            } catch {
                plog("⚠️ Plex link refresh could not prepare token change source=\(source.id.prefix(8))…")
                return
            }
            guard KeychainService.setPassword(token, for: source.id) else {
                sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                return
            }
            do {
                try sourceManager.credentialsDidChange(for: source.id)
            } catch {
                sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                return
            }
        }
        if let configuration {
            sourcesStore.update(source.id) { row in
                row.connectionConfiguration = configuration
                row = row.projectingPreferredConnectionForLegacy()
            }
        }
        plog(
            "🎞️ Plex link refreshed source=\(source.id.prefix(8))… "
                + "routes=\(configuration != nil) token=\(token != nil)"
        )
        await sourceManager.refreshConnector(for: source.id)
    }

    private func accountClient() -> PlexAccountClient {
        if let client { return client }
        let created = PlexAccountClient.standard()
        client = created
        return created
    }
}
