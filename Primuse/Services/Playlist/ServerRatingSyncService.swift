import Foundation
import PrimuseKit

@MainActor
protocol ServerRatingManaging: AnyObject {
    func fetchServerRating(target: ServerSongRatingTarget, source: MusicSource) async throws -> Int?
    func setServerRating(target: ServerSongRatingTarget, source: MusicSource, rating: Int?) async throws -> Int?
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
        enqueue(review, startImmediately: true)
    }

    func resume(sourceID: String? = nil) {
        guard library.readiness == .ready, !library.isExternalSnapshotWriteOwned else { return }
        // Acknowledgement can precede the debounced library snapshot. Keep
        // both pending and confirmed local edits recoverable after a restart.
        for entry in entries.values where sourceID == nil || entry.target.sourceID == sourceID {
            guard currentSource(for: entry) != nil, hasSong(for: entry.target) else { continue }
            library.restoreLocallyAuthoredServerRating(entry.review)
        }
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

    private func enqueue(_ review: LibraryReview, startImmediately: Bool) {
        guard let target = review.serverRatingTarget,
              let source = sourcesStore.source(id: target.sourceID),
              source.type == .navidrome, !source.isDeleted,
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
              source.isEnabled, !source.isDeleted, source.type == .navidrome,
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
              hasSong(for: entry.target) else { return false }
        return true
    }

    private func hasSong(for target: ServerSongRatingTarget) -> Bool {
        library.songs.contains { song in
            song.sourceID == target.sourceID && !song.isCueTrack && !song.isStreamDescriptor
                && ServerFavoriteWritebackPolicy.songID(fromConnectorPath: song.filePath, sourceType: .navidrome) == target.itemID
        }
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
