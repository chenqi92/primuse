import Foundation
import PrimuseKit

@MainActor
protocol ServerRatingManaging: AnyObject {
    func fetchServerRating(target: ServerSongRatingTarget, source: MusicSource) async throws -> Int?
    func setServerRating(target: ServerSongRatingTarget, source: MusicSource, rating: Int?) async throws -> Int?
    /// 这首歌(服务端条目 id)在服务端属于哪张专辑。
    func serverAlbumID(forSongItemID songItemID: String, source: MusicSource) async throws -> String?
}

extension ServerRatingManaging {
    func serverAlbumID(forSongItemID songItemID: String, source: MusicSource) async throws -> String? { nil }
}

extension SourceManager: ServerRatingManaging {}

/// Only locally authored mutations enter this device's durable outbox.
/// Portable reviews carry identity and clocks, never permission to replay writes.
@MainActor
final class ServerRatingSyncService {
    private struct Entry: Codable {
        let id: UUID
        let target: ServerSongRatingTarget
        let version: TimeInterval
        let rating: Int?
        let securityFingerprint: String
        let review: LibraryReview
        var baseline: Int?
        var pending = true
        var blockedByConflict = false
    }

    private struct Storage: Codable {
        var migratedExistingRatings = false
        var entries: [Entry] = []
    }

    private let sourceManager: any ServerRatingManaging
    private let sourcesStore: any ServerFavoriteSourcesProviding
    private let library: MusicLibrary
    private let defaults: UserDefaults
    private let storageKey: String
    private var entries: [ServerSongRatingTarget: Entry] = [:]
    private var migratedExistingRatings: Bool
    private var tasks: [String: Task<Void, Never>] = [:]
    private var freshMutations = Set<UUID>()
    /// 正在反查服务端专辑 id 的本机专辑;查完时把那一刻最新的评分发出去。
    private var albumTargetResolutions: [String: Task<Void, Never>] = [:]
    /// 各源曲库里现有歌曲的服务端条目 id,曲库一改(`songMutationGeneration` 前进)就作废。
    /// 每条评分都整库逐首解析一遍路径时,评分一多启动、回前台都把主线程卡上十几秒(#182)。
    private var songItemIDsGeneration: UInt64?
    private var songItemIDsBySource: [String: (sourceType: MusicSourceType, itemIDs: Set<String>)] = [:]

    init(
        sourceManager: any ServerRatingManaging,
        sourcesStore: any ServerFavoriteSourcesProviding,
        library: MusicLibrary,
        defaults: UserDefaults = .standard
    ) {
        self.sourceManager = sourceManager
        self.sourcesStore = sourcesStore
        self.library = library
        self.defaults = defaults
        storageKey = library.serverRatingStorageKey
        let savedData = defaults.data(forKey: storageKey)
        let storage = savedData.flatMap {
            try? JSONDecoder().decode(Storage.self, from: $0)
        } ?? Storage(migratedExistingRatings: savedData != nil)
        migratedExistingRatings = storage.migratedExistingRatings
        for entry in storage.entries {
            if let existing = entries[entry.target], existing.version > entry.version { continue }
            entries[entry.target] = entry
        }
    }

    func target(for song: Song) -> ServerSongRatingTarget? {
        guard let source = sourcesStore.source(id: song.sourceID), !source.isDeleted else { return nil }
        return ServerSongRatingTarget.make(song: song, source: source)
    }

    func localRatingDidChange(_ review: LibraryReview) {
        if review.subject.kind == .album, review.serverRatingTarget == nil {
            resolveAlbumTarget(for: review.subject)
            return
        }
        enqueue(review, startImmediately: true)
    }

    /// 本机给一张还没跟服务端对上号的专辑打了分:找一个支持专辑评分、有这张专辑的歌的源,
    /// 从其中一首歌反查服务端专辑 id,绑上再上传。清掉评分不用对号(服务端那边本来就对不上)。
    private func resolveAlbumTarget(for subject: LibraryReviewSubject) {
        guard albumTargetResolutions[subject.storageKey] == nil,
              let review = library.storedLibraryReview(for: subject),
              review.rating != nil, !review.isDeleted,
              let candidate = albumRatingCandidate(albumID: subject.entityID) else { return }
        let key = subject.storageKey
        albumTargetResolutions[key] = Task { @MainActor [weak self] in
            defer { self?.albumTargetResolutions[key] = nil }
            guard let self else { return }
            do {
                guard let albumID = try await self.sourceManager.serverAlbumID(
                    forSongItemID: candidate.songItemID, source: candidate.source
                ), let target = ServerSongRatingTarget.album(serverAlbumID: albumID, source: candidate.source),
                   let current = self.sourcesStore.source(id: candidate.source.id),
                   MusicSourceScopeFingerprint.make(for: current, includeSourceID: true)
                    == target.accountFingerprint,
                   let bound = self.library.bindServerRating(target, to: subject) else { return }
                self.enqueue(bound, startImmediately: true)
            } catch {
                plog("Server album rating lookup failed: \(String(describing: type(of: error)))")
            }
        }
    }

    /// 这张本机专辑在哪个支持专辑评分的源上有歌,取其中服务端条目 id 最小的那首(结果稳定)。
    private func albumRatingCandidate(albumID: String) -> (source: MusicSource, songItemID: String)? {
        var best: (source: MusicSource, songItemID: String)?
        for song in library.songs(forAlbum: albumID) where !song.isCueTrack && !song.isStreamDescriptor {
            guard let source = sourcesStore.source(id: song.sourceID),
                  source.isEnabled, !source.isDeleted,
                  ServerRatingWritebackPolicy.supportsAlbumRatings(source.type),
                  let itemID = ServerRatingWritebackPolicy.songID(
                    fromConnectorPath: song.filePath, sourceType: source.type
                  ) else { continue }
            if let best, (best.source.id, best.songItemID) <= (source.id, itemID) { continue }
            best = (source, itemID)
        }
        return best
    }

    /// 扫描读到的服务端专辑评分(#172)。`ratedAlbums` 是打过分的专辑(服务端专辑 id → 1…5),
    /// 不在里面的按没评分算;`songAlbumIDs` 是同一次走查里歌曲所属的服务端专辑。
    /// 只处理这次走查里见到、能唯一对上一张本机专辑的服务端专辑;采纳规则与歌曲相同。
    func serverAlbumRatingsObserved(
        source: MusicSource,
        ratedAlbums: [String: Int],
        songAlbumIDs: [String: String]
    ) {
        guard !songAlbumIDs.isEmpty, ServerRatingWritebackPolicy.supportsAlbumRatings(source.type),
              source.isEnabled, !source.isDeleted,
              library.readiness == .ready, !library.isExternalSnapshotWriteOwned else { return }
        // 本机专辑 → 它在这个源上的歌落在哪几张服务端专辑里。
        var serverAlbumsByLocalAlbum: [String: Set<String>] = [:]
        for song in library.songs where song.sourceID == source.id
            && !song.isCueTrack && !song.isStreamDescriptor {
            guard let localAlbumID = song.albumID, !localAlbumID.isEmpty,
                  let itemID = ServerRatingWritebackPolicy.songID(
                    fromConnectorPath: song.filePath, sourceType: source.type
                  ),
                  let serverAlbumID = songAlbumIDs[itemID] else { continue }
            serverAlbumsByLocalAlbum[localAlbumID, default: []].insert(serverAlbumID)
        }
        let securityFingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)
        var adopted = 0
        var changed = false
        for (localAlbumID, serverAlbumIDs) in serverAlbumsByLocalAlbum {
            // 本机一张专辑对应服务端好几张(或反过来被拆开)时说不清该听哪张的。
            guard serverAlbumIDs.count == 1, let serverAlbumID = serverAlbumIDs.first,
                  let target = ServerSongRatingTarget.album(serverAlbumID: serverAlbumID, source: source)
            else { continue }
            let subject = LibraryReviewSubject.album(localAlbumID)
            var local = library.storedLibraryReview(for: subject)
            // 已经绑在别的源 / 别的服务端专辑上的评分不抢。
            if let bound = local?.serverRatingTarget, bound != target { continue }
            let observed = ratedAlbums[serverAlbumID] ?? 0
            let decision = ServerRatingImportPolicy.decision(
                observed: observed,
                baseline: entries[target]?.baseline,
                local: local?.isDeleted == false ? (local?.rating ?? 0) : 0,
                hasPendingLocalEdit: entries[target]?.pending == true
                    || albumTargetResolutions[subject.storageKey] != nil
            )
            switch decision {
            case .keep:
                continue
            case .adopt:
                local = library.applyServerObservedRating(
                    observed == 0 ? nil : observed,
                    to: subject,
                    target: target
                )
                adopted += 1
            case .recordBaseline:
                // 两边一样:顺手对上号,之后本机再改就不用先反查专辑 id。
                if local?.serverRatingTarget == nil,
                   let bound = library.bindServerRating(target, to: subject) {
                    local = bound
                }
            }
            if entries[target] != nil {
                entries[target]?.baseline = observed
                changed = true
            } else if let local {
                entries[target] = Entry(
                    id: UUID(), target: target, version: local.ratingVersion, rating: local.rating,
                    securityFingerprint: securityFingerprint,
                    review: local,
                    baseline: observed,
                    pending: false
                )
                changed = true
            }
        }
        if changed { persist() }
        if adopted > 0 {
            plog("⭐️ \(source.name): adopted \(adopted) album rating(s) changed on the server")
        }
    }

    /// 扫描读到的服务端评分(条目 id → 0…5)。是否采纳见 `ServerRatingImportPolicy`;
    /// 采纳不是本机编辑,不进上传队列,只把基线记成服务端的值(#172)。
    func serverRatingsObserved(source: MusicSource, ratings: [String: Int]) {
        guard !ratings.isEmpty, ServerRatingWritebackPolicy.supports(source.type),
              source.isEnabled, !source.isDeleted,
              library.readiness == .ready, !library.isExternalSnapshotWriteOwned else { return }
        // 一首一首去问 `storedLibraryReview` 是「歌数 × 评分数」;先把现有评分按绑定的
        // 服务端条目、按歌曲各建一张表。合并规则与它相同。
        var boundReviews: [ServerSongRatingTarget: LibraryReview] = [:]
        var unboundReviews: [String: LibraryReview] = [:]
        for review in library.allLibraryReviews {
            if let target = review.serverRatingTarget {
                boundReviews[target] = boundReviews[target].map {
                    LibraryReviewReconciliationPolicy.winner(local: $0, remote: review)
                } ?? review
            } else {
                unboundReviews[review.subject.storageKey] = review
            }
        }
        let securityFingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)
        var adopted = 0
        var changed = false
        for song in library.songs where song.sourceID == source.id
            && !song.isCueTrack && !song.isStreamDescriptor {
            guard let target = ServerSongRatingTarget.make(song: song, source: source),
                  let observed = ratings[target.itemID] else { continue }
            let subject = LibraryReviewSubject.song(song.id)
            var local = [boundReviews[target], unboundReviews[subject.storageKey]]
                .compactMap { $0 }
                .reduce(nil as LibraryReview?) { result, next in
                    result.map { LibraryReviewReconciliationPolicy.winner(local: $0, remote: next) } ?? next
                }
            let decision = ServerRatingImportPolicy.decision(
                observed: observed,
                baseline: entries[target]?.baseline,
                local: local?.isDeleted == false ? (local?.rating ?? 0) : 0,
                hasPendingLocalEdit: entries[target]?.pending == true
            )
            switch decision {
            case .keep:
                continue
            case .adopt:
                local = library.applyServerObservedRating(
                    observed == 0 ? nil : observed,
                    to: subject,
                    target: target
                )
                adopted += 1
            case .recordBaseline:
                break
            }
            if entries[target] != nil {
                entries[target]?.baseline = observed
                changed = true
            } else if let local {
                entries[target] = Entry(
                    id: UUID(), target: target, version: local.ratingVersion, rating: local.rating,
                    securityFingerprint: securityFingerprint,
                    review: local,
                    baseline: observed,
                    pending: false
                )
                changed = true
            }
        }
        if changed { persist() }
        if adopted > 0 {
            plog("⭐️ \(source.name): adopted \(adopted) rating(s) changed on the server")
        }
    }

    /// 音乐源只换了线路（加外网地址、换 QuickConnect / FN Connect ID、改反向代理前缀）
    /// 时账号没变：已绑定评分与待发送评分里的账号指纹、安全指纹都换成新线路算出的值。
    /// 不换的话评分在界面上查不到，待发送的也会被当成换了账号直接丢掉。新值与旧版
    /// App 用同一套算法，跨设备、跨版本都对得上。换账号、改凭据不走这里，照旧作废。
    func sourceRouteDidChange(previous: MusicSource, current: MusicSource) {
        guard ServerRatingWritebackPolicy.supports(current.type),
              SourceScanContentScopePolicy.contentUnchanged(previous: previous, current: current) else {
            return
        }
        let previousAccount = MusicSourceScopeFingerprint.make(for: previous, includeSourceID: true)
        let currentAccount = MusicSourceScopeFingerprint.make(for: current, includeSourceID: true)
        let previousSecurity = MusicSourceSecurityRevision.scopedFingerprint(for: previous)
        let currentSecurity = MusicSourceSecurityRevision.scopedFingerprint(for: current)
        guard previousAccount != currentAccount || previousSecurity != currentSecurity else { return }

        library.rebindServerRatingTargets(
            sourceID: current.id,
            fromAccountFingerprint: previousAccount,
            toAccountFingerprint: currentAccount
        )
        var changed = false
        for (target, entry) in entries
        where target.sourceID == current.id && target.accountFingerprint == previousAccount {
            let rebound = ServerSongRatingTarget(
                sourceID: target.sourceID,
                itemID: target.itemID,
                accountFingerprint: currentAccount,
                itemKind: target.itemKind
            )
            entries.removeValue(forKey: target)
            changed = true
            if let newer = entries[rebound], newer.version >= entry.version { continue }
            var review = entry.review
            if review.serverRatingTarget == target { review.serverRatingTarget = rebound }
            entries[rebound] = Entry(
                id: entry.id,
                target: rebound,
                version: entry.version,
                rating: entry.rating,
                securityFingerprint: entry.securityFingerprint == previousSecurity
                    ? currentSecurity
                    : entry.securityFingerprint,
                review: review,
                baseline: entry.baseline,
                pending: entry.pending,
                blockedByConflict: entry.blockedByConflict
            )
        }
        if changed { persist() }
    }

    func resume(sourceID: String? = nil) {
        guard library.readiness == .ready, !library.isExternalSnapshotWriteOwned else { return }
        // Acknowledgement can precede the debounced library snapshot. Keep
        // both pending and confirmed local edits recoverable after a restart.
        library.restoreLocallyAuthoredServerRatings(entries.values.compactMap { entry in
            guard sourceID == nil || entry.target.sourceID == sourceID,
                  currentSource(for: entry) != nil, hasItem(for: entry) else { return nil }
            return entry.review
        })
        if !migratedExistingRatings {
            // The initial upgrade moves this installation's existing positive
            // ratings once. Bound/imported reviews and empty ratings are not writes.
            migratedExistingRatings = true
            var migratedTargets = Set<ServerSongRatingTarget>()
            let previouslyBoundTargets = Set(library.allLibraryReviews.compactMap(\.serverRatingTarget))
            for review in library.allLibraryReviews where review.subject.kind == .song
                && review.serverRatingTarget == nil && review.rating != nil && !review.isDeleted {
                guard let song = library.songForSynchronization(id: review.subject.entityID),
                      let target = target(for: song),
                      library.bindServerRating(target, to: review.subject) != nil else { continue }
                if !previouslyBoundTargets.contains(target) { migratedTargets.insert(target) }
            }
            for target in migratedTargets {
                guard let review = library.review(forServerRatingTarget: target) else { continue }
                enqueue(review, startImmediately: false)
            }
            persist()
        }
        let sourceIDs = Set(entries.values.filter {
            $0.pending && !$0.blockedByConflict && (sourceID == nil || $0.target.sourceID == sourceID)
        }.map(\.target.sourceID))
        for id in sourceIDs { start(sourceID: id) }
    }

    func waitForPendingMutations(sourceID: String) async {
        while let task = tasks[sourceID] { await task.value }
    }

    func waitForAlbumTargetResolutions() async {
        while let task = albumTargetResolutions.values.first { await task.value }
    }

    private func enqueue(_ review: LibraryReview, startImmediately: Bool) {
        guard let target = review.serverRatingTarget,
              let source = sourcesStore.source(id: target.sourceID),
              ServerRatingWritebackPolicy.supports(source.type), !source.isDeleted,
              !target.isAlbum || ServerRatingWritebackPolicy.supportsAlbumRatings(source.type),
              target.accountFingerprint == MusicSourceScopeFingerprint.make(for: source, includeSourceID: true)
        else { return }
        if let existing = entries[target], existing.version >= review.ratingVersion { return }
        let entry = Entry(
            id: UUID(), target: target, version: review.ratingVersion, rating: review.rating,
            securityFingerprint: MusicSourceSecurityRevision.scopedFingerprint(for: source),
            review: review,
            baseline: entries[target]?.baseline
        )
        entries[target] = entry
        freshMutations.insert(entry.id)
        if startImmediately {
            persist()
            start(sourceID: source.id)
        }
    }

    private func start(sourceID: String) {
        guard tasks[sourceID] == nil else { return }
        tasks[sourceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain(sourceID: sourceID)
            self.tasks[sourceID] = nil
        }
    }

    private func drain(sourceID: String) async {
        var attempted = Set<UUID>()
        while let entry = entries.values.first(where: {
            $0.target.sourceID == sourceID && $0.pending && !$0.blockedByConflict
                && !attempted.contains($0.id)
        }) {
            attempted.insert(entry.id)
            let fresh = freshMutations.remove(entry.id) != nil
            // Disabled sources keep their pending edit until re-enabled.
            guard sourcesStore.source(id: sourceID)?.isEnabled != false else { continue }
            guard let source = currentSource(for: entry), isCurrent(entry) else {
                finish(entry)
                continue
            }
            do {
                let remote = try await sourceManager.fetchServerRating(target: entry.target, source: source)
                guard currentSource(for: entry) != nil, isCurrent(entry) else { continue }
                if remote == entry.rating {
                    finish(entry, confirmed: remote ?? 0)
                    continue
                }
                if !fresh, let baseline = entry.baseline, baseline != (remote ?? 0) {
                    // Another client changed the value since this edit was queued.
                    // Keep the local choice, but require a new edit before overwriting it.
                    entries[entry.target]?.blockedByConflict = true
                    persist()
                    library.presentServerRatingError()
                    continue
                }
                entries[entry.target]?.baseline = remote ?? 0
                persist()
                let confirmed = try await sourceManager.setServerRating(
                    target: entry.target, source: source, rating: entry.rating
                )
                guard currentSource(for: entry) != nil else { continue }
                guard confirmed == entry.rating else { throw URLError(.badServerResponse) }
                // A newer local edit may have arrived while this write was in flight.
                // It inherits the actual server baseline, not this request's version.
                entries[entry.target]?.baseline = confirmed ?? 0
                if isCurrent(entry) { finish(entry, confirmed: confirmed ?? 0) }
                else { persist() }
            } catch {
                guard currentSource(for: entry) != nil, isCurrent(entry) else { continue }
                persist()
                if fresh { library.presentServerRatingError() }
                plog("Server rating sync failed: \(String(describing: type(of: error)))")
            }
        }
    }

    private func currentSource(for entry: Entry) -> MusicSource? {
        guard let source = sourcesStore.source(id: entry.target.sourceID),
              source.isEnabled, !source.isDeleted, ServerRatingWritebackPolicy.supports(source.type),
              !entry.target.isAlbum || ServerRatingWritebackPolicy.supportsAlbumRatings(source.type),
              !MusicSourceSecurityRevision.hasPendingChange(for: source.id),
              MusicSourceSecurityRevision.scopedFingerprint(for: source) == entry.securityFingerprint,
              MusicSourceScopeFingerprint.make(for: source, includeSourceID: true) == entry.target.accountFingerprint
        else { return nil }
        return source
    }

    private func isCurrent(_ entry: Entry) -> Bool {
        guard entries[entry.target]?.id == entry.id,
              let review = library.review(forServerRatingTarget: entry.target),
              review.ratingVersion == entry.version, review.rating == entry.rating,
              hasItem(for: entry) else { return false }
        return true
    }

    /// 歌曲目标看曲库里还有没有这首;专辑目标看绑着它的那张本机专辑在这个源上还有没有歌。
    private func hasItem(for entry: Entry) -> Bool {
        let target = entry.target
        guard target.isAlbum else { return hasSong(for: target, ratedSongID: entry.review.subject.entityID) }
        guard let review = library.review(forServerRatingTarget: target),
              review.subject.kind == .album else { return false }
        return library.songs(forAlbum: review.subject.entityID).contains { $0.sourceID == target.sourceID }
    }

    private func hasSong(for target: ServerSongRatingTarget, ratedSongID: String) -> Bool {
        guard let sourceType = sourcesStore.source(id: target.sourceID)?.type else { return false }
        // 打分的那首通常还在,按 id 直接看它;换了 id 或已不在时才查整个源。
        if let song = library.storedSong(id: ratedSongID),
           Self.itemID(of: song, sourceID: target.sourceID, sourceType: sourceType) == target.itemID {
            return true
        }
        return songItemIDs(sourceID: target.sourceID, sourceType: sourceType).contains(target.itemID)
    }

    private func songItemIDs(sourceID: String, sourceType: MusicSourceType) -> Set<String> {
        let generation = library.songMutationGenerationForMaintenance
        if songItemIDsGeneration != generation {
            songItemIDsGeneration = generation
            songItemIDsBySource.removeAll()
        }
        if let cached = songItemIDsBySource[sourceID], cached.sourceType == sourceType {
            return cached.itemIDs
        }
        var itemIDs = Set<String>()
        for song in library.songs {
            if let itemID = Self.itemID(of: song, sourceID: sourceID, sourceType: sourceType) {
                itemIDs.insert(itemID)
            }
        }
        songItemIDsBySource[sourceID] = (sourceType, itemIDs)
        return itemIDs
    }

    private static func itemID(of song: Song, sourceID: String, sourceType: MusicSourceType) -> String? {
        guard song.sourceID == sourceID, !song.isCueTrack, !song.isStreamDescriptor else { return nil }
        return ServerRatingWritebackPolicy.songID(fromConnectorPath: song.filePath, sourceType: sourceType)
    }

    private func finish(_ entry: Entry, confirmed: Int? = nil) {
        guard entries[entry.target]?.id == entry.id else { return }
        entries[entry.target]?.pending = false
        if let confirmed { entries[entry.target]?.baseline = confirmed }
        persist()
    }

    private func persist() {
        let storage = Storage(migratedExistingRatings: migratedExistingRatings, entries: Array(entries.values))
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
