import CoreSpotlight
import CryptoKit
import Foundation
import ImageIO
import OSLog
import PrimuseKit
#if os(iOS)
import UniformTypeIdentifiers
#endif

private let spotlightLog = Logger(subsystem: "com.welape.yuanyin", category: "Spotlight")

private let kSpotlightIndexName = "com.welape.yuanyin.library.v1"
private let kSongDomain = "com.welape.yuanyin.spotlight.song"
private let kAlbumDomain = "com.welape.yuanyin.spotlight.album"
private let kArtistDomain = "com.welape.yuanyin.spotlight.artist"
private let kPlaylistDomain = "com.welape.yuanyin.spotlight.playlist"
private let kSpotlightDomains = [kSongDomain, kAlbumDomain, kArtistDomain, kPlaylistDomain]

/// Keeps the on-device Spotlight index converged with the visible music
/// library. Ordinary library changes are upserted/deleted incrementally; a
/// complete rebuild is reserved for the first named-index migration, schema
/// changes, and missing/mismatched Core Spotlight client state.
@MainActor
final class SpotlightIndexService {
    private enum WorkPhase {
        case idle
        case debouncing
        case running
    }

    private struct PlaylistSummary: Sendable {
        let id: String
        let name: String
        let songCount: Int
    }

    private struct LibrarySnapshot: Sendable {
        let songs: [Song]
        let albums: [Album]
        let artists: [Artist]
        let playlists: [PlaylistSummary]
        let artistNameConfiguration: ArtistNameConfiguration
    }

    private enum IndexPayload: Sendable {
        case song(Song, artistDisplayName: String?, coverContentIdentifier: String?)
        case album(Album)
        case artist(Artist)
        case playlist(PlaylistSummary)
    }

    private struct PreparedSnapshot: Sendable {
        let records: [SpotlightIndexRecord]
        let payloadsByIdentifier: [String: IndexPayload]
    }

    private struct ClientStateResult {
        let data: Data?
        let error: (any Error)?
    }

    private nonisolated static let schemaVersion = 1
    private nonisolated static let debounceDuration: Duration = .seconds(3)
    private nonisolated static let followUpDebounceDuration: Duration = .seconds(1)
    private nonisolated static let interBatchDelay: Duration = .milliseconds(180)
    private nonisolated static let maxItemsPerBatch = 100
    private nonisolated static let maxDeletesPerBatch = 250
    private nonisolated static let maxThumbnailCacheMissesPerBatch = 8
    private nonisolated static let synchronizationPendingKey =
        "primuse.spotlightIndex.synchronizationPending.v2"
    private nonisolated static let synchronizationGenerationKey =
        "primuse.spotlightIndex.synchronizationGeneration.v2"
    private nonisolated static let completedSynchronizationGenerationKey =
        "primuse.spotlightIndex.completedSynchronizationGeneration.v2"

    private let manifestURL: URL
    private let thumbnailDirectoryURL: URL
    private var workPhase: WorkPhase = .idle
    private var pendingTask: Task<Void, Never>?
    private var pendingGeneration: UUID?
    private var queuedSnapshot: LibrarySnapshot?
    private var needsSynchronization = true
    #if os(iOS)
    /// Keep opportunistic full-library indexing out of the interactive
    /// foreground. The scene lifecycle resumes it in the background.
    private var isSynchronizationSuspended = true
    #else
    private var isSynchronizationSuspended = false
    #endif

    init(fileManager: FileManager = .default) {
        #if os(tvOS)
        let base = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        let directory = base.appendingPathComponent("Primuse/Spotlight", isDirectory: true)
        manifestURL = directory.appendingPathComponent("index-manifest-v1.json")
        thumbnailDirectoryURL = directory.appendingPathComponent("thumbnails-v1", isDirectory: true)
        needsSynchronization = Self.isSynchronizationPending
    }

    /// Persist before hopping back to the main actor so a process termination
    /// between a library mutation and Observation delivery cannot leave a
    /// stale Spotlight manifest marked clean.
    nonisolated static func persistLibraryChangePending() {
        let defaults = UserDefaults.standard
        let generation = defaults.integer(forKey: synchronizationGenerationKey)
        defaults.set(
            generation == .max ? 1 : generation + 1,
            forKey: synchronizationGenerationKey
        )
        defaults.set(true, forKey: synchronizationPendingKey)
    }

    private nonisolated static var synchronizationGeneration: Int {
        UserDefaults.standard.integer(forKey: synchronizationGenerationKey)
    }

    private nonisolated static var isSynchronizationPending: Bool {
        let defaults = UserDefaults.standard
        return (defaults.object(forKey: synchronizationPendingKey) as? Bool ?? true)
            || defaults.integer(forKey: completedSynchronizationGenerationKey)
                != defaults.integer(forKey: synchronizationGenerationKey)
    }

    /// Coalesces rapid library mutations. If a Core Spotlight batch is already
    /// running, the latest snapshot is queued instead of overlapping two batch
    /// sessions on the same named index.
    func scheduleSynchronization(library: MusicLibrary) {
        guard !isSynchronizationSuspended else { return }
        enqueueSynchronization(library: library, delay: Self.debounceDuration)
    }

    /// Reconcile an interrupted/first-run index without turning every process
    /// launch into a new dirty event. On iOS this remains deferred until the
    /// scene enters a non-playing background window.
    func synchronizeIfNeeded(library: MusicLibrary) {
        needsSynchronization = needsSynchronization || Self.isSynchronizationPending
        guard needsSynchronization, !isSynchronizationSuspended else { return }
        enqueueSynchronization(library: library, delay: Self.debounceDuration)
    }

    private func enqueueSynchronization(library: MusicLibrary, delay: Duration) {
        let snapshot = makeLibrarySnapshot(library: library)

        switch workPhase {
        case .idle:
            beginDebouncedSynchronization(snapshot: snapshot, delay: delay)
        case .debouncing:
            pendingTask?.cancel()
            beginDebouncedSynchronization(snapshot: snapshot, delay: delay)
        case .running:
            queuedSnapshot = snapshot
        }
    }

    /// Restarts work canceled for an iOS scene transition without performing a
    /// redundant full-library comparison after every foreground activation.
    func resumePendingSynchronization(library: MusicLibrary) {
        isSynchronizationSuspended = false
        synchronizeIfNeeded(library: library)
    }

    /// Retain only the dirty bit while the user is interacting. The next
    /// background resume snapshots the latest library instead of retaining a
    /// large stale copy from an earlier publication.
    func suspendSynchronization() {
        isSynchronizationSuspended = true
        cancelPendingSynchronization()
    }

    /// Stops opportunistic CPU/file work while the app is resigning active.
    /// A running Core Spotlight commit is allowed to finish its current batch;
    /// cancellation is observed before any subsequent batch or manifest save.
    func cancelPendingSynchronization() {
        guard workPhase != .idle else { return }
        persistSynchronizationPending()
        queuedSnapshot = nil
        pendingTask?.cancel()

        if workPhase == .debouncing {
            pendingTask = nil
            pendingGeneration = nil
            workPhase = .idle
        }
    }

    /// Parses the stable identifier returned by a Spotlight user activity.
    static func identifier(from activity: NSUserActivity) -> SpotlightItem? {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return nil
        }
        return parse(uniqueIdentifier: id)
    }

    static func parse(uniqueIdentifier: String) -> SpotlightItem? {
        let parts = uniqueIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        switch String(parts[0]) {
        case "song": return .song(id: String(parts[1]))
        case "album": return .album(id: String(parts[1]))
        case "artist": return .artist(id: String(parts[1]))
        case "playlist": return .playlist(id: String(parts[1]))
        default: return nil
        }
    }

    private func makeLibrarySnapshot(library: MusicLibrary) -> LibrarySnapshot {
        let playlistSummaries = library.playlists.map { playlist in
            PlaylistSummary(
                id: playlist.id,
                name: playlist.name,
                songCount: library.songCount(forPlaylist: playlist.id)
            )
        }
        return LibrarySnapshot(
            songs: library.visibleSongs,
            albums: library.visibleAlbums,
            artists: library.visibleArtists,
            playlists: playlistSummaries,
            artistNameConfiguration: library.artistNameConfiguration
        )
    }

    private func beginDebouncedSynchronization(snapshot: LibrarySnapshot, delay: Duration) {
        let generation = UUID()
        let synchronizationRevision = Self.synchronizationGeneration
        let manifestURL = self.manifestURL
        let thumbnailDirectoryURL = self.thumbnailDirectoryURL
        pendingGeneration = generation
        workPhase = .debouncing

        pendingTask = Task.detached(priority: .background) { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  await self?.transitionToRunning(generation: generation) == true else {
                return
            }

            let succeeded = await Self.performSynchronization(
                snapshot: snapshot,
                manifestURL: manifestURL,
                thumbnailDirectoryURL: thumbnailDirectoryURL
            )
            await self?.finishSynchronization(
                generation: generation,
                synchronizationRevision: synchronizationRevision,
                succeeded: succeeded
            )
        }
    }

    private func transitionToRunning(generation: UUID) -> Bool {
        guard pendingGeneration == generation, workPhase == .debouncing else { return false }
        workPhase = .running
        return true
    }

    private func finishSynchronization(
        generation: UUID,
        synchronizationRevision completedRevision: Int,
        succeeded: Bool
    ) {
        guard pendingGeneration == generation else { return }
        pendingTask = nil
        pendingGeneration = nil
        workPhase = .idle

        if isSynchronizationSuspended {
            queuedSnapshot = nil
            persistSynchronizationPending()
            return
        }

        if let queuedSnapshot {
            self.queuedSnapshot = nil
            needsSynchronization = true
            beginDebouncedSynchronization(
                snapshot: queuedSnapshot,
                delay: Self.followUpDebounceDuration
            )
        } else {
            if succeeded, completedRevision == Self.synchronizationGeneration {
                UserDefaults.standard.set(
                    completedRevision,
                    forKey: Self.completedSynchronizationGenerationKey
                )
                needsSynchronization = false
                UserDefaults.standard.set(false, forKey: Self.synchronizationPendingKey)
            } else {
                persistSynchronizationPending()
            }
        }
    }

    private func persistSynchronizationPending() {
        needsSynchronization = true
        Self.persistLibraryChangePending()
    }

    private nonisolated static func performSynchronization(
        snapshot: LibrarySnapshot,
        manifestURL: URL,
        thumbnailDirectoryURL: URL
    ) async -> Bool {
        guard canPerformIndexing, !Task.isCancelled else {
            spotlightLog.notice("Spotlight sync deferred because of thermal/low-power state")
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: thumbnailDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            spotlightLog.error("Spotlight cache setup failed: \(error.localizedDescription)")
            return false
        }

        guard let prepared = prepareSnapshot(snapshot), !Task.isCancelled else { return false }
        let previousManifest = loadManifest(from: manifestURL)
        let index = CSSearchableIndex(name: kSpotlightIndexName)
        let clientStateResult = await fetchClientState(from: index)
        if let error = clientStateResult.error {
            // A transiently unavailable index is not evidence that its contents
            // are stale. Defer instead of turning a read failure into a rebuild.
            spotlightLog.error("Spotlight client-state fetch failed: \(error.localizedDescription)")
            return false
        }
        let expectedClientState = previousManifest.map(clientState(for:))
        let clientStateMatches = clientStateResult.data == expectedClientState
        let forceFullRebuild = previousManifest != nil && !clientStateMatches
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: prepared.records,
            previousManifest: previousManifest,
            schemaVersion: schemaVersion,
            forceFullRebuild: forceFullRebuild
        )

        if plan.isEmpty, !plan.requiresFullRebuild {
            spotlightLog.debug("Spotlight index already matches the library")
            return true
        }

        guard canPerformIndexing, !Task.isCancelled else { return false }
        let pendingState = Data("v\(schemaVersion):pending".utf8)

        do {
            if plan.requiresFullRebuild {
                // Mark the named index dirty before clearing it. If the app is
                // suspended after deletion but before the first item batch,
                // the next launch will detect the mismatch and recover again.
                try await applyBatch(
                    to: index,
                    deletingIdentifiers: [],
                    searchableItems: [],
                    clientState: pendingState
                )
                guard canPerformIndexing, !Task.isCancelled else { return false }
                try await deleteDomains(kSpotlightDomains, from: index)
            }

            var deleteCursor = 0
            while deleteCursor < plan.identifiersToDelete.count {
                guard canPerformIndexing, !Task.isCancelled else { return false }
                let end = min(
                    deleteCursor + maxDeletesPerBatch,
                    plan.identifiersToDelete.count
                )
                let identifiers = Array(plan.identifiersToDelete[deleteCursor..<end])
                try await applyBatch(
                    to: index,
                    deletingIdentifiers: identifiers,
                    searchableItems: [],
                    clientState: pendingState
                )
                deleteCursor = end
                guard await pauseBetweenBatches() else { return false }
            }

            var upsertCursor = 0
            while upsertCursor < plan.identifiersToUpsert.count {
                guard canPerformIndexing, !Task.isCancelled else { return false }
                var searchableItems: [CSSearchableItem] = []
                searchableItems.reserveCapacity(maxItemsPerBatch)
                var thumbnailCacheMissCount = 0

                while upsertCursor < plan.identifiersToUpsert.count,
                      searchableItems.count < maxItemsPerBatch,
                      thumbnailCacheMissCount < maxThumbnailCacheMissesPerBatch {
                    let identifier = plan.identifiersToUpsert[upsertCursor]
                    guard let payload = prepared.payloadsByIdentifier[identifier] else {
                        spotlightLog.error("Spotlight payload missing for \(identifier, privacy: .public)")
                        return false
                    }
                    let item = makeSearchableItem(
                        payload: payload,
                        thumbnailDirectoryURL: thumbnailDirectoryURL
                    )
                    searchableItems.append(item.searchableItem)
                    if item.thumbnailCacheMiss {
                        thumbnailCacheMissCount += 1
                    }
                    upsertCursor += 1
                }

                try await applyBatch(
                    to: index,
                    deletingIdentifiers: [],
                    searchableItems: searchableItems,
                    clientState: pendingState
                )
                guard await pauseBetweenBatches() else { return false }
            }

            guard canPerformIndexing, !Task.isCancelled else { return false }
            let finalClientState = clientState(for: plan.nextManifest)
            try await applyBatch(
                to: index,
                deletingIdentifiers: [],
                searchableItems: [],
                clientState: finalClientState
            )

            if plan.requiresFullRebuild {
                do {
                    try await deleteDomains(kSpotlightDomains, from: .default())
                } catch {
                    spotlightLog.error("Legacy Spotlight cleanup failed: \(error.localizedDescription)")
                }
            }

            guard !Task.isCancelled else { return false }
            try saveManifest(plan.nextManifest, to: manifestURL)
            spotlightLog.notice(
                "Spotlight synchronized: upsert=\(plan.identifiersToUpsert.count) delete=\(plan.identifiersToDelete.count) full=\(plan.requiresFullRebuild)"
            )
            return true
        } catch {
            spotlightLog.error("Spotlight synchronization failed: \(error.localizedDescription)")
            return false
        }
    }

    private nonisolated static func prepareSnapshot(
        _ snapshot: LibrarySnapshot
    ) -> PreparedSnapshot? {
        let totalCount = snapshot.songs.count
            + snapshot.albums.count
            + snapshot.artists.count
            + snapshot.playlists.count
        var records: [SpotlightIndexRecord] = []
        records.reserveCapacity(totalCount)
        var payloads: [String: IndexPayload] = [:]
        payloads.reserveCapacity(totalCount)
        var coverIdentityCache: [String: String] = [:]
        var missingCoverIdentities: Set<String> = []

        for (offset, song) in snapshot.songs.enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return nil }
            let identifier = "song:\(song.id)"
            let coverContentIdentifier: String?
            if let coverRef = song.coverArtFileName, !coverRef.isEmpty {
                if let cached = coverIdentityCache[coverRef] {
                    coverContentIdentifier = cached
                } else if missingCoverIdentities.contains(coverRef) {
                    coverContentIdentifier = nil
                } else if let identity = MetadataAssetStore.shared
                    .coverContentIdentifier(named: coverRef) {
                    coverIdentityCache[coverRef] = identity
                    coverContentIdentifier = identity
                } else {
                    missingCoverIdentities.insert(coverRef)
                    coverContentIdentifier = nil
                }
            } else {
                coverContentIdentifier = nil
            }
            let artistDisplayName = song.displayArtistName(
                configuration: snapshot.artistNameConfiguration
            )
            let signature = contentSignature([
                song.title,
                song.albumTitle,
                artistDisplayName,
                snapshot.artistNameConfiguration.cacheSignature,
                song.coverArtFileName,
                coverContentIdentifier,
            ])
            records.append(SpotlightIndexRecord(identifier: identifier, signature: signature))
            payloads[identifier] = .song(
                song,
                artistDisplayName: artistDisplayName,
                coverContentIdentifier: coverContentIdentifier
            )
        }

        for album in snapshot.albums {
            let identifier = "album:\(album.id)"
            records.append(SpotlightIndexRecord(
                identifier: identifier,
                signature: contentSignature([album.title, album.artistName])
            ))
            payloads[identifier] = .album(album)
        }

        let artistSubtitle = String(localized: "spotlight_artist_subtitle")
        for artist in snapshot.artists {
            let identifier = "artist:\(artist.id)"
            records.append(SpotlightIndexRecord(
                identifier: identifier,
                signature: contentSignature([artist.name, artistSubtitle])
            ))
            payloads[identifier] = .artist(artist)
        }

        for playlist in snapshot.playlists {
            let identifier = "playlist:\(playlist.id)"
            let subtitle = String(
                format: String(localized: "spotlight_playlist_subtitle_format"),
                playlist.songCount
            )
            records.append(SpotlightIndexRecord(
                identifier: identifier,
                signature: contentSignature([playlist.name, subtitle])
            ))
            payloads[identifier] = .playlist(playlist)
        }

        return PreparedSnapshot(records: records, payloadsByIdentifier: payloads)
    }

    private nonisolated static func makeSearchableItem(
        payload: IndexPayload,
        thumbnailDirectoryURL: URL
    ) -> (searchableItem: CSSearchableItem, thumbnailCacheMiss: Bool) {
        switch payload {
        case let .song(song, artistDisplayName, coverContentIdentifier):
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = song.title
            attrs.album = song.albumTitle
            attrs.artist = artistDisplayName
            attrs.contentDescription = [artistDisplayName, song.albumTitle]
                .compactMap { $0 }
                .joined(separator: " — ")
            attrs.keywords = [song.title, artistDisplayName, song.albumTitle].compactMap { $0 }
            var thumbnailCacheMiss = false
            #if os(iOS)
            if let coverRef = song.coverArtFileName,
               let coverContentIdentifier {
                let thumbnail = cachedThumbnailURL(
                    coverArtFileName: coverRef,
                    coverContentIdentifier: coverContentIdentifier,
                    directoryURL: thumbnailDirectoryURL
                )
                attrs.thumbnailURL = thumbnail.url
                thumbnailCacheMiss = thumbnail.cacheMiss
            }
            #endif
            return (
                CSSearchableItem(
                    uniqueIdentifier: "song:\(song.id)",
                    domainIdentifier: kSongDomain,
                    attributeSet: attrs
                ),
                thumbnailCacheMiss
            )

        case let .album(album):
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = album.title
            attrs.album = album.title
            attrs.artist = album.artistName
            attrs.contentDescription = album.artistName ?? ""
            attrs.keywords = [album.title, album.artistName].compactMap { $0 }
            return (
                CSSearchableItem(
                    uniqueIdentifier: "album:\(album.id)",
                    domainIdentifier: kAlbumDomain,
                    attributeSet: attrs
                ),
                false
            )

        case let .artist(artist):
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = artist.name
            attrs.artist = artist.name
            attrs.contentDescription = String(localized: "spotlight_artist_subtitle")
            attrs.keywords = [artist.name]
            return (
                CSSearchableItem(
                    uniqueIdentifier: "artist:\(artist.id)",
                    domainIdentifier: kArtistDomain,
                    attributeSet: attrs
                ),
                false
            )

        case let .playlist(playlist):
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = playlist.name
            attrs.contentDescription = String(
                format: String(localized: "spotlight_playlist_subtitle_format"),
                playlist.songCount
            )
            attrs.keywords = [playlist.name]
            return (
                CSSearchableItem(
                    uniqueIdentifier: "playlist:\(playlist.id)",
                    domainIdentifier: kPlaylistDomain,
                    attributeSet: attrs
                ),
                false
            )
        }
    }

    #if os(iOS)
    /// Reuses a persistent 128 px JPEG keyed by the source artwork's content
    /// identity. Full recovery builds decode at most eight new covers per batch;
    /// later launches and metadata-only updates perform no image work.
    private nonisolated static func cachedThumbnailURL(
        coverArtFileName: String,
        coverContentIdentifier: String,
        directoryURL: URL
    ) -> (url: URL?, cacheMiss: Bool) {
        let cacheKey = SHA256.hash(data: Data(coverContentIdentifier.utf8))
            .prefix(20)
            .map { String(format: "%02x", $0) }
            .joined()
        let url = directoryURL.appendingPathComponent("\(cacheKey).jpg")
        if FileManager.default.fileExists(atPath: url.path) {
            return (url, false)
        }
        guard let raw = MetadataAssetStore.shared.readCoverData(named: coverArtFileName),
              !ArtworkImageCompatibility.hasRedundantJPEGSampling(raw) else {
            return (nil, true)
        }

        let encoded: Data? = autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(raw as CFData, sourceOptions) else {
                return nil
            }
            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
            ] as CFDictionary
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions
            ) else {
                return nil
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(destination, thumbnail, [
                kCGImageDestinationLossyCompressionQuality: 0.7,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
        guard let encoded else { return (nil, true) }
        do {
            try encoded.write(to: url, options: .atomic)
            return (url, true)
        } catch {
            spotlightLog.error("Spotlight thumbnail cache write failed: \(error.localizedDescription)")
            return (nil, true)
        }
    }
    #endif

    private nonisolated static func applyBatch(
        to index: CSSearchableIndex,
        deletingIdentifiers: [String],
        searchableItems: [CSSearchableItem],
        clientState: Data
    ) async throws {
        enqueueBatchMutations(
            to: index,
            deletingIdentifiers: deletingIdentifiers,
            searchableItems: searchableItems
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            index.endBatch(withClientState: clientState) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// The completion-handler variants are intentional inside a Core Spotlight
    /// batch: mutations are enqueued synchronously, and the single awaited
    /// commit point is `endBatch` below.
    private nonisolated static func enqueueBatchMutations(
        to index: CSSearchableIndex,
        deletingIdentifiers: [String],
        searchableItems: [CSSearchableItem]
    ) {
        index.beginBatch()
        if !deletingIdentifiers.isEmpty {
            index.deleteSearchableItems(
                withIdentifiers: deletingIdentifiers,
                completionHandler: nil
            )
        }
        if !searchableItems.isEmpty {
            index.indexSearchableItems(searchableItems, completionHandler: nil)
        }
    }

    private nonisolated static func deleteDomains(
        _ domains: [String],
        from index: CSSearchableIndex
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domains) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private nonisolated static func fetchClientState(
        from index: CSSearchableIndex
    ) async -> ClientStateResult {
        await withCheckedContinuation { continuation in
            index.fetchLastClientState { data, error in
                continuation.resume(returning: ClientStateResult(data: data, error: error))
            }
        }
    }

    private nonisolated static func pauseBetweenBatches() async -> Bool {
        do {
            try await Task.sleep(for: interBatchDelay)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private nonisolated static var canPerformIndexing: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            return false
        case .nominal, .fair:
            break
        @unknown default:
            return false
        }
        #if os(iOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return false
        }
        #endif
        return true
    }

    private nonisolated static func contentSignature(_ fields: [String?]) -> String {
        var encoded = Data()
        for field in fields {
            guard let field else {
                encoded.append(0)
                continue
            }
            encoded.append(1)
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
            encoded.append(bytes)
        }
        return SHA256.hash(data: encoded)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func clientState(
        for manifest: SpotlightIndexManifest
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("schema:\(manifest.schemaVersion)\n".utf8))
        for identifier in manifest.signaturesByIdentifier.keys.sorted() {
            hasher.update(data: Data(identifier.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data((manifest.signaturesByIdentifier[identifier] ?? "").utf8))
            hasher.update(data: Data([0x0A]))
        }
        let digest = hasher.finalize()
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return Data("v\(manifest.schemaVersion):\(digest)".utf8)
    }

    private nonisolated static func loadManifest(from url: URL) -> SpotlightIndexManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpotlightIndexManifest.self, from: data)
    }

    private nonisolated static func saveManifest(
        _ manifest: SpotlightIndexManifest,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }
}

enum SpotlightItem: Sendable {
    case song(id: String)
    case album(id: String)
    case artist(id: String)
    case playlist(id: String)
}
