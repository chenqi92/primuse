import CryptoKit
import Foundation
import PrimuseKit

/// Fills in metadata for songs that were added by ConnectorScanner in
/// "bare-song" mode (cloud sources only download a few hundred KB during
/// scan). This runs continuously in the background, fetching just the file
/// header via HTTP Range, extracting tags, and replacing the song in the
/// library with a fully-populated copy.
///
/// Lifecycle:
/// - App launch / foreground / BGProcessingTask wake → `start(...)` kicks off
///   a worker if there's anything pending.
/// - Worker drains the queue one song at a time. Each cloud-source connector
///   is an actor with its own throttle, so multiple workers per source don't
///   actually parallelize; one worker per source plus shared throttle is the
///   sweet spot.
/// - Failed songs (corrupt / missing / decoder rejected) are recorded so we
///   don't retry them every launch. Successful ones are replaced in the
///   library and persist via `MusicLibrary.persistSnapshot()`.
@MainActor
@Observable
final class MetadataBackfillService {
    /// Bytes to fetch from the start of an audio file. Big enough to cover
    /// embedded artwork + ID3v2 + FLAC Vorbis comments + most M4A `moov`
    /// headers. If a particular file's metadata isn't in this slice we may
    /// need to retry with a tail-Range fetch (M4A with trailing moov).
    private static let headBytes: Int64 = 256 * 1024

    /// Tail-Range fetch size for M4A files where moov is at the end.
    private static let tailBytes: Int64 = 256 * 1024

    /// Persisted set of song IDs that previously failed metadata extraction.
    /// Skipped on subsequent runs so we don't burn API quota retrying them
    /// every app launch.
    private var failedSongIDs: Set<String> = []

    /// UserDefaults key for "only run backfill on Wi-Fi". Default true.
    /// User-facing toggle lives in CloudSyncSettingsView.
    static let wifiOnlyDefaultsKey = "primuse.cloudScanWifiOnly"

    private let library: MusicLibrary
    private let sourceManager: SourceManager
    private let metadataService = MetadataService()
    private let failedURL: URL

    /// Songs currently being processed (for UI / cancellation).
    private(set) var pendingCount: Int = 0
    private(set) var processedCount: Int = 0
    private(set) var isRunning: Bool = false

    private var worker: Task<Void, Never>?
    /// Bumped on every `start()` / `stop()`. The worker captures its own
    /// generation and uses it to decide whether the cleanup at end-of-Task
    /// should clear shared state — without this, a cancelled-but-still-
    /// finishing worker can wipe `worker`/`isRunning` set by a new `start()`
    /// that ran between cancel and Task.value resumption.
    private var workerGeneration: Int = 0

    init(library: MusicLibrary, sourceManager: SourceManager) {
        self.library = library
        self.sourceManager = sourceManager
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.failedURL = directory.appendingPathComponent("backfill-failed.json")
        loadFailed()
    }

    /// Start (or resume) backfill. Idempotent — if a worker is already
    /// running this is a no-op. Safe to call on every app foreground / BG
    /// task wake.
    ///
    /// Skips on cellular when "Wi-Fi only" is enabled (default). Returns
    /// early without scheduling work; caller can re-invoke later when the
    /// path changes (we observe NetworkMonitor for that).
    func start() {
        guard worker == nil else { return }

        // Cellular gate. Backfill on a 2200-song cloud library is ~550MB —
        // enough to be a problem on metered connections.
        let wifiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyDefaultsKey) as? Bool ?? true
        if wifiOnly && !NetworkMonitor.shared.isOnUnmeteredNetwork {
            plog("📥 Backfill: deferred (cellular + Wi-Fi-only setting on)")
            return
        }

        let needsBackfill = pickNextBatch()
        guard !needsBackfill.isEmpty else { return }
        pendingCount = needsBackfill.count
        processedCount = 0
        isRunning = true
        workerGeneration += 1
        let generation = workerGeneration
        // Diagnostic: prove that we only pick still-bare songs. If you see
        // this number stay >0 forever you can compare against
        // `library.songs.count` to confirm no infinite reprocessing.
        plog("📥 Backfill: gen=\(generation) bareInLib=\(remainingCount) batchHead=\(needsBackfill.count)")
        worker = Task { [weak self] in
            await self?.runWorker()
            await MainActor.run { [weak self] in
                guard let self, self.workerGeneration == generation else { return }
                self.worker = nil
                self.isRunning = false
                self.pendingCount = 0
            }
        }
    }

    /// Stop the worker after the in-flight song finishes. Safe to call on
    /// background-task expiration; nothing is left in a half-state because
    /// `replaceSong` is atomic. Bumping the generation here is what tells
    /// the in-flight worker's MainActor cleanup block to skip — it's no
    /// longer the "current" worker, so it must not touch shared state.
    func stop() {
        workerGeneration += 1
        worker?.cancel()
        worker = nil
        isRunning = false
    }

    /// Re-evaluate the queue every time the library changes (e.g. a fresh
    /// scan added new bare songs). Call after scan completion or song add.
    func refreshQueue() {
        if worker == nil { start() }
    }

    /// Block until the worker finishes draining the current queue. Used by
    /// the BGProcessingTask handler so iOS doesn't yank us mid-work.
    func waitUntilIdle() async {
        while worker != nil {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// True if a Song is considered "bare" — i.e. nothing was ever
    /// successfully extracted from it. Mirrors the filter used by
    /// `pickNextBatch`/`remainingCount`.
    ///
    /// **Important**: checks every metadata field, not just duration +
    /// bitRate. The 256KB head fetch often parses ID3v2 tags (artist,
    /// album) cleanly even when it can't compute duration (needs more
    /// frames) or bitRate (needs full file). If we only checked duration
    /// + bitRate, those partially-resolved songs stayed "bare" forever
    /// and got re-picked on every worker iteration — burning network
    /// quota in an infinite loop without any progress.
    static func isBareSong(_ song: Song) -> Bool {
        song.duration == 0
            && song.bitRate == nil
            && song.artistID == nil
            && song.albumID == nil
            && song.year == nil
            && song.genre == nil
    }

    /// True if there are bare songs in the library that backfill could
    /// process. Reflects queue state, not just whether a worker is
    /// currently running — a cellular-paused service shows
    /// `isRunning == false` but still has pending work that should keep
    /// BGProcessingTask scheduled.
    var hasPendingWork: Bool {
        library.songs.contains { song in
            !failedSongIDs.contains(song.id) && Self.isBareSong(song)
        }
    }

    /// Number of songs currently waiting for backfill. Used by the UI to
    /// show "loading details · N remaining" — the older `pendingCount`
    /// was a snapshot at start time so it could disagree with reality
    /// after Phase A added more bare songs mid-backfill.
    var remainingCount: Int {
        remainingCount(forSource: nil)
    }

    /// Per-source variant — used by the source card so its "remaining"
    /// number matches the global storage page rather than counting
    /// songs that backfill has given up on.
    func remainingCount(forSource sourceID: String?) -> Int {
        library.songs.lazy.filter { song in
            !self.failedSongIDs.contains(song.id) &&
                Self.isBareSong(song) &&
                (sourceID == nil || song.sourceID == sourceID)
        }.count
    }

    // MARK: - Worker

    /// Songs to flush to the library at once. Smaller = UI updates feel
    /// more incremental; larger = fewer SwiftUI invalidations and fewer
    /// `rebuildIndex`/`persistSnapshot` runs. 10 strikes a good balance.
    private static let flushBatchSize = 10
    /// Even with a partial batch, flush at least every N seconds so the
    /// user sees progress without having to wait for 10 songs.
    private static let flushInterval: TimeInterval = 3

    private func runWorker() async {
        // Outer loop: take a snapshot of bare songs, process the snapshot
        // sequentially, flush in batches. We deliberately do NOT call
        // `pickNextBatch` per-song — until we flush the batch the
        // already-processed songs still look "bare" in the library and
        // would be picked again, causing duplicate Range fetches and a
        // weird-looking processedCount that grows past pendingCount.
        while !Task.isCancelled {
            let blockedByCellular = await MainActor.run { [self] in shouldBlockForCellular() }
            if blockedByCellular {
                plog("📥 Backfill: pausing (cellular detected mid-flight)")
                break
            }

            let snapshot = await MainActor.run { [self] in pickNextBatch() }
            if snapshot.isEmpty { break }

            await processSnapshot(snapshot)
        }
    }

    /// Process a fixed list of songs sequentially, flushing the library
    /// every `flushBatchSize` successes (or every `flushInterval` seconds).
    /// Each song in the snapshot is touched exactly once.
    private func processSnapshot(_ snapshot: [Song]) async {
        var pendingFlush: [Song] = []
        var lastFlushAt = Date()

        let flush: (_ force: Bool) async -> Void = { [weak self] force in
            guard let self else { return }
            let shouldFlush = force
                || pendingFlush.count >= Self.flushBatchSize
                || Date().timeIntervalSince(lastFlushAt) >= Self.flushInterval
            guard shouldFlush, !pendingFlush.isEmpty else { return }
            let batch = pendingFlush
            pendingFlush.removeAll(keepingCapacity: true)
            lastFlushAt = Date()
            await MainActor.run { [weak self] in
                self?.library.replaceSongs(batch)
            }
        }

        for song in snapshot {
            if Task.isCancelled { break }

            // Cellular check between songs — flush what we have and bail
            // so the user's data isn't burned past their setting.
            let blockedByCellular = await MainActor.run { [self] in shouldBlockForCellular() }
            if blockedByCellular {
                await flush(true)
                return
            }

            let result = await processOne(song)
            await MainActor.run { [weak self] in
                guard let self else { return }
                processedCount += 1
                if result == nil {
                    failedSongIDs.insert(song.id)
                    saveFailed()
                }
            }
            if let updated = result {
                pendingFlush.append(updated)
            }
            await flush(false)
        }

        await flush(true)
    }

    private func shouldBlockForCellular() -> Bool {
        let wifiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyDefaultsKey) as? Bool ?? true
        return wifiOnly && !NetworkMonitor.shared.isOnUnmeteredNetwork
    }

    /// Returns the merged Song on success, nil on failure. Caller is
    /// responsible for batching the result into the library — this
    /// method no longer touches `library.replaceSong` directly so we can
    /// flush many songs at once.
    private func processOne(_ song: Song) async -> Song? {
        let started = Date()
        do {
            // Use the SHARED connector (not auxiliary). Backfill is sequential
            // and benefits massively from accumulated state on the single
            // BaiduPanSource actor: throttle clock, dlink cache, dir-listing
            // cache. Auxiliary instances reset all of that per song, which is
            // what made backfill 10× slower than it needed to be — every song
            // re-paid the list+filemetas dlink cost AND was prone to 31034
            // rate-limit storms because the throttle state didn't carry over.
            let connector = try await sourceManager.connectorForSong(song)

            let fetchStarted = Date()
            let headData = try await connector.fetchRange(
                path: song.filePath,
                offset: 0,
                length: Self.headBytes
            )
            let fetchElapsed = Date().timeIntervalSince(fetchStarted)

            var metadata = await extractMetadata(
                from: headData,
                song: song,
                cacheKey: song.id
            )
            if metadataLooksMissing(metadata) {
                if let tailData = try? await connector.fetchRange(
                    path: song.filePath,
                    offset: -Self.tailBytes,
                    length: Self.tailBytes
                ) {
                    let combined = headData + tailData
                    metadata = await extractMetadata(from: combined, song: song, cacheKey: song.id)
                }
            }

            // Even with both head and tail in hand, some files have no
            // parseable tags at all (untagged WAV, broken FLACs, weird
            // encoders). Without this guard, mergeSong writes a Song that
            // STILL satisfies `bare` (duration=0, bitRate=nil), so the
            // next worker iteration / next launch keeps re-fetching it
            // forever. Mark these as failed so they're skipped on retry.
            if metadataLooksMissing(metadata) {
                plog("⚠️ Backfill: '\(song.title)' has no parseable metadata after head+tail; marking failed")
                return nil
            }

            let totalElapsed = Date().timeIntervalSince(started)
            plog(String(format: "📥 Backfill: '%@' done in %.2fs (fetch %.2fs)", song.title, totalElapsed, fetchElapsed))
            return mergeSong(bare: song, metadata: metadata)
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            plog(String(format: "⚠️ Backfill failed for '%@' after %.2fs: %@", song.title, elapsed, error.localizedDescription))
            return nil
        }
    }

    /// Write the partial bytes to a temp file and run the standard metadata
    /// reader against it. SFBAudio's parser is happy with truncated files
    /// for most formats (mp3/flac); m4a needs the moov atom which may be
    /// at the tail (handled by the caller).
    private func extractMetadata(
        from data: Data,
        song: Song,
        cacheKey: String
    ) async -> MetadataService.SongMetadata {
        let ext = (song.filePath as NSString).pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-\(cacheKey).\(ext)")
        try? data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return await metadataService.loadMetadata(
            for: tempURL,
            cacheKey: cacheKey,
            allowOnlineFetch: false
        )
    }

    private func metadataLooksMissing(_ m: MetadataService.SongMetadata) -> Bool {
        // No artist + no album + no duration ⇒ extraction probably failed.
        m.artist == nil && m.albumTitle == nil && m.duration <= 0
    }

    private func mergeSong(bare: Song, metadata: MetadataService.SongMetadata) -> Song {
        let artistID = metadata.artist.map { Self.hash($0.lowercased()) }
        let albumID: String? = if let artist = metadata.artist, let album = metadata.albumTitle {
            Self.hash("\(artist.lowercased()):\(album.lowercased())")
        } else {
            nil
        }

        // Sidecar references on the bare song (from listFiles sibling
        // detection) win over anything embedded in the file — they're
        // higher quality (full-size cover) and remote-resolvable.
        let coverRef = bare.coverArtFileName ?? metadata.coverArtFileName
        let lyricsRef = bare.lyricsFileName ?? metadata.lyricsFileName

        return Song(
            id: bare.id,
            title: bare.title,
            albumID: albumID,
            artistID: artistID,
            albumTitle: metadata.albumTitle,
            artistName: metadata.artist,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            duration: metadata.duration,
            fileFormat: bare.fileFormat,
            filePath: bare.filePath,
            sourceID: bare.sourceID,
            fileSize: bare.fileSize,
            bitRate: metadata.bitRate,
            sampleRate: metadata.sampleRate,
            bitDepth: metadata.bitDepth,
            genre: metadata.genre,
            year: metadata.year,
            lastModified: bare.lastModified,
            dateAdded: bare.dateAdded,
            coverArtFileName: coverRef,
            lyricsFileName: lyricsRef
        )
    }

    // MARK: - Queue selection

    /// A song needs backfill if it has none of the metadata that file-header
    /// extraction would produce (duration, bitRate). Songs in the failure
    /// set are skipped. Limited to a batch so the queue doesn't grow
    /// unbounded for huge libraries.
    private func pickNextBatch() -> [Song] {
        let candidates = library.songs.lazy.filter { song in
            guard !self.failedSongIDs.contains(song.id) else { return false }
            return Self.isBareSong(song)
        }
        return Array(candidates.prefix(500))
    }

    // MARK: - Failed-set persistence

    private func loadFailed() {
        guard let data = try? Data(contentsOf: failedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        failedSongIDs = Set(decoded)
    }

    private func saveFailed() {
        guard let data = try? JSONEncoder().encode(Array(failedSongIDs)) else { return }
        try? data.write(to: failedURL, options: .atomic)
    }

    private static func hash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
