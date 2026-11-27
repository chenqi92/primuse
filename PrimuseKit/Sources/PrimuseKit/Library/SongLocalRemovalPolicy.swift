import Foundation

/// Why a deletion never reached the source file. The classification itself
/// lives with `SourceManager`, which owns the transport error types; the cases
/// are shared so policy and persistence can be tested without them.
public enum SourceFileDeletionFailureReason: String, Hashable, Sendable, Codable {
    case permissionDenied
    case authenticationRequired
    case readOnly
    case unavailable
    case other
}

/// Why a row lives in the device-local removal ledger instead of being deleted
/// outright. It is persisted, so the recovery screen can explain each entry
/// long after the deletion attempt.
public enum SongLocalRemovalReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// The protocol exposes no delete operation at all — Subsonic-family
    /// servers, UPnP, the read-only catalogues.
    case sourceDoesNotSupportDeletion
    /// The server answered the delete with a refusal that a retry cannot fix
    /// until an administrator changes the share.
    case remoteDeletionDenied
    /// Deletion was available and the user deliberately kept the remote file.
    case userKeptRemoteFile
}

/// Device-local removal is the only way to get a row out of the library when
/// the source file cannot be deleted: an ordinary library delete would either
/// be impossible or be undone by the next scan.
public enum SongLocalRemovalPolicy {
    fileprivate static let segmentKeyPrefix = "\u{0}cue:"

    /// The scanner gives each CUE track its own stable ID, even when the file
    /// and the start time are shared (for example, tracks in a disc image).
    /// A NUL cannot occur in an actual source path.
    public static func segmentExclusionKey(for song: Song) -> String? {
        guard SourceFileDeletionPolicy.isFileSegment(song) else { return nil }
        return segmentKeyPrefix + TVScanPipelinePolicy.canonicalSongID(song.id)
    }

    /// Refusals where the file is known to stay put and retrying cannot help.
    /// Authentication failures, timeouts and unknown errors stay retry-only —
    /// the source may well delete the file on the next attempt.
    public static let deniedFailureReasons: Set<SourceFileDeletionFailureReason> = [
        .permissionDenied, .readOnly,
    ]

    /// Every configured source offers the fallback. A protocol with no delete
    /// verb and a mount whose account may not delete are the same situation to
    /// the person looking at the row: it cannot leave the library any other
    /// way, and the next scan would bring it straight back.
    public static func offersLocalRemoval(for sourceType: MusicSourceType?) -> Bool {
        sourceType != nil
    }

    /// Whether the delete action should be presented as "delete the file" or
    /// as "remove from this device".
    public static func canDeleteRemoteFile(for sourceType: MusicSourceType?) -> Bool {
        sourceType?.supportsFileDeletion == true
    }

    /// Reason to record when no remote deletion was attempted.
    public static func reasonWithoutRemoteDeletion(
        for sourceType: MusicSourceType?
    ) -> SongLocalRemovalReason {
        canDeleteRemoteFile(for: sourceType)
            ? .userKeptRemoteFile
            : .sourceDoesNotSupportDeletion
    }

    /// Whether a failed remote deletion may be resolved by dropping the row
    /// from this device only.
    public static func canResolveLocally(
        failureReasons: Set<SourceFileDeletionFailureReason>
    ) -> Bool {
        !failureReasons.isEmpty && failureReasons.isSubset(of: deniedFailureReasons)
    }

    public static func sorted(_ entries: [SongLocalRemovalEntry]) -> [SongLocalRemovalEntry] {
        entries.sorted { lhs, rhs in
            lhs.removedAt == rhs.removedAt
                ? lhs.song.id < rhs.song.id
                : lhs.removedAt > rhs.removedAt
        }
    }
}

/// One row the user dropped from this device while the source copy stayed in
/// place. The whole `Song` is retained so a restore does not have to wait for
/// the next scan, and so playlists and artwork overrides can still resolve it.
public struct SongLocalRemovalEntry: Codable, Sendable, Equatable, Identifiable {
    public var song: Song
    public var reason: SongLocalRemovalReason
    public var removedAt: Date
    /// Message captured from the refused deletion, when there was one.
    public var detail: String?

    public var id: String { song.id }
    public var sourceID: String { song.sourceID }

    public init(
        song: Song,
        reason: SongLocalRemovalReason,
        removedAt: Date = Date(),
        detail: String? = nil
    ) {
        self.song = song
        self.reason = reason
        self.removedAt = removedAt
        self.detail = detail
    }
}

/// The part of a `SongLocalRemovalEntry` that is not the song itself. Held
/// beside the retained catalogue so existing lookups keep working on plain
/// `Song` values.
public struct SongLocalRemovalMetadata: Codable, Sendable, Equatable {
    public var reason: SongLocalRemovalReason
    public var removedAt: Date
    public var detail: String?

    public init(
        reason: SongLocalRemovalReason,
        removedAt: Date = Date(),
        detail: String? = nil
    ) {
        self.reason = reason
        self.removedAt = removedAt
        self.detail = detail
    }
}

/// On-disk shape of the device-local removal ledger.
///
/// The file is deliberately outside `Snapshot`: it never reaches CloudKit, the
/// Apple TV payload or a portable snapshot, because "removed here" is a
/// statement about one device, not about the account.
public struct SongLocalRemovalLedger: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 4
    /// v2 files had exactly one producer — the duplicate-cleanup path, which
    /// removed rows precisely when a WebDAV share refused DELETE.
    public static let legacyReason = SongLocalRemovalReason.remoteDeletionDenied

    public var formatVersion: Int?
    public var identities: [String]
    /// Written beside `entries` so a downgraded build still finds the retained
    /// catalogue in the shape it knows how to read.
    public var retainedSongs: [Song]?
    /// v3. Carries the removal reason and timestamp behind each retained row.
    public var entries: [SongLocalRemovalEntry]?

    public init(
        formatVersion: Int? = SongLocalRemovalLedger.currentFormatVersion,
        identities: [String],
        retainedSongs: [Song]? = nil,
        entries: [SongLocalRemovalEntry]? = nil
    ) {
        self.formatVersion = formatVersion
        self.identities = identities
        self.retainedSongs = retainedSongs
        self.entries = entries
    }

    /// Writes both shapes from one list of entries.
    public init(identities: [String], entries: [SongLocalRemovalEntry]) {
        self.init(
            identities: identities,
            retainedSongs: entries.map(\.song),
            entries: entries
        )
    }

    public struct Resolved: Sendable, Equatable {
        public var songs: [String: Song]
        public var metadata: [String: SongLocalRemovalMetadata]

        public init(
            songs: [String: Song] = [:],
            metadata: [String: SongLocalRemovalMetadata] = [:]
        ) {
            self.songs = songs
            self.metadata = metadata
        }
    }

    /// `entries` wins where both shapes describe the same row; a v2 file
    /// contributes its retained songs under the legacy reason so no record is
    /// lost on the upgrade. A zero timestamp marks "recorded before the reason
    /// was", which the recovery screen renders without a date.
    public func resolved() -> Resolved {
        var songs = Dictionary(
            (retainedSongs ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var metadata: [String: SongLocalRemovalMetadata] = [:]
        for entry in entries ?? [] {
            songs[entry.song.id] = entry.song
            metadata[entry.song.id] = SongLocalRemovalMetadata(
                reason: entry.reason,
                removedAt: entry.removedAt,
                detail: entry.detail
            )
        }
        for id in songs.keys where metadata[id] == nil {
            metadata[id] = SongLocalRemovalMetadata(
                reason: Self.legacyReason,
                removedAt: Date(timeIntervalSince1970: 0)
            )
        }
        // A snapshot may describe a retained track using both forms of its
        // digest. Keep the actual removal date and a single restore entry.
        var idBySegment: [String: String] = [:]
        var redundantIDs: [String] = []
        for song in songs.values {
            guard let key = SongLocalRemovalPolicy.segmentExclusionKey(for: song) else { continue }
            if let other = idBySegment[key] {
                let oldDate = metadata[other]?.removedAt ?? .distantPast
                let newDate = metadata[song.id]?.removedAt ?? .distantPast
                if oldDate > newDate || (oldDate == newDate && other < song.id) {
                    redundantIDs.append(song.id)
                    continue
                }
                redundantIDs.append(other)
            }
            idBySegment[key] = song.id
        }
        for id in redundantIDs {
            songs[id] = nil
            metadata[id] = nil
        }
        return Resolved(songs: songs, metadata: metadata)
    }

    /// Older ledgers stored a whole-file key even when the user removed just
    /// one CUE track. Only narrow keys backed by a recoverable track record.
    public func resolvedIdentities(
        retainedSongs: [String: Song]? = nil, sourcePrefixes: [String: String]
    ) -> Set<String> {
        var keys = Set(identities)
        guard !keys.isEmpty else { return keys }
        let prefix = SongLocalRemovalPolicy.segmentKeyPrefix
        let savedSegments = keys.filter { $0.hasPrefix(prefix) }
        let retained = retainedSongs ?? resolved().songs
        if !savedSegments.isEmpty {
            keys.subtract(savedSegments)
            let recoverable = Set(retained.values.compactMap(SongLocalRemovalPolicy.segmentExclusionKey))
            for key in savedSegments {
                let canonical = prefix + TVScanPipelinePolicy.canonicalSongID(String(key.dropFirst(prefix.count)))
                if recoverable.contains(canonical) { keys.insert(canonical) }
            }
        }
        let aliasesOnly = (formatVersion ?? 0) >= Self.currentFormatVersion
        if aliasesOnly && sourcePrefixes.isEmpty { return keys }
        return Self.narrowingLegacySegmentExclusions(
            keys, retainedSongs: retained, sourcePrefixes: sourcePrefixes,
            unresolvedAccountAliasesOnly: aliasesOnly
        )
    }

    public static func narrowingLegacySegmentExclusions(
        _ identities: Set<String>, retainedSongs: [String: Song], sourcePrefixes: [String: String],
        unresolvedAccountAliasesOnly: Bool
    ) -> Set<String> {
        var result = identities
        var wholeFileKeys = Set<String>()
        var segmentFileKeys = Set<String>()
        for song in retainedSongs.values {
            let raw = "\(song.sourceID):\(song.filePath)"
            let canonical = "\(sourcePrefixes[song.sourceID] ?? song.sourceID):\(song.filePath)"
            guard result.contains(raw) || result.contains(canonical) else { continue }
            if let key = SongLocalRemovalPolicy.segmentExclusionKey(for: song) {
                // The v3 migration may have run before the account resolver
                // was installed. In that case only its account alias is left.
                if unresolvedAccountAliasesOnly && (!identities.contains(key) || identities.contains(raw)) {
                    continue
                }
                result.insert(key)
                segmentFileKeys.insert(raw)
                segmentFileKeys.insert(canonical)
            } else {
                wholeFileKeys.insert(raw)
                wholeFileKeys.insert(canonical)
            }
        }
        result.subtract(segmentFileKeys.subtracting(wholeFileKeys))
        return result
    }
}
