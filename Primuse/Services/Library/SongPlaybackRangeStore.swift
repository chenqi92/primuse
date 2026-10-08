import Foundation
import PrimuseKit

/// The listener's per-song playback ranges ("播放时间段"): the part of a song
/// to play instead of the whole of it, and whether that is switched on.
///
/// The local JSON file is the source of truth. Every change also goes to the
/// listener's other devices — Apple TV included — through the key-value store,
/// merged last-writer-wins per song with clearings kept as tombstones
/// (`SongPlaybackRangeSyncPolicy`). `Song.id` hashes a per-device source id, so
/// each record also carries the title, artist and length that find the same
/// file under another device's id.
@MainActor
@Observable
final class SongPlaybackRangeStore {
    static let cloudStorageKey = "primuse_song_playback_ranges_v1"
    private static let cloudPushDelay: Duration = .seconds(2)

    static let shared = SongPlaybackRangeStore()

    /// Records by song id, including clearings (`range == nil`).
    private(set) var records: [String: SongPlaybackRangeRecord] = [:]
    /// Song ids by `SongPlaybackRangeSyncPolicy.matchKey`, for twin lookups.
    @ObservationIgnored private var idsByMatchKey: [String: [String]] = [:]

    private let storeURL: URL
    private let syncsThroughICloud: Bool
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var cloudPushTask: Task<Void, Never>?
    @ObservationIgnored private var isRegisteredWithCloud = false

    /// `storeURL` is for tests; the app uses `shared`, the only instance that
    /// syncs.
    init(storeURL: URL? = nil) {
        syncsThroughICloud = storeURL == nil
        if let storeURL {
            self.storeURL = storeURL
        } else {
            #if os(tvOS)
            let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                .appendingPathComponent("Primuse", isDirectory: true)
            #else
            let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
                .appendingPathComponent("Primuse", isDirectory: true)
            #endif
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.storeURL = base.appendingPathComponent("song_playback_ranges.json")
        }
        load()
        if syncsThroughICloud {
            CloudKVSSync.shared.register(key: Self.cloudStorageKey) { [weak self] in
                guard let self else { return }
                if self.isRegisteredWithCloud {
                    self.mergeCloudCopy()
                } else {
                    // The first reload runs inside `register`, while `shared`
                    // is still being created.
                    Task { @MainActor [weak self] in self?.mergeCloudCopy() }
                }
            }
            isRegisteredWithCloud = true
        }
    }

    // MARK: - Reading

    /// The song's range, on or off; nil when it has none.
    func range(for song: Song) -> SongPlaybackRange? {
        record(for: song)?.range
    }

    /// What the players apply to `song`: its range when it is on and fits.
    func applied(for song: Song) -> AppliedSongPlaybackRange? {
        let whole = song.withoutAppliedPlaybackRange
        return SongPlaybackRangePolicy.applied(range(for: whole), songDuration: whole.duration)
    }

    private func record(for song: Song) -> SongPlaybackRangeRecord? {
        guard !records.isEmpty else { return nil }
        let whole = song.withoutAppliedPlaybackRange
        let key = SongPlaybackRangeSyncPolicy.matchKey(title: whole.title, artist: whole.artistName)
        return SongPlaybackRangeSyncPolicy.resolvedRecord(
            songID: whole.id,
            songDuration: whole.duration,
            records: records,
            twinIDs: idsByMatchKey[key] ?? []
        )
    }

    // MARK: - Editing

    func setRange(_ range: SongPlaybackRange, for song: Song) {
        write(range, for: song)
    }

    /// Switches an existing range on or off. A song without a range is left alone.
    func setEnabled(_ enabled: Bool, for song: Song) {
        guard var range = range(for: song), range.isEnabled != enabled else { return }
        range.isEnabled = enabled
        write(range, for: song)
    }

    func clearRange(for song: Song) {
        guard range(for: song) != nil else { return }
        write(nil, for: song)
    }

    private func write(_ range: SongPlaybackRange?, for song: Song) {
        let whole = song.withoutAppliedPlaybackRange
        let record = SongPlaybackRangeRecord(
            range: range,
            updatedAt: Date(),
            title: whole.title,
            artist: whole.artistName ?? "",
            songDuration: whole.duration
        )
        guard records[whole.id] != record else { return }
        records[whole.id] = record
        rebuildIndex()
        didChange(songIDs: [whole.id])
        scheduleSave()
        scheduleCloudPush()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let state = SongPlaybackRangeSyncPolicy.decode(data) else { return }
        records = SongPlaybackRangeSyncPolicy.retained(state, now: Date()).records
        rebuildIndex()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard let data = SongPlaybackRangeSyncPolicy.encode(SongPlaybackRangeSyncState(records: records)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func rebuildIndex() {
        var index: [String: [String]] = [:]
        for (id, record) in records {
            index[SongPlaybackRangeSyncPolicy.matchKey(title: record.title, artist: record.artist), default: []].append(id)
        }
        idsByMatchKey = index
    }

    private func didChange(songIDs: Set<String>?) {
        var userInfo: [String: Any] = [:]
        if let songIDs { userInfo["songIDs"] = songIDs }
        NotificationCenter.default.post(name: .primuseSongPlaybackRangesDidChange, object: nil, userInfo: userInfo)
    }

    // MARK: - iCloud

    private func scheduleCloudPush() {
        guard syncsThroughICloud else { return }
        cloudPushTask?.cancel()
        cloudPushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cloudPushDelay)
            guard !Task.isCancelled else { return }
            self?.pushToCloudNow()
        }
    }

    /// Merges with the cloud copy first, so a push never replaces another
    /// device's records it has not seen.
    private func pushToCloudNow() {
        cloudPushTask = nil
        guard syncsThroughICloud else { return }
        let remote = SongPlaybackRangeSyncPolicy.decode(
            UserDefaults.standard.data(forKey: Self.cloudStorageKey)
        ) ?? .empty
        settle(SongPlaybackRangeSyncPolicy.merge(SongPlaybackRangeSyncState(records: records), remote), over: remote)
    }

    /// The cloud copy changed: take what it has that this device lacks, and
    /// push back only if this device has something it lacks.
    private func mergeCloudCopy() {
        guard let remote = SongPlaybackRangeSyncPolicy.decode(
            UserDefaults.standard.data(forKey: Self.cloudStorageKey)
        ) else { return }
        settle(SongPlaybackRangeSyncPolicy.merge(SongPlaybackRangeSyncState(records: records), remote), over: remote)
    }

    private func settle(_ merged: SongPlaybackRangeSyncState, over remote: SongPlaybackRangeSyncState) {
        let retained = SongPlaybackRangeSyncPolicy.retained(merged, now: Date())
        if retained.records != records {
            records = retained.records
            rebuildIndex()
            scheduleSave()
            // Arrivals from another device may concern any song.
            didChange(songIDs: nil)
        }
        let upload = SongPlaybackRangeSyncPolicy.uploadState(retained)
        guard upload != remote, let data = SongPlaybackRangeSyncPolicy.encode(upload) else { return }
        UserDefaults.standard.set(data, forKey: Self.cloudStorageKey)
        CloudKVSSync.shared.markChanged(key: Self.cloudStorageKey)
    }
}

extension Notification.Name {
    /// Posted when playback ranges changed. `userInfo["songIDs"]` is the
    /// `Set<String>` of songs edited here; it is absent when ranges arrived
    /// from another device and any song may be affected.
    static let primuseSongPlaybackRangesDidChange = Notification.Name("primuse.songPlaybackRangesDidChange")
}
