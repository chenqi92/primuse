import Foundation
import PrimuseKit

/// 书架上的「收藏」与服务端按书收藏（Ting Reader）的双向对账，规则见 `TingReaderFavoriteReconciliation`。
///
/// - 扫描收尾与镜像刷新时对一次账，把别的客户端收藏 / 取消的书带回书架；
/// - 书架上收藏或取消一本书（两秒内合批）后，对每个支持的源再对一次，把改动推上去。
///
/// 本机的书和服务端的书靠歌曲路径对上：路径里带着服务端书 id，书架按 `spokenWordBookIDs` 给出本机书 id。
/// 曲库还没装好、这个源一本书都没有时什么都不动，也不记基线，免得拿空集当成「全取消了」。
@MainActor
final class ServerBookFavoriteSyncService {
    typealias ConnectorProvider = @MainActor (MusicSource) -> (any ServerBookFavoriteConnector)?
    typealias Baseline = TingReaderFavoriteReconciliation.Baseline

    static let baselinesDefaultsKey = "primuse.serverBookFavorites.baselines.v1"

    private let sourcesProvider: @MainActor () -> [MusicSource]
    private let connectorProvider: ConnectorProvider
    private weak var library: MusicLibrary?
    private let collection: FavoriteCollectionStore
    private let defaults: UserDefaults
    private let localChangeDelay: Duration
    private var baselines: [String: Baseline]
    private var running: [String: Task<Void, Never>] = [:]
    private var rerunRequested: Set<String> = []
    private var localChangeTask: Task<Void, Never>?
    // deinit 不在主 actor 上，只在那里读一次。
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(
        sourcesProvider: @escaping @MainActor () -> [MusicSource],
        connectorProvider: @escaping ConnectorProvider,
        library: MusicLibrary,
        collection: FavoriteCollectionStore = .shared,
        defaults: UserDefaults = .standard,
        localChangeDelay: Duration = .seconds(2)
    ) {
        self.sourcesProvider = sourcesProvider
        self.connectorProvider = connectorProvider
        self.library = library
        self.collection = collection
        self.defaults = defaults
        self.localChangeDelay = localChangeDelay
        if let data = defaults.data(forKey: Self.baselinesDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: Baseline].self, from: data) {
            baselines = decoded
        } else {
            baselines = [:]
        }
        observer = NotificationCenter.default.addObserver(
            forName: FavoriteCollectionStore.collectedBooksDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.scheduleLocalChangeSync() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    static func supports(_ type: MusicSourceType) -> Bool {
        type == .tingReader
    }

    /// 扫描收尾 / 镜像刷新时调用。
    func refresh(source: MusicSource, applyFence: ServerMirrorApplyFence) async {
        guard Self.supports(source.type), applyFence() else { return }
        await reconcileSerially(source.id)
    }

    func syncAllNow() async {
        for source in eligibleSources() {
            await reconcileSerially(source.id)
        }
    }

    // MARK: - Scheduling

    private func eligibleSources() -> [MusicSource] {
        sourcesProvider().filter { $0.isEnabled && !$0.isDeleted && Self.supports($0.type) }
    }

    private func scheduleLocalChangeSync() {
        localChangeTask?.cancel()
        let delay = localChangeDelay
        localChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.syncAllNow()
        }
    }

    /// 同一个源同时只对一轮账；进行中又来请求就在这一轮结束后再补一轮。
    private func reconcileSerially(_ sourceID: String) async {
        if let task = running[sourceID] {
            rerunRequested.insert(sourceID)
            await task.value
            return
        }
        repeat {
            rerunRequested.remove(sourceID)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.reconcile(sourceID: sourceID)
            }
            running[sourceID] = task
            await task.value
            running[sourceID] = nil
        } while rerunRequested.contains(sourceID)
    }

    // MARK: - Reconciliation

    /// 基线按「源 + 账号」记：换了账号，上一个账号的收藏不能拿来判断谁取消了什么。
    private static func baselineKey(for source: MusicSource) -> String {
        "\(source.id)|\(source.username ?? "")"
    }

    private func reconcile(sourceID: String) async {
        guard let source = eligibleSources().first(where: { $0.id == sourceID }),
              let connector = connectorProvider(source),
              let library,
              !Self.localBooks(sourceID: sourceID, library: library).isEmpty else { return }
        let sourceTag = LogRedactionPolicy.digest(source.id)
        let key = Self.baselineKey(for: source)
        do {
            let server = try await connector.fetchServerBookFavorites()
            // 取服务端期间曲库与书架都可能变了，用现在的。
            guard eligibleSources().contains(where: { $0.id == sourceID }) else { return }
            let localBooks = Self.localBooks(sourceID: sourceID, library: library)
            guard !localBooks.isEmpty else { return }
            let previous = baselines[key]
            let plan = TingReaderFavoriteReconciliation.plan(
                serverFavorites: server,
                localBooks: localBooks,
                collectedLocalBookIDs: collection.collectedBookIDs,
                baseline: previous
            )
            collection.applyServerBookChanges(
                collect: plan.collectLocally,
                uncollect: plan.uncollectLocally,
                library: library
            )

            var failedFavorites: Set<String> = []
            var failedUnfavorites: Set<String> = []
            for bookID in plan.unfavoriteOnServer {
                do {
                    try await connector.setServerBookFavorite(bookID: bookID, isFavorite: false)
                } catch is CancellationError {
                    return
                } catch {
                    failedUnfavorites.insert(bookID)
                }
            }
            for bookID in plan.favoriteOnServer {
                do {
                    try await connector.setServerBookFavorite(bookID: bookID, isFavorite: true)
                } catch is CancellationError {
                    return
                } catch {
                    failedFavorites.insert(bookID)
                }
            }
            baselines[key] = TingReaderFavoriteReconciliation.baseline(
                plan.baseline,
                failedFavorites: failedFavorites,
                failedUnfavorites: failedUnfavorites,
                localBooks: localBooks
            )
            persistBaselines()
            if !plan.collectLocally.isEmpty || !plan.uncollectLocally.isEmpty
                || !plan.favoriteOnServer.isEmpty || !plan.unfavoriteOnServer.isEmpty {
                plog("📚 server book favorites source=\(sourceTag) first=\(previous == nil) collected=\(plan.collectLocally.count) uncollected=\(plan.uncollectLocally.count) favorited=\(plan.favoriteOnServer.count - failedFavorites.count) unfavorited=\(plan.unfavoriteOnServer.count - failedUnfavorites.count) failed=\(failedFavorites.count + failedUnfavorites.count) server=\(server.count)")
            }
        } catch is CancellationError {
            return
        } catch {
            plog("📚 server book favorites source=\(sourceTag) failed: \(error.localizedDescription)")
        }
    }

    /// 这个源在书架上的书：服务端书 id → 书架上的书 id。
    static func localBooks(sourceID: String, library: MusicLibrary) -> [String: String] {
        var result: [String: String] = [:]
        for song in library.spokenWordSongs where song.sourceID == sourceID {
            guard let reference = TingReaderAPIProtocol.trackReference(from: song.filePath),
                  result[reference.bookID] == nil,
                  let bookID = library.spokenWordBookIDs[song.id] else { continue }
            result[reference.bookID] = bookID
        }
        return result
    }

    private func persistBaselines() {
        guard let data = try? JSONEncoder().encode(baselines) else { return }
        defaults.set(data, forKey: Self.baselinesDefaultsKey)
    }
}
