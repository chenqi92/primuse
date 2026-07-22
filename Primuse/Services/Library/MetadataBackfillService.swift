import CryptoKit
import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#endif

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
    /// If an MP3's ID3 tag says the APIC frame extends beyond `headBytes`,
    /// fetch a larger head once for artwork. Keeps the normal duration
    /// backfill cheap while still recovering common 300-800KB covers.
    private static let maxID3ArtworkHeadBytes: Int = 2 * 1024 * 1024

    /// Tail-Range fetch size for M4A files where moov is at the end.
    private static let tailBytes: Int64 = 256 * 1024

    /// Persisted set of song IDs that previously failed metadata extraction.
    /// Skipped on subsequent runs so we don't burn API quota retrying them
    /// every app launch.
    private var failedSongIDs: Set<String> = []

    /// Songs that parsed fine (have a usable duration) but yielded no
    /// extractable embedded artwork. Kept SEPARATE from `failedSongIDs`:
    /// a missing cover must not mark a song permanently failed (that dropped
    /// its duration update at flush and stuck it bare). These songs stay
    /// playable & recoverable; we only stop re-fetching them *for artwork*.
    private var artworkGivenUpIDs: Set<String> = []

    /// Songs whose embedded title has been checked under the metadata-title
    /// policy. Older builds intentionally kept the filename even after parsing
    /// tags, so every backfillable remote song needs one successful pass after
    /// upgrading. Persisting the IDs makes this a one-time repair rather than a
    /// Range request on every launch.
    private var titleCheckedIDs: Set<String> = []

    /// Consecutive *transient* failure count per song ID, this session only.
    /// Reset to 0 on a successful backfill. Not persisted — a throttle blip
    /// today must not disqualify the song on future launches.
    private var transientFailureCounts: [String: Int] = [:]
    /// Songs parked this session after `maxTransientRetries` consecutive
    /// transient failures (timeout / network / rate-limit). Treated like
    /// `failedSongIDs` for queueing and UI (skipped from the queue, the row
    /// spinner stops) but deliberately NOT written to disk: a transient
    /// throttle shouldn't permanently mark the song unreadable, so the next
    /// launch starts it fresh when the source is healthy again.
    private var sessionGivenUpIDs: Set<String> = []

    /// UserDefaults key for "only run backfill on Wi-Fi". Default true.
    /// User-facing toggle lives in CloudSyncSettingsView.
    static let wifiOnlyDefaultsKey = "primuse.cloudScanWifiOnly"

    /// True when backfill is currently deferred because we're on cellular
    /// with "Wi-Fi only" on AND there's actually pending work. Drives the
    /// UI prompt that asks the user whether to proceed on 5G/4G. Cleared
    /// once the user chooses (allowCellular / dismissCellularPrompt).
    private(set) var pausedForCellular: Bool = false
    /// User opted into cellular backfill for this session only (not persisted).
    private var cellularAllowedThisSession = false
    /// User dismissed the cellular prompt this session — don't re-prompt
    /// automatically until next launch.
    private var cellularPromptDismissedThisSession = false

    private let library: MusicLibrary
    private let sourceManager: SourceManager
    private let backfillableSourceIDs: () -> Set<String>
    private let metadataService = MetadataService()
    private let failedURL: URL
    private let artworkGivenUpURL: URL
    private let titleCheckedURL: URL

    /// Songs currently being processed (for UI / cancellation).
    private(set) var pendingCount: Int = 0
    private(set) var processedCount: Int = 0
    private(set) var isRunning: Bool = false
    /// Cached in one library pass and consumed by all source cards. The old
    /// implementation filtered the complete song array once per card on every
    /// SwiftUI body update, multiplying work by source count during scrolling.
    private(set) var cachedRemainingCount: Int = 0
    private(set) var remainingCountBySourceID: [String: Int] = [:]
    private var lastRemainingCountRefreshAt = Date.distantPast
    private static let remainingCountRefreshInterval: TimeInterval = 5

    private var worker: Task<Void, Never>?
    /// Source lifecycle notifications can arrive from the view, CloudKit and
    /// the global cleanup coordinator almost simultaneously. Coalesce them so
    /// removing several large sources scans the library once instead of once
    /// per notification/source on the main actor.
    private var pendingDiscardSourceIDs: Set<String> = []
    private var discardWorkTask: Task<Void, Never>?
    /// Exact session progress, kept non-observable so one completed network
    /// request doesn't invalidate every view that observes this service.
    private var processedTotal: Int = 0
    /// Debounced writer for the three persisted ID sets. Encoding and atomic
    /// file replacement run off the main actor.
    private var statePersistenceTask: Task<Void, Never>?
    /// Bumped on every `start()` / `stop()`. The worker captures its own
    /// generation and uses it to decide whether the cleanup at end-of-Task
    /// should clear shared state — without this, a cancelled-but-still-
    /// finishing worker can wipe `worker`/`isRunning` set by a new `start()`
    /// that ran between cancel and Task.value resumption.
    private var workerGeneration: Int = 0

    /// Worker 持有的 UIBackgroundTask ID, app 切到后台时给 backfill ~30 秒额外
    /// 收尾时间。worker 完成 / stop 时释放。expirationHandler 兜底 ── 系统提前
    /// 回收时主动 stop, 不留半挂状态。
    /// macOS 没有 UIBackgroundTask 机制 ── app 切后台就是后台进程, 不会被立即
    /// 挂起, 所以这块代码用 `#if os(iOS)` 整体守卫。
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(
        library: MusicLibrary,
        sourceManager: SourceManager,
        backfillableSourceIDs: @escaping () -> Set<String> = { [] }
    ) {
        self.library = library
        self.sourceManager = sourceManager
        self.backfillableSourceIDs = backfillableSourceIDs
        let appSupport = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.failedURL = directory.appendingPathComponent("backfill-failed.json")
        self.artworkGivenUpURL = directory.appendingPathComponent("backfill-artwork-givenup.json")
        self.titleCheckedURL = directory.appendingPathComponent("backfill-title-checked.json")
        loadFailed()
        loadArtworkGivenUp()
        loadTitleChecked()

        // One-time migration. Earlier builds had an overly-aggressive
        // partial-merge rule that marked any song as failed when head
        // 256KB didn't yield a duration — even if a tail-fetch would
        // have recovered it (M4A with udta in head, moov at tail are
        // the common victim). Field reports surfaced ~500 stuck songs
        // per library. Wipe the persisted set so those songs get a
        // fresh attempt under the corrected logic. Versioned key
        // prevents repeating on every launch.
        // v2026_06: 回填失败判定改为「区分瞬时/永久」后,清一次旧的 failedSongIDs,
        // 让此前被瞬时错误(源未就绪等)误钉成永久失败的歌按新逻辑重试。
        let migrationKey = "primuse.backfillFailedReset.v2026_06_transientRetry"
        if !UserDefaults.standard.bool(forKey: migrationKey), !failedSongIDs.isEmpty {
            plog("📥 Backfill: wiping \(failedSongIDs.count) failedSongIDs (one-time migration: transient/permanent split)")
            failedSongIDs.removeAll()
            saveFailed()
        }

        // v2026_06b: artwork-only failures used to land in failedSongIDs, which
        // dropped the song's (already parsed) duration at flush and stuck it
        // bare — playable songs that merely lacked an embedded cover ended up
        // unplayable with no cover. Now they go to artworkGivenUpIDs instead.
        // Wipe the old persisted failures once so anything stuck purely for a
        // missing cover gets a fresh pass and keeps its duration.
        let artworkDecoupleKey = "primuse.backfillFailedReset.v2026_06b_artworkDecouple"
        if !UserDefaults.standard.bool(forKey: artworkDecoupleKey) {
            if !failedSongIDs.isEmpty {
                plog("📥 Backfill: wiping \(failedSongIDs.count) failedSongIDs (one-time: artwork/fail decouple)")
                failedSongIDs.removeAll()
                saveFailed()
            }
            UserDefaults.standard.set(true, forKey: artworkDecoupleKey)
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

        // Fifth one-time migration. FLAC backfill used to rely entirely on
        // AVFoundation reading a truncated 256KB temp file. Field reports from
        // OneDrive showed those rows being marked failed because duration stayed
        // at 0. The reader now parses FLAC STREAMINFO directly from the header,
        // so clear failed marks for duration-less FLAC rows and let them retry.
        let flacStreamInfoFixKey = "primuse.backfillFailedReset.v2026_06_flacStreamInfo"
        if !UserDefaults.standard.bool(forKey: flacStreamInfoFixKey) {
            let flacIDs = Set(library.songs.lazy.filter {
                $0.fileFormat == .flac && $0.duration <= 0
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(flacIDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                saveFailed()
                plog("📥 Backfill: clearing \(resetIDs.count) failed FLAC rows for STREAMINFO retry")
            }
            UserDefaults.standard.set(true, forKey: flacStreamInfoFixKey)
        }

        // Sixth one-time migration. Before partial ID3 results were persisted,
        // an MP3 whose title/artist parsed correctly but whose duration did not
        // was pinned in failedSongIDs forever. Give those rows one fresh pass:
        // the native TIT2/TPE1/TALB reader can now recover their text, and the
        // worker saves that text even if duration remains unavailable.
        let partialID3FixKey = "primuse.backfillFailedReset.v2026_07_partialID3Text"
        if !UserDefaults.standard.bool(forKey: partialID3FixKey) {
            let mp3IDs = Set(library.songs.lazy.filter {
                $0.fileFormat == .mp3
            }.map(\.id))
            let resetIDs = failedSongIDs.intersection(mp3IDs)
            if !resetIDs.isEmpty {
                failedSongIDs.subtract(resetIDs)
                sessionGivenUpIDs.subtract(resetIDs)
                titleCheckedIDs.subtract(resetIDs)
                for id in resetIDs { transientFailureCounts[id] = nil }
                saveFailed()
                saveTitleChecked()
                plog("📥 Backfill: clearing \(resetIDs.count) failed MP3 rows for partial ID3 text retry")
            }
            UserDefaults.standard.set(true, forKey: partialID3FixKey)
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
                self.sessionGivenUpIDs.subtract(ids)
                self.titleCheckedIDs.subtract(ids)
                for id in ids { self.transientFailureCounts[id] = nil }
                self.saveFailed()
                self.saveTitleChecked()
                self.start()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .primuseSourceDidSoftDelete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? String else { return }
            MainActor.assumeIsolated {
                self.discardWork(forSourceID: id)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .primuseSourceDidDelete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? String else { return }
            MainActor.assumeIsolated {
                self.discardWork(forSourceID: id)
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
        refreshRemainingCounts(force: true)

        // Cellular gate. Backfill on a 2200-song cloud library is ~550MB —
        // enough to be a problem on metered connections. Instead of silently
        // deferring, surface a prompt (pausedForCellular) when there's actually
        // work to do, so the user can opt into 5G/4G if they need it.
        if shouldBlockForCellular() {
            pausedForCellular = hasPendingWork && !cellularPromptDismissedThisSession
            plog("📥 Backfill: deferred (cellular + Wi-Fi-only); pendingWork=\(hasPendingWork) prompt=\(pausedForCellular)")
            return
        }
        pausedForCellular = false

        let needsBackfill = pickNextBatch()
        guard !needsBackfill.isEmpty else {
            // Either every song has metadata OR every bare song is in
            // failedSongIDs. Surface both numbers so a "spinner stuck"
            // report can be triaged from the log without app-side
            // instrumentation.
            let sourceIDs = backfillableSourceIDs()
            let bareTotal = library.songs.lazy.filter {
                sourceIDs.contains($0.sourceID) && Self.isBareSong($0)
            }.count
            plog("📥 Backfill: skip (no eligible bare songs — total=\(library.songs.count) bare=\(bareTotal) failed=\(failedSongIDs.count))")
            return
        }
        pendingCount = needsBackfill.count
        processedTotal = 0
        processedCount = 0
        isRunning = true
        workerGeneration += 1
        let generation = workerGeneration
        beginBackgroundTaskIfNeeded()
        // Diagnostic: prove that we only pick still-bare songs. If you see
        // this number stay >0 forever you can compare against
        // `library.songs.count` to confirm no infinite reprocessing.
        plog("📥 Backfill: gen=\(generation) bareInLib=\(remainingCount) batchHead=\(needsBackfill.count)")
        worker = Task { [weak self] in
            await self?.runWorker()
            await MainActor.run { [weak self] in
                guard let self, self.workerGeneration == generation else { return }
                let processed = self.processedTotal
                self.processedCount = processed
                self.worker = nil
                self.isRunning = false
                self.pendingCount = 0
                self.refreshRemainingCounts(force: true)
                self.endBackgroundTaskIfHeld()
                // 完成通知 ── 处理 >= 5 首才发, 避免每次 worker 短跑都打扰用户。
                // hasPendingWork == false 表示当前没遗留 ── 队列全清才算"完成"。
                // postIfEnabled 内部会检查用户在设置页是否开了开关 + 系统是否已授权,
                // 不满足条件直接 noop。
                if processed >= 5 && !self.hasPendingWork {
                    let processedCount = processed
                    Task {
                        await UserNotificationService.shared.postLongTaskCompletion(
                            category: .rescrapeLibraryDone,
                            title: String(localized: "backfill_done_title"),
                            body: String(format: String(localized: "backfill_done_body"), processedCount)
                        )
                    }
                }
            }
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        #if os(iOS)
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "primuse.backfill") { [weak self] in
            // System wants the time back ── stop worker gracefully, release token.
            // 之前没这个 expirationHandler, app 切到后台时 backfill 立刻被挂起,
            // 没机会 flush in-flight batch。现在能多 30 秒优雅收尾。
            Task { @MainActor [weak self] in
                self?.stop()
                self?.endBackgroundTaskIfHeld()
            }
        }
        plog("📥 Backfill: beginBackgroundTask id=\(backgroundTaskID.rawValue)")
        #endif
    }

    private func endBackgroundTaskIfHeld() {
        #if os(iOS)
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
        plog("📥 Backfill: endBackgroundTask id=\(id.rawValue)")
        #endif
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
        pendingCount = 0
        endBackgroundTaskIfHeld()
    }

    /// Re-evaluate active work after a source was enabled or disabled.
    /// This cancels the current snapshot so disabled sources stop burning
    /// network, but deliberately keeps failedSongIDs intact so the next
    /// launch does not retry files already classified as unparseable.
    func sourceAvailabilityChanged() {
        stop()
        refreshQueue()
    }

    /// Drop queued work for a source that was removed. The
    /// worker processes fixed snapshots, so without stopping it a deleted
    /// 10K-song source can keep burning through stale rows until relaunch.
    func discardWork(forSourceID sourceID: String) {
        discardWork(forSourceIDs: [sourceID])
    }

    func discardWork(forSourceIDs sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        pendingDiscardSourceIDs.formUnion(sourceIDs)
        // Network work must stop immediately; only the potentially expensive
        // library/state sweep is debounced.
        stop()

        discardWorkTask?.cancel()
        discardWorkTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.flushPendingDiscardWork()
        }
    }

    /// Used by the source-cleanup coordinator immediately before it removes
    /// the songs from MusicLibrary. Waiting for the debounce after that point
    /// would lose the IDs needed to clear the persisted backfill state.
    func discardWorkNow(forSourceIDs sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        pendingDiscardSourceIDs.formUnion(sourceIDs)
        stop()
        discardWorkTask?.cancel()
        discardWorkTask = nil
        flushPendingDiscardWork()
    }

    private func flushPendingDiscardWork() {
        let sourceIDs = pendingDiscardSourceIDs
        pendingDiscardSourceIDs.removeAll(keepingCapacity: true)
        discardWorkTask = nil
        guard !sourceIDs.isEmpty else { return }

        let songIDs = Set(library.songs.lazy.filter {
            sourceIDs.contains($0.sourceID)
        }.map(\.id))
        guard !songIDs.isEmpty else { return }
        failedSongIDs.subtract(songIDs)
        sessionGivenUpIDs.subtract(songIDs)
        titleCheckedIDs.subtract(songIDs)
        for id in songIDs { transientFailureCounts[id] = nil }
        saveFailed()
        saveTitleChecked()
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
        let sourceIDs = backfillableSourceIDs()
        return library.songs.contains { song in
            !failedSongIDs.contains(song.id)
                && !sessionGivenUpIDs.contains(song.id)
                && sourceIDs.contains(song.sourceID)
                && self.needsBackfill(song)
        }
    }

    /// Number of songs currently waiting for backfill. Used by the UI to
    /// show "loading details · N remaining" — the older `pendingCount`
    /// was a snapshot at start time so it could disagree with reality
    /// after Phase A added more bare songs mid-backfill.
    var remainingCount: Int {
        cachedRemainingCount
    }

    /// True if backfill has given up on this song (extraction failed, or
    /// the file is parseable but exposes no duration). Used by SongRowView
    /// to swap the "loading details" spinner for a static "details
    /// unavailable" hint so the user isn't stuck staring at a forever-
    /// loading row.
    func didFail(songID: String) -> Bool {
        // Includes session-parked songs (repeated transient failures) so the
        // row swaps its forever-spinner for the "details unavailable" hint.
        failedSongIDs.contains(songID) || sessionGivenUpIDs.contains(songID)
    }

    /// Per-source variant — used by the source card so its "remaining"
    /// number matches the global storage page rather than counting
    /// songs that backfill has given up on.
    func remainingCount(forSource sourceID: String?) -> Int {
        guard let sourceID else { return cachedRemainingCount }
        return remainingCountBySourceID[sourceID] ?? 0
    }

    private func refreshRemainingCounts(force: Bool = false) {
        let now = Date()
        guard force
                || now.timeIntervalSince(lastRemainingCountRefreshAt)
                    >= Self.remainingCountRefreshInterval else { return }
        lastRemainingCountRefreshAt = now
        let sourceIDs = backfillableSourceIDs()
        var bySource: [String: Int] = [:]
        bySource.reserveCapacity(sourceIDs.count)
        var total = 0
        for song in library.songs {
            guard !failedSongIDs.contains(song.id),
                  !sessionGivenUpIDs.contains(song.id),
                  sourceIDs.contains(song.sourceID),
                  needsBackfill(song) else { continue }
            bySource[song.sourceID, default: 0] += 1
            total += 1
        }
        if remainingCountBySourceID != bySource {
            remainingCountBySourceID = bySource
        }
        if cachedRemainingCount != total {
            cachedRemainingCount = total
        }
    }

    /// Number of songs backfill has given up on — persisted permanent
    /// failures plus this-session transient parks — that are still in the
    /// library, still duration-less, and from an active source. Drives the
    /// "retry failed" button: 0 ⇒ nothing to retry.
    var failedCount: Int {
        let sourceIDs = backfillableSourceIDs()
        return library.songs.lazy.filter { song in
            (self.failedSongIDs.contains(song.id) || self.sessionGivenUpIDs.contains(song.id))
                && sourceIDs.contains(song.sourceID)
                && Self.isBareSong(song)
        }.count
    }

    /// Clear failure marks for every duration-less song (persisted + session
    /// parks) and restart backfill so the user can re-attempt reads that
    /// previously failed — e.g. after a flaky source recovered. Scoped to bare
    /// songs so pressing it doesn't trigger a mass artwork re-fetch for MP3s
    /// that merely lack an embedded cover. Bound to the retry button.
    func retryFailed() {
        let bareIDs = Set(library.songs.lazy.filter { Self.isBareSong($0) }.map(\.id))
        guard !bareIDs.isEmpty else { return }
        failedSongIDs.subtract(bareIDs)
        sessionGivenUpIDs.subtract(bareIDs)
        for id in bareIDs { transientFailureCounts[id] = nil }
        saveFailed()
        plog("📥 Backfill: retryFailed cleared \(bareIDs.count) bare-song marks, restarting")
        start()
    }

    // MARK: - Worker

    /// Large cloud libraries need far fewer whole-library cache/index rebuilds.
    /// Network requests still complete continuously; only the observable
    /// library publication is coalesced.
    private static let flushBatchSize = 100
    /// Even with a partial batch, flush at least every N seconds so the
    /// user sees progress without having to wait for 10 songs.
    private static let flushInterval: TimeInterval = 2
    /// 并发处理 worker 数。百度网盘 actor 内的 throttle 把 callAPI 串行化
    /// (避免 errno 31034 限流), 但 Range fetch 走 actor 外 URLSession 能真
    /// 并发。3 个 worker 实测下吞吐量翻倍多, 再多会撞 throttle 等待 + 触发
    /// 服务端限流。其他 connector (Synology / WebDAV) 也用同一个并发数,
    /// 它们没限速但 3 路并发也比串行快。
    private static let workerConcurrency = 3
    /// Hard cap for a single song's metadata backfill. Some SMB/NAS stacks can
    /// leave a READ or AVFoundation metadata load suspended indefinitely for a
    /// damaged or locked file. Let that file go and keep the queue moving.
    private static let perSongTimeout: TimeInterval = 45
    /// Max consecutive *transient* failures tolerated for one song within a
    /// session before we stop retrying it. Without this cap, a file that the
    /// source (e.g. 百度网盘) keeps throttling past the connector's request
    /// timeout fails transiently → never marked failed → re-picked every pass
    /// → its "读取标签中…" spinner spins forever. The cap parks such a song for
    /// the session; a future launch retries it fresh.
    private static let maxTransientRetries = 5

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

        // 预热阶段: 按 source 分组, 给每个 source 调一次 batch prefetchMetadata
        // (百度网盘会一次拿 100 个 dlink, 其他 connector 默认 noop)。后续每首
        // 的 fetchRange 走 dlink cache 命中, 省掉 1w 次 filemetas API 配额。
        let songsBySource: [String: [Song]] = Dictionary(grouping: snapshot) { $0.sourceID }
        for (_, sourceSongs) in songsBySource {
            guard !Task.isCancelled else { return }
            guard let representative = sourceSongs.first else { continue }
            guard isStillEligible(representative) else { continue }
            if let connector = try? await sourceManager.connectorForSong(representative) {
                let paths = sourceSongs.map(\.filePath)
                await connector.prefetchMetadata(paths: paths)
            }
        }

        // 并发 worker 拉取 ── TaskGroup pull-pattern, 启动 N 个 task 跑 processOne,
        // 谁完成立刻拿下一首。比 chunk 切片均匀, 慢源 / 快源混合时不会被慢
        // 元素拖整批进度。pendingFlush 的累积 + flush 都在 main actor (TaskGroup
        // body 是 main actor isolated, 各 task 完成回到这里时是 serial 的),
        // 不需要锁。
        var iterator = snapshot.makeIterator()
        await withTaskGroup(of: (song: Song, outcome: BackfillOutcome).self) { group in
            defer { group.cancelAll() }
            // Seed: 启动 workerConcurrency 个 task
            for _ in 0..<Self.workerConcurrency {
                guard let song = iterator.next() else { break }
                if shouldBlockForCellular() { return }
                guard isStillEligible(song) else { continue }
                group.addTask { [self] in (song, await self.processOne(song)) }
            }

            // Drain: 每完成一个就启动下一个, 同时累积 / flush
            while let result = await group.next() {
                if Task.isCancelled { break }

                processedTotal += 1
                // UI progress does not need per-file granularity. Publishing
                // every ten results prevents an Observable invalidation storm
                // while retaining responsive feedback.
                if processedTotal.isMultiple(of: 10) || processedTotal == pendingCount {
                    processedCount = processedTotal
                }
                let songID = result.song.id
                if result.outcome.markFailed, isStillEligible(result.song) {
                    failedSongIDs.insert(songID)
                    saveFailed()
                }
                if result.outcome.transientFailure, isStillEligible(result.song) {
                    // Cap consecutive transient failures so a chronically
                    // throttled file (timeout every pass) can't loop forever —
                    // park it for the session instead, which stops the row
                    // spinner without persisting a false "permanent" failure.
                    let count = (transientFailureCounts[songID] ?? 0) + 1
                    if count >= Self.maxTransientRetries {
                        sessionGivenUpIDs.insert(songID)
                        transientFailureCounts[songID] = nil
                        plog("⚠️ Backfill: '\(result.song.title)' parked for session after \(count) transient failures (retries next launch)")
                    } else {
                        transientFailureCounts[songID] = count
                    }
                }
                if result.outcome.artworkGivenUp {
                    // Stop re-fetching this song for artwork, but DON'T fail it —
                    // its duration update below still flushes and it stays playable.
                    artworkGivenUpIDs.insert(songID)
                    saveArtworkGivenUp()
                }
                if let updated = result.outcome.song {
                    transientFailureCounts[songID] = nil  // success → reset streak
                    pendingFlush.append(updated)
                }

                // Flush when the batch is full OR the interval has elapsed。
                // 在 main actor 上, library.replaceSongs 调一次即可。
                let shouldFlush = pendingFlush.count >= Self.flushBatchSize
                    || Date().timeIntervalSince(lastFlushAt) >= Self.flushInterval
                if shouldFlush, !pendingFlush.isEmpty {
                    // Partial metadata can be accompanied by markFailed=true
                    // (for example TIT2 parsed but duration did not). Failure
                    // membership must stop future network retries, not discard
                    // the useful result we already have.
                    let batch = pendingFlush.filter(canApplyBackfillResult)
                    pendingFlush.removeAll(keepingCapacity: true)
                    lastFlushAt = Date()
                    if !batch.isEmpty {
                        library.replaceSongs(batch)
                        markTitlesChecked(in: batch)
                        refreshRemainingCounts()
                        plog("📥 flushed \(batch.count) songs to library")
                    }
                }

                // Cellular check between songs ── 切到 cellular 后停止派发新
                // task, 已 in-flight 的让它们自然完成 (next 仍会 yield)。
                if shouldBlockForCellular() {
                    plog("📥 Backfill: cellular detected, stop dispatching new tasks")
                    continue
                }

                // 派发下一首给空闲 worker。
                if let next = iterator.next() {
                    guard isStillEligible(next) else { continue }
                    group.addTask { [self] in (next, await self.processOne(next)) }
                }
            }
        }

        // Final flush
        if !pendingFlush.isEmpty {
            let batch = pendingFlush.filter(canApplyBackfillResult)
            pendingFlush.removeAll()
            if !batch.isEmpty {
                library.replaceSongs(batch)
                markTitlesChecked(in: batch)
                refreshRemainingCounts()
                plog("📥 final flush: \(batch.count) songs to library")
            }
        }
        // Also publish permanent/transient failures from a snapshot that had
        // no successful songs to flush.
        refreshRemainingCounts(force: true)
    }

    private func shouldBlockForCellular() -> Bool {
        let wifiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyDefaultsKey) as? Bool ?? true
        // 用户本次会话已明确同意蜂窝 → 不再拦。
        return wifiOnly && !cellularAllowedThisSession && !NetworkMonitor.shared.isOnUnmeteredNetwork
    }

    /// 用户在蜂窝提示里选择「继续」。persist=true 时永久关闭「仅 WiFi」开关,
    /// 否则只放行本次会话。随后立即恢复回填。
    func allowCellular(persist: Bool) {
        cellularAllowedThisSession = true
        if persist {
            UserDefaults.standard.set(false, forKey: Self.wifiOnlyDefaultsKey)
        }
        pausedForCellular = false
        start()
    }

    /// 用户选择「仅 WiFi / 暂不」。本会话不再自动弹蜂窝提示。
    func dismissCellularPrompt() {
        cellularPromptDismissedThisSession = true
        pausedForCellular = false
    }

    /// 回填读取失败是否属于「瞬时、可重试」错误(连接/鉴权/超时/限流/网络/取消),
    /// 而非「永久」错误(文件已不存在、4xx 客户端错误)。瞬时错误不标 failed,
    /// 下一轮自动重试,避免重装/启动初期源未就绪时把歌永久钉成「无法读取」。
    static func isTransientBackfillError(_ error: Error) -> Bool {
        if error is BackfillHardTimeoutError { return false }
        if error is URLError { return true }
        if error is CancellationError { return true }
        switch error {
        case SourceError.connectionFailed, SourceError.authenticationFailed, SourceError.timeout:
            return true
        case SourceError.pathNotFound, SourceError.fileNotFound:
            return false // 文件确实不在了 —— 永久
        case CloudDriveError.notAuthenticated, CloudDriveError.tokenExpired,
             CloudDriveError.tokenRefreshFailed, CloudDriveError.rateLimited,
             CloudDriveError.invalidResponse:
            return true
        case CloudDriveError.fileNotFound:
            return false
        case CloudDriveError.apiError(let code, _):
            return !(400..<500).contains(code) // 4xx 永久, 5xx/其它瞬时
        default:
            return true // 未知的读取错误 → 当瞬时, 倾向重试而非永久卡死
        }
    }

    /// Outcome of one backfill attempt. `song` is the merged result to
    /// flush into the library when present (preserves whatever fields we
    /// did parse, e.g. artist+album when duration was unreadable).
    /// `markFailed` tells the caller to add the original ID to
    /// `failedSongIDs` so backfill stops retrying — set even on partial
    /// merges so a duration-less file isn't picked up next pass.
    struct BackfillOutcome: Sendable {
        var song: Song?
        var markFailed: Bool
        /// Set when the attempt failed with a *transient* error (timeout /
        /// network / throttle). The caller bumps a per-song retry counter and
        /// parks the song after `maxTransientRetries` so it stops re-queuing.
        var transientFailure: Bool = false
        /// Song parsed fine (has a usable duration) but has no extractable
        /// embedded artwork. Stop retrying it *for artwork* without marking it
        /// permanently failed — its duration update is still saved and it stays
        /// playable & recoverable.
        var artworkGivenUp: Bool = false
    }

    private struct BackfillHardTimeoutError: LocalizedError, Sendable {
        let seconds: TimeInterval

        var errorDescription: String? {
            "Timed out reading tags after \(seconds.finiteInt())s"
        }
    }

    private final class AsyncTimeoutBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: CheckedContinuation<T, Error>
        private var didFinish = false
        private var workTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func setTasks(workTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
            lock.lock()
            if didFinish {
                lock.unlock()
                workTask.cancel()
                timeoutTask.cancel()
                return
            }
            self.workTask = workTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }

        func succeed(_ value: T) {
            finish(.success(value))
        }

        func fail(_ error: Error) {
            finish(.failure(error))
        }

        private func finish(_ result: Result<T, Error>) {
            let tasks: (work: Task<Void, Never>?, timeout: Task<Void, Never>?)
            lock.lock()
            if didFinish {
                lock.unlock()
                return
            }
            didFinish = true
            tasks = (workTask, timeoutTask)
            lock.unlock()

            tasks.work?.cancel()
            tasks.timeout?.cancel()

            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private nonisolated static func withHardTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let box = AsyncTimeoutBox<T>(continuation)
            let timeoutNanoseconds = (max(0.1, seconds) * 1_000_000_000)
                .finiteUInt64(or: 100_000_000)

            let workTask = Task {
                do {
                    box.succeed(try await operation())
                } catch {
                    box.fail(error)
                }
            }

            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    box.fail(BackfillHardTimeoutError(seconds: seconds))
                } catch {
                    // The timeout task is cancelled when work finishes first.
                }
            }

            box.setTasks(workTask: workTask, timeoutTask: timeoutTask)
        }
    }

    /// Run one backfill against `song`. Returns a merged Song to flush
    /// (may be nil if extraction yielded nothing usable) and a flag
    /// indicating whether the attempt should be remembered as failed —
    /// the two are independent because some files parse partial tags
    /// (artist, album) but never expose duration.
    private func processOne(_ song: Song) async -> BackfillOutcome {
        let started = Date()
        do {
            return try await Self.withHardTimeout(seconds: Self.perSongTimeout) { [self] in
                try await self.processOneCore(song, started: started)
            }
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            if !isStillEligible(song) {
                return BackfillOutcome(song: nil, markFailed: false)
            }
            // 只有「确定性永久」的错误(文件已不存在 / 4xx)才标记 failed —— 那种
            // 重试也没用,标记后不再浪费配额。连接/鉴权/超时/限流/网络这类是瞬时的
            // (常见于刚启动、源还没连上 / token 还没就绪),绝不能钉成永久失败,否则
            // 会一直卡在「无法读取歌曲详情」;不标记 → 下一轮回填自动重试。
            let transient = Self.isTransientBackfillError(error)
            plog(String(format: "⚠️ Backfill failed for '%@' after %.2fs: %@ (%@)",
                        song.title, elapsed, error.localizedDescription,
                        transient ? "transient — will retry" : "permanent — marking failed"))
            return BackfillOutcome(song: nil, markFailed: !transient, transientFailure: transient)
        }
    }

    private func processOneCore(_ song: Song, started: Date) async throws -> BackfillOutcome {
        guard isStillEligible(song) else {
            return BackfillOutcome(song: nil, markFailed: false)
        }
        // Use the SHARED connector (not auxiliary). Backfill is sequential
        // and benefits massively from accumulated state on the single
        // BaiduPanSource actor: throttle clock, dlink cache, dir-listing
        // cache. Auxiliary instances reset all of that per song, which is
        // what made backfill 10x slower than it needed to be — every song
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

        // Do not turn metadata backfill into a whole-library playback-cache
        // prewarm. At 256 KB per song, a 10K-song source caused ~2.5 GB of
        // unnecessary writes and sustained I/O pressure while the user was
        // browsing. Playback already prewarms the current song and queue on
        // demand through SourceManager.

        var metadata = await extractMetadata(
            from: headData,
            song: song,
            cacheKey: song.id
        )
        if Self.needsEmbeddedArtworkBackfill(song),
           metadata.coverArtFileName == nil,
           let id3ByteCount = FileMetadataReader.id3TagByteCount(in: headData),
           id3ByteCount > headData.count {
            let expandedByteCount = min(id3ByteCount, Self.maxID3ArtworkHeadBytes)
            if expandedByteCount > headData.count,
               let expandedHead = try? await connector.fetchRange(
                path: song.filePath,
                offset: 0,
                length: Int64(expandedByteCount)
               ) {
                metadata = await extractMetadata(
                    from: expandedHead,
                    song: song,
                    cacheKey: song.id
                )
            }
        }
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

        // Duration can fail independently from the ID3 text frames. Preserve
        // any title/artist/album/cover we did recover, then mark the row failed
        // only to stop repeated network reads. Older code returned nil here,
        // so a valid TIT2 was silently thrown away and the filename remained
        // visible until an online scrape replaced the song.
        if metadataLooksMissing(metadata) {
            if hasUsablePartialMetadata(metadata, comparedTo: song) {
                let partial = mergeSong(bare: song, metadata: metadata)
                plog("⚠️ Backfill: '\(song.title)' has no duration after head+tail; saving partial tags as '\(partial.title)' and marking duration failed")
                return BackfillOutcome(song: partial, markFailed: true)
            }
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
        let ext = song.fileFormat.rawValue
        if ext == "mp3" {
            metadata.duration = correctedDuration(parsed: metadata.duration, bitRateKbps: metadata.bitRate, fileSize: song.fileSize, title: song.title)
        } else if ext == "flac",
                  (metadata.bitRate ?? 0) <= 0,
                  metadata.duration > 0,
                  song.fileSize > 0 {
            metadata.bitRate = (Double(song.fileSize) * 8.0 / metadata.duration / 1000.0)
                .rounded()
                .finiteInt()
        }
        let merged = mergeSong(bare: song, metadata: metadata)
        let artworkStillMissing = Self.needsEmbeddedArtworkBackfill(song)
            && (merged.coverArtFileName?.isEmpty ?? true)
        let totalElapsed = Date().timeIntervalSince(started)
        // Include the parsed duration in the log line so an
        // infinite-loop case (pickNextBatch repeatedly handing back
        // the same songs) can be diagnosed without re-instrumenting:
        // duration=0 in the log means mergeSong didn't actually
        // capture a usable duration despite metadataLooksMissing
        // returning false → bug in the parser or the gate.
        plog(String(format: "📥 Backfill: '%@' done in %.2fs (fetch %.2fs) duration=%.1fs", song.title, totalElapsed, fetchElapsed, merged.duration))
        if artworkStillMissing {
            plog("📥 Backfill: '\(song.title)' has no parseable MP3 artwork; skipping future artwork-only retries")
        }
        // Missing artwork must NOT mark the song permanently failed — that
        // dropped its (just-parsed) duration at flush and stuck it bare. Keep
        // the duration, record the artwork give-up separately.
        return BackfillOutcome(song: merged, markFailed: false, artworkGivenUp: artworkStillMissing)
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
        let ext = song.fileFormat.rawValue
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-\(cacheKey).\(ext)")
        // Data.write and removeItem are synchronous. Keep both away from the
        // main actor; the metadata actor can read the completed temp file.
        await Task.detached(priority: .utility) {
            try? data.write(to: tempURL)
        }.value
        // tempURL 是 backfill-<hash>.<ext> 形式, 没意义。caller 传 song 原始
        // 文件名当 fallbackTitle, 嵌入 title 缺失时显示得正常。
        let originalFileBaseName = song.title
        let metadata = await metadataService.loadMetadata(
            for: tempURL,
            cacheKey: cacheKey,
            allowOnlineFetch: false,
            fallbackTitle: originalFileBaseName
        )
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        return metadata
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

    private func hasUsablePartialMetadata(
        _ metadata: MetadataService.SongMetadata,
        comparedTo song: Song
    ) -> Bool {
        let incomingTitle = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!incomingTitle.isEmpty && incomingTitle != currentTitle)
            || metadata.artist != nil
            || metadata.albumTitle != nil
            || metadata.trackNumber != nil
            || metadata.discNumber != nil
            || metadata.year != nil
            || metadata.genre != nil
            || metadata.sampleRate != nil
            || metadata.bitRate != nil
            || metadata.bitDepth != nil
            || metadata.coverArtFileName != nil
            || metadata.lyricsFileName != nil
            || metadata.replayGainTrackGain != nil
            || metadata.replayGainTrackPeak != nil
            || metadata.replayGainAlbumGain != nil
            || metadata.replayGainAlbumPeak != nil
    }

    private func mergeSong(bare: Song, metadata: MetadataService.SongMetadata) -> Song {
        let metadataTitle = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedTitle = metadataTitle.isEmpty ? bare.title : metadata.title
        let mergedArtist = metadata.artist ?? bare.artistName
        let mergedAlbum = metadata.albumTitle ?? bare.albumTitle
        let artistID = mergedArtist.map { Self.hash($0.lowercased()) }
        let albumID: String? = if let artist = mergedArtist, let album = mergedAlbum {
            Self.hash("\(artist.lowercased()):\(album.lowercased())")
        } else {
            nil
        }

        // Sidecar references on the bare song (from listFiles sibling
        // detection) win over anything embedded in the file — they're
        // higher quality (full-size cover) and remote-resolvable.
        let coverRef = bare.coverArtFileName ?? metadata.coverArtFileName
        let lyricsRef = bare.lyricsFileName ?? metadata.lyricsFileName
        let mvRef = bare.mvPath ?? metadata.mvPath

        return Song(
            id: bare.id,
            title: mergedTitle,
            albumID: albumID,
            artistID: artistID,
            albumTitle: mergedAlbum,
            artistName: mergedArtist,
            trackNumber: metadata.trackNumber ?? bare.trackNumber,
            discNumber: metadata.discNumber ?? bare.discNumber,
            duration: metadata.duration > 0 ? metadata.duration : bare.duration,
            fileFormat: bare.fileFormat,
            filePath: bare.filePath,
            sourceID: bare.sourceID,
            fileSize: bare.fileSize,
            bitRate: metadata.bitRate ?? bare.bitRate,
            sampleRate: metadata.sampleRate ?? bare.sampleRate,
            bitDepth: metadata.bitDepth ?? bare.bitDepth,
            genre: metadata.genre ?? bare.genre,
            year: metadata.year ?? bare.year,
            lastModified: bare.lastModified,
            dateAdded: bare.dateAdded,
            coverArtFileName: coverRef,
            lyricsFileName: lyricsRef,
            mvPath: mvRef,
            replayGainTrackGain: metadata.replayGainTrackGain ?? bare.replayGainTrackGain,
            replayGainTrackPeak: metadata.replayGainTrackPeak ?? bare.replayGainTrackPeak,
            replayGainAlbumGain: metadata.replayGainAlbumGain ?? bare.replayGainAlbumGain,
            replayGainAlbumPeak: metadata.replayGainAlbumPeak ?? bare.replayGainAlbumPeak,
            revision: bare.revision,
            titlePinyin: mergedTitle == bare.title ? bare.titlePinyin : nil,
            artistPinyin: mergedArtist == bare.artistName ? bare.artistPinyin : nil,
            albumPinyin: mergedAlbum == bare.albumTitle ? bare.albumPinyin : nil,
            lyricsText: bare.lyricsText
        )
    }

    // MARK: - Queue selection

    /// A song needs backfill if it has none of the metadata that file-header
    /// extraction would produce (duration, bitRate). Songs in the failure
    /// set are skipped. Limited to a batch so the queue doesn't grow
    /// unbounded for huge libraries.
    private func pickNextBatch() -> [Song] {
        let sourceIDs = backfillableSourceIDs()
        let candidates = library.songs.lazy.filter { song in
            guard !self.failedSongIDs.contains(song.id) else { return false }
            guard !self.sessionGivenUpIDs.contains(song.id) else { return false }
            guard !self.library.disabledSourceIDs.contains(song.sourceID) else { return false }
            guard sourceIDs.contains(song.sourceID) else { return false }
            return self.needsBackfill(song)
        }
        return Array(candidates.prefix(500))
    }

    private func isStillEligible(_ song: Song) -> Bool {
        guard !failedSongIDs.contains(song.id) else { return false }
        guard !sessionGivenUpIDs.contains(song.id) else { return false }
        guard !library.disabledSourceIDs.contains(song.sourceID) else { return false }
        guard backfillableSourceIDs().contains(song.sourceID) else { return false }
        guard let live = library.song(id: song.id), live.sourceID == song.sourceID else { return false }
        return self.needsBackfill(live)
    }

    /// Validate that an in-flight result still belongs to the live file. This
    /// deliberately ignores failedSongIDs: a partial result is marked failed
    /// before the coalesced flush, but its already-parsed tags must still land.
    private func canApplyBackfillResult(_ song: Song) -> Bool {
        guard !library.disabledSourceIDs.contains(song.sourceID) else { return false }
        guard backfillableSourceIDs().contains(song.sourceID) else { return false }
        guard let live = library.song(id: song.id),
              live.sourceID == song.sourceID,
              live.filePath == song.filePath else {
            return false
        }
        if let liveRevision = live.revision, let resultRevision = song.revision {
            return liveRevision == resultRevision
        }
        if live.fileSize > 0, song.fileSize > 0 {
            return live.fileSize == song.fileSize
        }
        return true
    }

    /// A song still needs backfill if it's bare (no duration), or it's an MP3
    /// missing a cover that we haven't already given up on for artwork. The
    /// artwork-give-up check keeps a duration-complete song from being re-picked
    /// forever just because its file has no embedded cover.
    private func needsBackfill(_ song: Song) -> Bool {
        Self.isBareSong(song)
            || (Self.needsEmbeddedArtworkBackfill(song) && !artworkGivenUpIDs.contains(song.id))
            || !titleCheckedIDs.contains(song.id)
    }

    private static func needsEmbeddedArtworkBackfill(_ song: Song) -> Bool {
        song.fileFormat == .mp3 && (song.coverArtFileName?.isEmpty ?? true)
    }

    // MARK: - Failed-set persistence

    private func loadFailed() {
        guard let data = try? Data(contentsOf: failedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        failedSongIDs = Set(decoded)
    }

    private func loadArtworkGivenUp() {
        guard let data = try? Data(contentsOf: artworkGivenUpURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        artworkGivenUpIDs = Set(decoded)
    }

    private func loadTitleChecked() {
        guard let data = try? Data(contentsOf: titleCheckedURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        titleCheckedIDs = Set(decoded)
    }

    private func saveArtworkGivenUp() {
        scheduleStatePersistence()
    }

    private func saveTitleChecked() {
        scheduleStatePersistence()
    }

    private func markTitlesChecked(in songs: [Song]) {
        let previousCount = titleCheckedIDs.count
        titleCheckedIDs.formUnion(songs.map(\.id))
        if titleCheckedIDs.count != previousCount {
            saveTitleChecked()
        }
    }

    private func saveFailed() {
        scheduleStatePersistence()
    }

    private func scheduleStatePersistence() {
        // Set snapshots are copy-on-write, so capturing them here is cheap.
        // Conversion to arrays, JSON encoding, and disk writes happen later on
        // a utility executor. Repeated per-song updates collapse into one write.
        let failed = failedSongIDs
        let artworkGivenUp = artworkGivenUpIDs
        let titleChecked = titleCheckedIDs
        let failedURL = failedURL
        let artworkURL = artworkGivenUpURL
        let titleURL = titleCheckedURL

        statePersistenceTask?.cancel()
        statePersistenceTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            Self.writeIDSet(failed, to: failedURL)
            Self.writeIDSet(artworkGivenUp, to: artworkURL)
            Self.writeIDSet(titleChecked, to: titleURL)
        }
    }

    private nonisolated static func writeIDSet(_ ids: Set<String>, to url: URL) {
        guard let data = try? JSONEncoder().encode(Array(ids)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func hash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
