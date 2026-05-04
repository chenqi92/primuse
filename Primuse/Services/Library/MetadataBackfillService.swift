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

        // One-time migration. Earlier builds had an overly-aggressive
        // partial-merge rule that marked any song as failed when head
        // 256KB didn't yield a duration — even if a tail-fetch would
        // have recovered it (M4A with udta in head, moov at tail are
        // the common victim). Field reports surfaced ~500 stuck songs
        // per library. Wipe the persisted set so those songs get a
        // fresh attempt under the corrected logic. Versioned key
        // prevents repeating on every launch.
        let migrationKey = "primuse.backfillFailedReset.v2026_05_partialMerge"
        if !UserDefaults.standard.bool(forKey: migrationKey), !failedSongIDs.isEmpty {
            plog("📥 Backfill: wiping \(failedSongIDs.count) failedSongIDs (one-time migration after tail-fetch fix)")
            failedSongIDs.removeAll()
            saveFailed()
        }
        UserDefaults.standard.set(true, forKey: migrationKey)

        // Second one-time migration. The previous backfill stamped
        // many songs with SFB's truncated-head duration estimate
        // (typically 6–12 s for raw MP3s without XING/LAME, since
        // SFB only saw the first 256 KB). Sweep the library for
        // songs whose stored duration is < half what (fileSize ×
        // 8 / bitRate) predicts, reset their duration to 0, and
        // clear any matching failed mark so they re-enter the
        // queue. The corrected `correctedDuration` helper now
        // overwrites bogus parser values on the next pass.
        let durationFixKey = "primuse.backfillFailedReset.v2026_05_truncatedDuration"
        if !UserDefaults.standard.bool(forKey: durationFixKey) {
            var resetSongs: [Song] = []
            for song in library.songs {
                guard let bitRate = song.bitRate, bitRate > 0,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0 else { continue }
                let bytesPerSec = Double(bitRate) * 125.0
                let estimatedFromFileSize = Double(song.fileSize) / bytesPerSec
                if song.duration < estimatedFromFileSize * 0.5 {
                    var copy = song
                    copy.duration = 0
                    resetSongs.append(copy)
                    failedSongIDs.remove(song.id)
                }
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) songs with truncated-head duration to re-trigger backfill")
                library.replaceSongs(resetSongs)
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: durationFixKey)
        }

        // Third one-time migration. Some older backfill results stored
        // `bitRate = 0` alongside the truncated-head MP3 duration, so
        // the previous sweep (which required a parsed bitrate) missed
        // exactly the field-reported shape: 3-5 MB MP3s saved as
        // 10-15 second tracks. Use the same conservative 192kbps
        // fallback as `correctedDuration` and reset only when the saved
        // duration is less than half the file-size estimate.
        let durationFallbackFixKey = "primuse.backfillFailedReset.v2026_05_truncatedDurationFallbackBitrate"
        if !UserDefaults.standard.bool(forKey: durationFallbackFixKey) {
            var resetSongs: [Song] = []
            for song in library.songs {
                guard song.fileFormat == .mp3,
                      (song.bitRate ?? 0) <= 0,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0 else { continue }
                let bytesPerSec = Double(Self.defaultMP3Bitrate) * 125.0
                let estimatedFromFileSize = Double(song.fileSize) / bytesPerSec
                if song.duration < estimatedFromFileSize * 0.5 {
                    var copy = song
                    copy.duration = 0
                    resetSongs.append(copy)
                    failedSongIDs.remove(song.id)
                }
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) MP3 songs with truncated duration + missing bitrate")
                library.replaceSongs(resetSongs)
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: durationFallbackFixKey)
        }

        // Fourth one-time migration. Playback used to let SFB rewrite
        // cloud-stream duration from partial Range reads, so a healthy
        // 2-4 minute MP3 could regress back to ~8 seconds after the
        // previous migrations had already run. Reset every implausibly
        // short MP3 again, using parsed bitrate when available and the
        // conservative 192kbps fallback otherwise.
        let streamRewriteFixKey = "primuse.backfillFailedReset.v2026_05_streamDurationRewrite"
        if !UserDefaults.standard.bool(forKey: streamRewriteFixKey) {
            var resetSongs: [Song] = []
            for song in library.songs {
                guard song.fileFormat == .mp3,
                      song.fileSize > Self.headBytes * 2,
                      song.duration > 0 else { continue }
                let effectiveBitRate = (song.bitRate ?? 0) > 0 ? song.bitRate! : Self.defaultMP3Bitrate
                let estimatedFromFileSize = Double(song.fileSize) / (Double(effectiveBitRate) * 125.0)
                if estimatedFromFileSize > 30, song.duration < estimatedFromFileSize * 0.5 {
                    var copy = song
                    copy.duration = 0
                    resetSongs.append(copy)
                    failedSongIDs.remove(song.id)
                }
            }
            if !resetSongs.isEmpty {
                plog("📥 Backfill: resetting \(resetSongs.count) MP3 songs after partial stream duration rewrite")
                library.replaceSongs(resetSongs)
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: streamRewriteFixKey)
        }

        // A re-scan that found a path with new bytes wipes the failed
        // mark so backfill re-attempts the song with the fresh file. The
        // song's metadata in the library is already reset to bare by
        // `MusicLibrary.addSongs`, so `start()` will pick it up next pass.
        NotificationCenter.default.addObserver(
            forName: .primuseSongContentChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let songs = (note.userInfo?["songs"] as? [Song]) ?? []
            guard !songs.isEmpty else { return }
            MainActor.assumeIsolated {
                let ids = Set(songs.map(\.id))
                self.failedSongIDs.subtract(ids)
                self.saveFailed()
                self.start()
            }
        }
    }

    /// Start (or resume) backfill. Idempotent — if a worker is already
    /// running this is a no-op. Safe to call on every app foreground / BG
    /// task wake.
    ///
    /// Skips on cellular when "Wi-Fi only" is enabled (default). Returns
    /// early without scheduling work; caller can re-invoke later when the
    /// path changes (we observe NetworkMonitor for that).
    func start() {
        guard worker == nil else {
            // Worker still in flight — common during initial scan when
            // multiple onChange events fire. Logging was added because
            // a "spinner never stops" report initially looked like
            // start() wasn't being called at all.
            plog("📥 Backfill: skip (worker already running, gen=\(workerGeneration))")
            return
        }

        // Cellular gate. Backfill on a 2200-song cloud library is ~550MB —
        // enough to be a problem on metered connections.
        let wifiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyDefaultsKey) as? Bool ?? true
        if wifiOnly && !NetworkMonitor.shared.isOnUnmeteredNetwork {
            plog("📥 Backfill: deferred (cellular + Wi-Fi-only setting on)")
            return
        }

        let needsBackfill = pickNextBatch()
        guard !needsBackfill.isEmpty else {
            // Either every song has metadata OR every bare song is in
            // failedSongIDs. Surface both numbers so a "spinner stuck"
            // report can be triaged from the log without app-side
            // instrumentation.
            let bareTotal = library.songs.lazy.filter { Self.isBareSong($0) }.count
            plog("📥 Backfill: skip (no eligible bare songs — total=\(library.songs.count) bare=\(bareTotal) failed=\(failedSongIDs.count))")
            return
        }
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

    /// True if a Song still needs backfill. We key on `duration` alone
    /// because:
    /// - it's the load-bearing field (drives progress bar, gates the
    ///   playable-queue filter, prevents SFB from misjudging stream
    ///   length);
    /// - other fields (artist/album/genre/year) can be filled by the
    ///   online scraper without backfill ever running, leaving songs
    ///   in a "looks fine but no duration" state. The OLD predicate
    ///   required all six fields to be empty — so any scrape result
    ///   silently disqualified the song from backfill, the row spinner
    ///   never stopped, and the queue filter kept it un-playable.
    ///
    /// Infinite-loop protection: `metadataLooksMissing` after head+tail
    /// → `markFailed` → `failedSongIDs.contains` short-circuits the
    /// next pick. So a file genuinely without duration is tried once
    /// and then skipped forever — no retry storm.
    static func isBareSong(_ song: Song) -> Bool {
        song.duration <= 0
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

    /// True if backfill has given up on this song (extraction failed, or
    /// the file is parseable but exposes no duration). Used by SongRowView
    /// to swap the "loading details" spinner for a static "details
    /// unavailable" hint so the user isn't stuck staring at a forever-
    /// loading row.
    func didFail(songID: String) -> Bool {
        failedSongIDs.contains(songID)
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
        var lastSnapshotIDs: Set<String> = []
        while !Task.isCancelled {
            let blockedByCellular = await MainActor.run { [self] in shouldBlockForCellular() }
            if blockedByCellular {
                plog("📥 Backfill: pausing (cellular detected mid-flight)")
                break
            }

            let snapshot = await MainActor.run { [self] in pickNextBatch() }
            if snapshot.isEmpty { break }

            // Oscillation guard: if pickNextBatch keeps returning the
            // exact same set of song IDs after we already processed
            // them, our writes aren't sticking — replaceSongs failed,
            // backfill returned duration=0 despite reporting "done", or
            // some other code path is silently overwriting the merged
            // result back to bare. Bail to avoid burning quota in an
            // infinite loop, and surface the diagnostic so we can
            // pinpoint where the round-trip drops the duration.
            let snapIDs = Set(snapshot.map(\.id))
            if !lastSnapshotIDs.isEmpty, snapIDs == lastSnapshotIDs {
                plog("⚠️ Backfill: pickNextBatch returned the same \(snapIDs.count) IDs after a full round — aborting (writes aren't sticking; check 'duration=' in prior done lines)")
                break
            }
            lastSnapshotIDs = snapIDs

            await processSnapshot(snapshot)
        }
    }

    /// Process a fixed list of songs sequentially, flushing the library
    /// every `flushBatchSize` successes (or every `flushInterval` seconds).
    /// Each song in the snapshot is touched exactly once.
    private func processSnapshot(_ snapshot: [Song]) async {
        var pendingFlush: [Song] = []
        var lastFlushAt = Date()
        plog("📥 processSnapshot: starting with \(snapshot.count) songs")

        for song in snapshot {
            if Task.isCancelled { break }

            // Cellular check between songs — flush what we have and bail
            // so the user's data isn't burned past their setting.
            if shouldBlockForCellular() {
                if !pendingFlush.isEmpty {
                    library.replaceSongs(pendingFlush)
                    pendingFlush.removeAll(keepingCapacity: true)
                }
                return
            }

            let outcome = await processOne(song)
            processedCount += 1
            if outcome.markFailed {
                failedSongIDs.insert(song.id)
                saveFailed()
            }
            if let updated = outcome.song {
                pendingFlush.append(updated)
            }

            // Flush when the batch is full OR the interval has elapsed.
            // Inlined (was a closure that Swift 6's actor-isolation
            // closure handling silently no-op'd — `await flush(...)`
            // returned without ever entering the body, so songs were
            // appended forever and `library.replaceSongs` was never
            // called. Direct call avoids the trap.
            let shouldFlush = pendingFlush.count >= Self.flushBatchSize
                || Date().timeIntervalSince(lastFlushAt) >= Self.flushInterval
            if shouldFlush, !pendingFlush.isEmpty {
                let batch = pendingFlush
                pendingFlush.removeAll(keepingCapacity: true)
                lastFlushAt = Date()
                library.replaceSongs(batch)
                plog("📥 flushed \(batch.count) songs to library")
            }
        }

        // Final flush
        if !pendingFlush.isEmpty {
            let batch = pendingFlush
            pendingFlush.removeAll()
            library.replaceSongs(batch)
            plog("📥 final flush: \(batch.count) songs to library")
        }
    }

    private func shouldBlockForCellular() -> Bool {
        let wifiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyDefaultsKey) as? Bool ?? true
        return wifiOnly && !NetworkMonitor.shared.isOnUnmeteredNetwork
    }

    /// Outcome of one backfill attempt. `song` is the merged result to
    /// flush into the library when present (preserves whatever fields we
    /// did parse, e.g. artist+album when duration was unreadable).
    /// `markFailed` tells the caller to add the original ID to
    /// `failedSongIDs` so backfill stops retrying — set even on partial
    /// merges so a duration-less file isn't picked up next pass.
    struct BackfillOutcome {
        var song: Song?
        var markFailed: Bool
    }

    /// Run one backfill against `song`. Returns a merged Song to flush
    /// (may be nil if extraction yielded nothing usable) and a flag
    /// indicating whether the attempt should be remembered as failed —
    /// the two are independent because some files parse partial tags
    /// (artist, album) but never expose duration.
    private func processOne(_ song: Song) async -> BackfillOutcome {
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

            // Reuse the head bytes we just paid for to prewarm the cloud
            // playback cache. CloudPlaybackSource will pick up `.partial`
            // on the first SFB read, so the user's first-buffer latency for
            // this song drops from "1 chunk + CDN HEAD" to "disk hit".
            // Only worthwhile for cloud-stream sources — local/file paths
            // never go through CloudPlaybackSource.
            if song.fileSize >= Int64(Self.headBytes),
               await sourceManager.songSupportsRangeStreaming(song) {
                sourceManager.seedPrewarmCache(song: song, head: headData)
            }

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

            // Nothing parseable at all → no merge, mark failed so we
            // don't burn quota retrying.
            if metadataLooksMissing(metadata) {
                plog("⚠️ Backfill: '\(song.title)' has no parseable metadata after head+tail; marking failed")
                return BackfillOutcome(song: nil, markFailed: true)
            }

            // After tightening `metadataLooksMissing` to require
            // duration > 0, reaching this point means head+tail
            // produced a usable duration. The old "merged.duration<=0
            // → markFailed" guard was firing on songs that just hadn't
            // had tail tried yet — removed.
            // Only reverse-compute for raw MP3. M4A/MP4/M4B carry
            // authoritative duration inside `moov.mvhd`; backfill's
            // tail-fetch already gets it correctly. Applying the
            // bytes-÷-bitrate heuristic to those formats wrongly
            // overwrites the correct value because m4a containers
            // often wrap data far larger than `bitRate × duration / 8`
            // (multiple tracks, padding, sidecar metadata) — observed
            // in the field as a 13MB / 198kbps m4a being "corrected"
            // from the real 177s to a bogus 562s.
            let ext = (song.filePath as NSString).pathExtension.lowercased()
            if ext == "mp3" {
                metadata.duration = correctedDuration(parsed: metadata.duration, bitRateKbps: metadata.bitRate, fileSize: song.fileSize, title: song.title)
            }
            let merged = mergeSong(bare: song, metadata: metadata)
            let totalElapsed = Date().timeIntervalSince(started)
            // Include the parsed duration in the log line so an
            // infinite-loop case (pickNextBatch repeatedly handing back
            // the same songs) can be diagnosed without re-instrumenting:
            // duration=0 in the log means mergeSong didn't actually
            // capture a usable duration despite metadataLooksMissing
            // returning false → bug in the parser or the gate.
            plog(String(format: "📥 Backfill: '%@' done in %.2fs (fetch %.2fs) duration=%.1fs", song.title, totalElapsed, fetchElapsed, merged.duration))
            return BackfillOutcome(song: merged, markFailed: false)
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            plog(String(format: "⚠️ Backfill failed for '%@' after %.2fs: %@", song.title, elapsed, error.localizedDescription))
            return BackfillOutcome(song: nil, markFailed: true)
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
        // tempURL 是 backfill-<hash>.<ext> 形式, 没意义。caller 传 song 原始
        // 文件名当 fallbackTitle, 嵌入 title 缺失时显示得正常。
        let originalFileBaseName = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return await metadataService.loadMetadata(
            for: tempURL,
            cacheKey: cacheKey,
            allowOnlineFetch: false,
            fallbackTitle: originalFileBaseName
        )
    }

    /// Reverse-compute duration from `(fileSize × 8) / bitRate` when
    /// SFB's parsed value is implausibly short. Backfill feeds the
    /// parser only the first 256 KB of the audio file, so for raw MP3s
    /// without an XING/LAME header the parser estimates duration as
    /// `truncated_file_size / bitrate` and reports 6–12 seconds for
    /// what's really a 2–4 minute song. The real `song.fileSize`
    /// (from the source listing) plus the parsed `bitRate` give us
    /// the actual duration directly. Only kicks in when:
    /// - we have a usable bitrate (parser tells us this from frame
    ///   header — present in head bytes for any sane MP3)
    /// - the file is materially larger than the head we sent (otherwise
    ///   the parser saw the whole thing and its number is trustworthy)
    /// - the parser's value is < half the bytes-based estimate (the
    ///   unambiguous "truncated input" signal — avoids stomping on a
    ///   correctly-parsed XING/LAME duration that genuinely matches)
    /// Default MP3 bitrate when SFB couldn't extract one from the
    /// truncated 256KB head. 192kbps is the population median across
    /// modern MP3 libraries (audiobooks lean lower, high-quality music
    /// lean 256/320). Estimate accuracy: ±25% of true duration —
    /// good enough to show a recognizable time on the row instead of
    /// "0:08", and the player rewrites it to the real value after
    /// the user plays the song once.
    private static let defaultMP3Bitrate = 192

    private func correctedDuration(parsed: TimeInterval, bitRateKbps: Int?, fileSize: Int64, title: String) -> TimeInterval {
        guard fileSize > Self.headBytes * 2 else { return parsed }
        // Use parsed bitRate when available, otherwise fall back to
        // population median. SFB often returns 0 for raw MP3 without
        // XING/LAME (it estimates frames from the truncated head and
        // gives up), which is exactly when we need this most.
        let effectiveBitRate = (bitRateKbps ?? 0) > 0 ? bitRateKbps! : Self.defaultMP3Bitrate
        let bytesPerSecond = Double(effectiveBitRate) * 125.0
        let estimatedFromFileSize = Double(fileSize) / bytesPerSecond
        // Keep parsed value when it's already in the same ballpark
        // (parser found the LAME/XING header → trustable). Override
        // only when parsed is implausibly short — the truncated-head
        // signature.
        guard parsed < estimatedFromFileSize * 0.5 else { return parsed }
        let bitRateLabel = (bitRateKbps ?? 0) > 0 ? "\(bitRateKbps!)kbps parsed" : "\(Self.defaultMP3Bitrate)kbps fallback"
        plog(String(format: "📥 Backfill: '%@' duration estimate %.1fs → %.1fs (size=%lldKB %@ — real value will land when user plays once)",
                    title, parsed, estimatedFromFileSize, fileSize / 1024, bitRateLabel))
        return estimatedFromFileSize
    }

    private func metadataLooksMissing(_ m: MetadataService.SongMetadata) -> Bool {
        // Duration is the load-bearing field — without it the player
        // can't draw a progress bar and SFB streaming may decide the
        // song is shorter than it actually is. We treat duration alone
        // as the signal for "head fetch was insufficient, try tail".
        //
        // Why ignore artist/album: M4A/MP4/M4B commonly put `udta`
        // (artist/album tags) in the head but `moov` (which carries
        // duration via `mvhd`/`mdhd`) at the tail. The old rule only
        // fired tail-fetch when ALL of artist/album/duration were
        // missing — so these files passed with duration=0 and got
        // marked failed downstream. Failing on missing duration alone
        // costs one extra Range request for the small minority of
        // files that don't expose duration in head, and recovers the
        // common case where tail has it.
        m.duration <= 0
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
            lyricsFileName: lyricsRef,
            revision: bare.revision
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
