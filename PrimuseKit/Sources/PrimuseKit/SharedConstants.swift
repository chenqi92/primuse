import Foundation
import CoreFoundation

/// Encodes Foundation-style JSON objects without calling
/// `JSONSerialization.data(withJSONObject:)`.
///
/// The Objective-C writer can raise an `NSException` while bridging Swift
/// collections. `NSException` bypasses Swift `do/catch`, so callers cannot
/// recover even when they use `try` or `try?`. Converting the supported JSON
/// graph to an `Encodable` value first keeps failures in Swift's error model.
public enum SafeJSONSerialization {
    public static func data(
        withJSONObject object: Any,
        options: JSONSerialization.WritingOptions = []
    ) throws -> Data {
        let value = try JSONValue(object)
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = []
        if options.contains(.prettyPrinted) { formatting.insert(.prettyPrinted) }
        if options.contains(.sortedKeys) { formatting.insert(.sortedKeys) }
        if options.contains(.withoutEscapingSlashes) { formatting.insert(.withoutEscapingSlashes) }
        encoder.outputFormatting = formatting
        return try encoder.encode(value)
    }

    public struct UnsupportedValueError: LocalizedError, Sendable {
        public let typeName: String

        public var errorDescription: String? {
            "Unsupported JSON value of type \(typeName)"
        }
    }

    private enum JSONValue: Encodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case signedInteger(Int64)
        case unsignedInteger(UInt64)
        case number(Double)
        case bool(Bool)
        case null

        init(_ rawValue: Any) throws {
            let mirror = Mirror(reflecting: rawValue)
            if mirror.displayStyle == .optional {
                if let wrapped = mirror.children.first?.value {
                    self = try JSONValue(wrapped)
                } else {
                    self = .null
                }
                return
            }

            if rawValue is NSNull {
                self = .null
                return
            }

            // Swift numeric values bridge to NSNumber. Inspect the Core
            // Foundation type first because NSNumber(1) also casts to Bool.
            if let number = rawValue as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    self = .bool(number.boolValue)
                    return
                }
                let encoding = String(cString: number.objCType)
                switch encoding {
                case "C", "S", "I", "L", "Q":
                    self = .unsignedInteger(number.uint64Value)
                case "f", "d":
                    let value = number.doubleValue
                    guard value.isFinite else {
                        throw UnsupportedValueError(typeName: "non-finite number")
                    }
                    self = .number(value)
                default:
                    self = .signedInteger(number.int64Value)
                }
                return
            }

            if let string = rawValue as? String {
                self = .string(string)
                return
            }
            if let dictionary = rawValue as? [String: Any] {
                self = .object(try dictionary.mapValues(JSONValue.init))
                return
            }
            if let array = rawValue as? [Any] {
                self = .array(try array.map(JSONValue.init))
                return
            }
            if let dictionary = rawValue as? NSDictionary {
                var result: [String: JSONValue] = [:]
                for (key, value) in dictionary {
                    guard let key = key as? String else {
                        throw UnsupportedValueError(typeName: "non-string dictionary key")
                    }
                    result[key] = try JSONValue(value)
                }
                self = .object(result)
                return
            }
            if let array = rawValue as? NSArray {
                self = .array(try array.map(JSONValue.init))
                return
            }

            throw UnsupportedValueError(typeName: String(reflecting: type(of: rawValue)))
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .object(let values):
                var container = encoder.container(keyedBy: JSONKey.self)
                for (key, value) in values {
                    try container.encode(value, forKey: JSONKey(key))
                }
            case .array(let values):
                var container = encoder.unkeyedContainer()
                for value in values { try container.encode(value) }
            case .string(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .signedInteger(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .unsignedInteger(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .number(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .bool(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .null:
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }
    }

    private struct JSONKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }
}

public extension BinaryFloatingPoint {
    /// Converts a floating-point value to `Int` without allowing malformed
    /// metadata (`NaN`, infinity, or an out-of-range finite value) to trap.
    /// Callers can choose a domain-appropriate fallback; durations normally
    /// use zero so an invalid value is treated as unknown.
    func finiteInt(or fallback: Int = 0) -> Int {
        let value = Double(self)
        guard value.isFinite,
              value >= Double(Int.min),
              value < Double(Int.max) else {
            return fallback
        }
        return Int(value)
    }

    /// Converts a floating-point value to `UInt64` without trapping on
    /// negative, non-finite, or out-of-range timeout/configuration values.
    func finiteUInt64(or fallback: UInt64 = 0) -> UInt64 {
        let value = Double(self)
        guard value.isFinite,
              value >= 0,
              value < Double(UInt64.max) else {
            return fallback
        }
        return UInt64(value)
    }
}

public extension FileManager {
    /// Search-path APIs normally return one URL on Apple platforms, but using
    /// `.first!` turns an unusual container/filesystem failure into a process
    /// trap. Temporary storage is a safe last-resort location for startup.
    func primuseDirectoryURL(for directory: SearchPathDirectory) -> URL {
        urls(for: directory, in: .userDomainMask).first ?? temporaryDirectory
    }
}

/// Resolves an absolute file path persisted inside an older iOS app-data
/// container. Reinstalling an app changes the container UUID while restored
/// Application Support, Caches and Documents content keeps the same relative
/// location. Only known Primuse-owned roots are rebased, and a URL is returned
/// only when the direct or rebased target exists.
public enum PrimuseSandboxPathResolver {
    public static func existingURL(
        forStoredAbsolutePath storedPath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard storedPath.hasPrefix("/") else { return nil }

        let directURL = URL(fileURLWithPath: storedPath).standardizedFileURL
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        let roots: [(marker: String, currentRoot: URL)] = [
            (
                "/Library/Application Support/Primuse/",
                fileManager
                    .primuseDirectoryURL(for: .applicationSupportDirectory)
                    .appendingPathComponent("Primuse", isDirectory: true)
            ),
            (
                "/Library/Caches/Primuse/",
                fileManager
                    .primuseDirectoryURL(for: .cachesDirectory)
                    .appendingPathComponent("Primuse", isDirectory: true)
            ),
            (
                "/Documents/LocalMusic/",
                fileManager
                    .primuseDirectoryURL(for: .documentDirectory)
                    .appendingPathComponent("LocalMusic", isDirectory: true)
            ),
        ]

        for root in roots {
            guard let markerRange = storedPath.range(of: root.marker) else { continue }
            let relativePath = String(storedPath[markerRange.upperBound...])
            let standardizedRoot = root.currentRoot.standardizedFileURL
            let candidate = relativePath.isEmpty
                ? standardizedRoot
                : standardizedRoot.appendingPathComponent(relativePath).standardizedFileURL
            let rootPrefix = standardizedRoot.path.hasSuffix("/")
                ? standardizedRoot.path
                : standardizedRoot.path + "/"
            guard (candidate.path == standardizedRoot.path || candidate.path.hasPrefix(rootPrefix)),
                  fileManager.fileExists(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }
}

public enum SafeByteRange {
    /// Returns the exclusive end for a non-negative byte range, or `nil`
    /// when the range is empty, negative, or would overflow `Int64`.
    public static func exclusiveEnd(offset: Int64, length: Int64) -> Int64? {
        guard offset >= 0, length > 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, end > offset else { return nil }
        return end
    }

    /// RFC 7233 Range header. Negative offsets use suffix-range syntax.
    public static func httpHeader(offset: Int64, length: Int64) -> String? {
        guard length > 0 else { return nil }
        if offset < 0 { return "bytes=\(offset)" }
        guard let end = exclusiveEnd(offset: offset, length: length) else { return nil }
        return "bytes=\(offset)-\(end - 1)"
    }
}

public enum PrimuseConstants {
    public static let appGroupIdentifier = "group.com.welape.yuanyin"
    public static let playbackStateKey = "playbackState"
    public static let keychainServiceName = "com.welape.primuse.credentials"

    // Widget shared snapshots (App Group). Written by the main app, read by
    // the WidgetKit extension. Keys also double as the @AppStorage keys the
    // settings UI binds to (sync toggle / refresh mode) so both sides agree.
    public static let lyricsSnapshotKey = "widget.lyricsSnapshot"
    public static let listeningStatsKey = "widget.listeningStats"
    public static let sourcesSnapshotKey = "widget.sourcesSnapshot"
    public static let wrappedSnapshotKey = "widget.wrappedSnapshot"
    public static let widgetSyncEnabledKey = "widget.syncEnabled"
    public static let widgetRefreshModeKey = "widget.refreshMode"
    public static let widgetSharedDataScopeKey = "widget.sharedDataScope"
    public static let widgetClickableInteractionKey = "widget.clickableInteraction"
    public static let widgetNowPlayingEnabledKey = "widget.enabled.nowPlaying"
    public static let widgetLyricsEnabledKey = "widget.enabled.lyrics"
    public static let widgetListeningStatsEnabledKey = "widget.enabled.listeningStats"
    public static let widgetRecentAlbumsEnabledKey = "widget.enabled.recentAlbums"
    public static let widgetSourcesEnabledKey = "widget.enabled.sources"
    public static let widgetWrappedEnabledKey = "widget.enabled.wrapped"

    public static let eqBandFrequencies: [Float] = [
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]
    public static let eqBandCount = 10
    public static let eqMinGain: Float = -12.0
    public static let eqMaxGain: Float = 12.0
    public static let eqDefaultBandwidth: Float = 1.0

    public static let defaultCacheSizeBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB
    public static let smallFileThreshold: Int64 = 50 * 1024 * 1024 // 50 MB

    public static let supportedCoverExtensions = ["jpg", "jpeg", "png", "webp"]
    public static let supportedLyricsExtensions = ["lrc"]
    public static let supportedMusicVideoExtensions = ["mp4", "m4v", "mov"]
    public static let folderCoverNames = ["cover", "folder", "album", "front", "artwork"]

    /// Note: `.mp4` is intentionally excluded — it's primarily a video
    /// container, and the SFB AAC-in-MP4 decoder is unreliable for the
    /// kind of mp4 a user typically drops in their music folder (often
    /// extracted-from-video files with non-standard atom layout). Audio
    /// MP4 files should use `.m4a`. Including `.mp4` here led to mid-stream
    /// PCM decode errors that auto-skipped 25%+ of cloud-drive scans.
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "flac", "wav", "aiff", "aif", "au", "snd", "caf", "alac",
        "ape", "dsf", "dff", "ogg", "opus", "wma", "asf", "wv", "dts", "dtshd", "dts-hd",
        "ac3", "eac3", "ec3", "mlp", "truehd", "thd", "amr", "awb",
        "atrac", "oma", "aa3", "at3", "tak", "tta", "mpc", "mpp", "shn", "speex", "spx", "qoa"
    ]

    /// CUE sheets are library descriptors rather than playable files. Source
    /// scanners enumerate them separately and expand their INDEX 01 entries
    /// into virtual Song rows that all point at the referenced audio image.
    public static let supportedCueSheetExtensions: Set<String> = ["cue"]
}

/// Stable identifiers shared by the app targets and the Apple Music adapter.
///
/// `MusicLibrary` is also compiled into the tvOS target, while the concrete
/// MusicKit-backed service is not. Keeping these values in PrimuseKit prevents
/// the shared library model from depending on a platform-specific service.
public enum AppleMusicLibraryIdentity {
    public static let sourceID = "primuse.appleMusic.system"
    public static let systemPlaylistID = "primuse.system.appleMusicLibrary"
    public static let userPlaylistIDPrefix = "primuse.system.appleMusic.playlist."

    public static func isMirrorPlaylist(_ playlistID: String) -> Bool {
        playlistID == systemPlaylistID
            || playlistID.hasPrefix(userPlaylistIDPrefix)
    }
}

/// Platform-neutral identity used to reconcile the two IDs MusicKit exposes
/// for the same Apple Music track: a user-library ID (`i.*`) and a catalog ID.
public struct AppleMusicTrackIdentity: Sendable, Equatable {
    public let itemID: String
    public let alternateIDs: Set<String>
    public let title: String
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?

    public init(
        itemID: String,
        alternateIDs: Set<String> = [],
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.itemID = itemID
        self.alternateIDs = alternateIDs
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// Resolves a MusicKit playback item back to the canonical user-library item.
/// ID overlap is authoritative; normalized metadata is a conservative fallback
/// for MusicKit responses whose `PlayParameters` omit the catalog identifier.
public enum AppleMusicTrackIdentityResolver {
    public static func canonicalID(
        for playback: AppleMusicTrackIdentity,
        in library: [AppleMusicTrackIdentity]
    ) -> String? {
        guard !library.isEmpty else { return nil }

        let playbackIDs = playback.alternateIDs.union([playback.itemID])
        let exact = library.filter {
            !$0.alternateIDs.union([$0.itemID]).isDisjoint(with: playbackIDs)
        }
        if exact.count == 1 { return exact[0].itemID }

        let normalizedTitle = normalize(playback.title)
        guard !normalizedTitle.isEmpty else { return nil }
        let titleMatches = library.filter { normalize($0.title) == normalizedTitle }
        guard !titleMatches.isEmpty else { return nil }

        let ranked = titleMatches.map { candidate in
            (candidate.itemID, metadataScore(playback: playback, candidate: candidate))
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0 < $1.0
        }

        guard let best = ranked.first, best.1 >= 4 else { return nil }
        if ranked.count > 1, ranked[1].1 == best.1 { return nil }
        return best.0
    }

    private static func metadataScore(
        playback: AppleMusicTrackIdentity,
        candidate: AppleMusicTrackIdentity
    ) -> Int {
        var score = 0

        let playbackArtist = normalize(playback.artist)
        let candidateArtist = normalize(candidate.artist)
        if !playbackArtist.isEmpty, playbackArtist == candidateArtist { score += 5 }

        let playbackAlbum = normalize(playback.album)
        let candidateAlbum = normalize(candidate.album)
        if !playbackAlbum.isEmpty, playbackAlbum == candidateAlbum { score += 3 }

        if let lhs = playback.duration, lhs > 0,
           let rhs = candidate.duration, rhs > 0 {
            let delta = abs(lhs - rhs)
            if delta <= 0.75 {
                score += 4
            } else if delta <= 2.5 {
                score += 3
            }
        }

        return score
    }

    private static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// Whether an Apple Music response is a complete cloud snapshot or merely the
/// local-device fallback. Only a complete snapshot may prune songs/playlists.
public enum AppleMusicLibrarySyncMode: Sendable, Equatable {
    case authoritative
    case partialFallback

    public var shouldPruneMissingSongs: Bool { self == .authoritative }
    public var shouldReplaceMirrorPlaylist: Bool { self == .authoritative }
}

/// Preferences that affect the platform-neutral music-library projection.
///
/// The Apple Music settings UI and the shared library model must read the same
/// key. This lives outside the MusicKit implementation so macOS/iOS and tvOS
/// can all compile the shared model without target-membership assumptions.
public enum AppleMusicLibraryPreferences {
    public static let syncUserLibraryKey = "primuse.appleMusic.syncUserLibrary"

    public static var syncUserLibraryEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: syncUserLibraryKey) != nil else { return true }
        return defaults.bool(forKey: syncUserLibraryKey)
    }
}

/// Pure policy for deciding whether a MusicKit queue snapshot may replace
/// Primuse's canonical playback queue.
public enum AppleMusicQueueMirrorPolicy {
    public static func isActiveSession(
        sessionGeneration: UInt64,
        activeGeneration: UInt64,
        isCancelled: Bool
    ) -> Bool {
        sessionGeneration == activeGeneration && !isCancelled
    }

    public static func shouldApplySnapshot(
        sessionGeneration: UInt64,
        activeGeneration: UInt64,
        isCancelled: Bool,
        primuseOwnsCanonicalQueue: Bool,
        snapshotCount: Int
    ) -> Bool {
        isActiveSession(
            sessionGeneration: sessionGeneration,
            activeGeneration: activeGeneration,
            isCancelled: isCancelled
        )
            && !primuseOwnsCanonicalQueue
            && snapshotCount > 0
    }
}

/// Decides whether MusicKit or Primuse owns the ordering for an Apple Music
/// item. Any item selected from Primuse's visible queue must remain
/// Primuse-managed, including queues made entirely of Apple Music songs.
public enum AppleMusicQueueOwnershipPolicy {
    public static func shouldUsePrimuseQueue(
        selectedQueueEntryMatches: Bool
    ) -> Bool {
        selectedQueueEntryMatches
    }
}

/// Distinguishes Apple Music catalog playback from the two kinds of items that
/// can appear in the user's Music library. A library row is not automatically
/// subscription-independent: an Apple Music catalog item can remain in the
/// library after the subscription expires.
public enum AppleMusicPlaybackSource: Sendable, Equatable {
    case catalog
    case catalogBackedUserLibrary
    case subscriptionIndependentUserLibrary
}

/// Resolves the opaque identifiers MusicKit supplies for a `Song` into the
/// narrowest safe playback source. Library IDs use the `i.` namespace; an
/// additional catalog/global ID means the row still represents catalog
/// content and must retain the no-subscription crash guard.
public enum AppleMusicPlaybackSourceResolver {
    public static func resolve(
        itemID: String,
        explicitCatalogIDs: Set<String>,
        genericPlayParameterIDs: Set<String>
    ) -> AppleMusicPlaybackSource {
        guard itemID.hasPrefix("i.") else { return .catalog }

        if explicitCatalogIDs.contains(where: { !$0.isEmpty }) {
            return .catalogBackedUserLibrary
        }

        let hasAlternateCatalogID = genericPlayParameterIDs.contains { candidate in
            !candidate.isEmpty && candidate != itemID && !candidate.hasPrefix("i.")
        }
        return hasAlternateCatalogID
            ? .catalogBackedUserLibrary
            : .subscriptionIndependentUserLibrary
    }
}

/// `MusicSubscription.canPlayCatalogContent` only describes catalog
/// privileges. Keep the guard for both catalog search results and catalog
/// items retained in the library, while allowing confirmed library-only items
/// such as locally imported files to reach ApplicationMusicPlayer.
public enum AppleMusicSubscriptionGatePolicy {
    public static func requiresCatalogCapability(
        for source: AppleMusicPlaybackSource
    ) -> Bool {
        source != .subscriptionIndependentUserLibrary
    }
}

/// Pure policy for recognizing the end of a MusicKit track.
///
/// `ApplicationMusicPlayer` does not consistently settle on `.stopped`: some
/// OS versions pause and reset `playbackTime`, while others remain `.playing`
/// with a frozen clock. Callers therefore retain the furthest observed time and
/// use a short stall watchdog near the reported duration.
public enum AppleMusicPlaybackEndPolicy {
    public static func isNearEnd(
        duration: TimeInterval,
        playbackTime: TimeInterval,
        furthestObservedTime: TimeInterval
    ) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        let tolerance = min(5, max(1.5, duration * 0.02))
        let observedTime = max(playbackTime, furthestObservedTime)
        return observedTime >= max(0, duration - tolerance)
    }

    public static func shouldAdvance(
        hasObservedActivePlayback: Bool,
        isStopped: Bool,
        isPaused: Bool,
        wasPausedByUser: Bool,
        isPlaybackInterrupted: Bool,
        isNearEnd: Bool,
        stalledNearEndSampleCount: Int,
        stallSampleThreshold: Int
    ) -> Bool {
        guard hasObservedActivePlayback else { return false }
        if isPlaybackInterrupted { return false }
        if isStopped { return true }
        if isPaused && !wasPausedByUser && isNearEnd { return true }
        return isNearEnd
            && stallSampleThreshold > 0
            && stalledNearEndSampleCount >= stallSampleThreshold
    }
}

/// Versioned persistence for the Library/Home quick-access selection.
///
/// Version 1 stored a bare array and rendered Liked Songs outside that array,
/// which meant it could neither be hidden nor reordered. Version 2 stores the
/// complete ordered selection, including Liked Songs. Decoding a legacy array
/// prepends the supplied default pin once, preserving the old visible result.
public enum QuickAccessPinKind: String, Codable, Sendable {
    case album, artist, playlist
}

public struct QuickAccessPinReference: Codable, Hashable, Identifiable, Sendable {
    public let kind: QuickAccessPinKind
    public let itemID: String

    public init(kind: QuickAccessPinKind, itemID: String) {
        self.kind = kind
        self.itemID = itemID
    }

    public var id: String { "\(kind.rawValue):\(itemID)" }
}

public enum QuickAccessPinStorageCodec {
    private struct Envelope: Codable {
        let version: Int
        let pins: [QuickAccessPinReference]
    }

    public static func decode(
        _ rawValue: String,
        defaultPins: [QuickAccessPinReference],
        maximumCount: Int
    ) -> [QuickAccessPinReference] {
        guard maximumCount > 0 else { return [] }
        guard !rawValue.isEmpty, let data = rawValue.data(using: .utf8) else {
            return normalized(defaultPins, maximumCount: maximumCount)
        }

        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.version >= 2 {
            return normalized(envelope.pins, maximumCount: maximumCount)
        }

        if let legacyPins = try? JSONDecoder().decode([QuickAccessPinReference].self, from: data) {
            return normalized(defaultPins + legacyPins, maximumCount: maximumCount)
        }

        return normalized(defaultPins, maximumCount: maximumCount)
    }

    public static func encode(
        _ pins: [QuickAccessPinReference],
        maximumCount: Int
    ) -> String {
        let envelope = Envelope(
            version: 2,
            pins: normalized(pins, maximumCount: maximumCount)
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalized(
        _ pins: [QuickAccessPinReference],
        maximumCount: Int
    ) -> [QuickAccessPinReference] {
        var seen = Set<QuickAccessPinReference>()
        var result: [QuickAccessPinReference] = []
        result.reserveCapacity(min(pins.count, maximumCount))
        for pin in pins where seen.insert(pin).inserted {
            result.append(pin)
            if result.count == maximumCount { break }
        }
        return result
    }
}

/// Picks songs that may extend an exhausted shuffle round. Existing queue IDs
/// and duplicates in the library snapshot are excluded so an expansion never
/// immediately replays the just-finished track or inflates the queue.
public enum ShuffleContinuationPolicy {
    public static func candidateIDs(
        queueIDs: [String],
        libraryIDs: [String],
        currentID: String?
    ) -> [String] {
        var excluded = Set(queueIDs)
        if let currentID { excluded.insert(currentID) }
        var emitted = Set<String>()
        return libraryIDs.filter { id in
            !id.isEmpty && !excluded.contains(id) && emitted.insert(id).inserted
        }
    }
}

/// Decides whether a manual "next" command is allowed to start another
/// decode. A one-song, repeat-off queue has no successor; treating modulo 1
/// as an advance only downloads and restarts the same remote file.
public enum ManualQueueAdvancePolicy {
    public static func shouldAdvance(
        queueCount: Int,
        repeatMode: RepeatMode,
        shuffleEnabled: Bool,
        hasSuccessor: Bool
    ) -> Bool {
        guard queueCount > 0 else { return false }
        guard queueCount == 1, repeatMode == .off else { return true }
        return shuffleEnabled && hasSuccessor
    }
}

/// Shared predicate for the background metadata pipeline. A scanner can mark
/// only the title inspection as complete while still leaving duration or MP3
/// artwork work eligible for backfill.
public enum MetadataBackfillEligibilityPolicy {
    public static func needsBackfill(
        duration: TimeInterval,
        format: AudioFormat,
        hasCoverArt: Bool,
        artworkGivenUp: Bool,
        titleChecked: Bool
    ) -> Bool {
        duration <= 0
            || (format == .mp3 && !hasCoverArt && !artworkGivenUp)
            || !titleChecked
    }
}

/// Protects the identity supplied by a CUE sheet when metadata is scraped from
/// the shared physical audio file. A forced scrape may replace ordinary-track
/// text, but it must not collapse every virtual segment to one file-level name.
public enum ScrapeCueIdentityPolicy {
    public static func resolvedTitle(
        original: String,
        scraped: String,
        isCueTrack: Bool
    ) -> String {
        guard isCueTrack, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return scraped
        }
        return original
    }

    public static func resolvedOptionalText(
        original: String?,
        scraped: String?,
        isCueTrack: Bool
    ) -> String? {
        guard isCueTrack,
              let original,
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return scraped
        }
        return original
    }
}

/// Prevents metadata scraping from materializing an entire remote audio file
/// merely to establish a search identity. Range-capable sources already feed
/// embedded tags through metadata backfill; formats that require a complete
/// local file should only download that file when the user actually plays or
/// explicitly caches it.
public enum ScrapeAudioMaterializationPolicy {
    public static func shouldResolvePlaybackURL(
        sourceSupportsRangeStreaming: Bool,
        formatRequiresCompleteLocalFile: Bool
    ) -> Bool {
        !(sourceSupportsRangeStreaming && formatRequiresCompleteLocalFile)
    }
}

/// Decides how a trusted, confidence-checked online scrape candidate is
/// applied to the library seed. Background enrichment keeps its conservative
/// fill-only contract, while an explicit rescrape may replace known catalog
/// fields. Empty provider values never erase local metadata in either mode.
public enum ScrapeMetadataApplicationPolicy {
    public static func shouldRequestMetadata(
        fieldsAreMissing: Bool,
        forceRefresh: Bool
    ) -> Bool {
        fieldsAreMissing || forceRefresh
    }

    public static func resolvedText(
        original: String?,
        scraped: String?,
        overwrite: Bool
    ) -> String? {
        let candidate = scraped?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else { return original }

        let existing = original?.trimmingCharacters(in: .whitespacesAndNewlines)
        if overwrite || existing?.isEmpty != false {
            return candidate
        }
        return original
    }

    public static func resolvedValue<Value>(
        original: Value?,
        scraped: Value?,
        overwrite: Bool
    ) -> Value? {
        if overwrite {
            return scraped ?? original
        }
        return original ?? scraped
    }
}

/// A deterministic rank for manual scrape candidates. Title compatibility is
/// the identity gate; when the library song has a reliable duration, close
/// known durations come next, unknown durations follow, and clearly mismatched
/// durations are last. This prevents a provider that omits duration from
/// receiving an artificially perfect score by shrinking the score denominator.
public struct ScrapeCandidateRank: Sendable, Equatable {
    public enum DurationTier: Int, Sendable, Equatable {
        case close = 0
        case unknown = 1
        case mismatch = 2
        case unavailable = 3
    }

    public let confidence: Double
    public let titleMatchLevel: Int
    public let artistMatchLevel: Int
    public let durationTier: DurationTier
    public let durationDeltaMs: Int?
}

public enum ScrapeCandidateRankingPolicy {
    public static func rank(
        requestedTitle: String,
        requestedArtist: String?,
        targetDurationMs: Int?,
        candidateTitle: String,
        candidateArtist: String?,
        candidateDurationMs: Int?
    ) -> ScrapeCandidateRank {
        let titleMatchLevel = textMatchLevel(
            requested: requestedTitle,
            candidate: candidateTitle
        )
        let artistMatchLevel = textMatchLevel(
            requested: requestedArtist,
            candidate: candidateArtist
        )

        var score = 0.0
        var maximumScore = 30.0
        score += titleMatchLevel == 2 ? 30 : (titleMatchLevel == 1 ? 15 : 0)

        let normalizedRequestedArtist = normalized(requestedArtist)
        if !normalizedRequestedArtist.isEmpty {
            maximumScore += 20
            score += artistMatchLevel == 2 ? 20 : (artistMatchLevel == 1 ? 10 : 0)
        }

        let validTargetMs = targetDurationMs.flatMap { $0 > 0 ? $0 : nil }
        let validCandidateMs = candidateDurationMs.flatMap { $0 > 0 ? $0 : nil }
        let durationTier: ScrapeCandidateRank.DurationTier
        let durationDeltaMs: Int?
        if let targetMs = validTargetMs {
            maximumScore += 50
            if let candidateMs = validCandidateMs {
                let delta = abs(candidateMs - targetMs)
                durationDeltaMs = delta
                if delta < 2_000 {
                    score += 50
                } else if delta < 5_000 {
                    score += 30
                } else if delta < 10_000 {
                    score += 10
                } else {
                    score -= 20
                }
                durationTier = delta < 10_000 ? .close : .mismatch
            } else {
                durationDeltaMs = nil
                durationTier = .unknown
            }
        } else {
            durationDeltaMs = nil
            durationTier = .unavailable
        }

        let confidence = maximumScore > 0
            ? max(0, min(1, score / maximumScore))
            : 0
        return ScrapeCandidateRank(
            confidence: confidence,
            titleMatchLevel: titleMatchLevel,
            artistMatchLevel: artistMatchLevel,
            durationTier: durationTier,
            durationDeltaMs: durationDeltaMs
        )
    }

    public static func isPreferred(
        _ lhs: ScrapeCandidateRank,
        over rhs: ScrapeCandidateRank
    ) -> Bool {
        let lhsTitleCompatible = lhs.titleMatchLevel > 0
        let rhsTitleCompatible = rhs.titleMatchLevel > 0
        if lhsTitleCompatible != rhsTitleCompatible {
            return lhsTitleCompatible
        }

        if lhsTitleCompatible {
            if lhs.durationTier != rhs.durationTier {
                return lhs.durationTier.rawValue < rhs.durationTier.rawValue
            }
            if let lhsDelta = lhs.durationDeltaMs,
               let rhsDelta = rhs.durationDeltaMs,
               lhsDelta != rhsDelta {
                return lhsDelta < rhsDelta
            }
            if lhs.artistMatchLevel != rhs.artistMatchLevel {
                return lhs.artistMatchLevel > rhs.artistMatchLevel
            }
            if lhs.titleMatchLevel != rhs.titleMatchLevel {
                return lhs.titleMatchLevel > rhs.titleMatchLevel
            }
        }

        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        return false
    }

    private static func textMatchLevel(
        requested: String?,
        candidate: String?
    ) -> Int {
        let requestedText = normalized(requested)
        let candidateText = normalized(candidate)
        guard !requestedText.isEmpty, !candidateText.isEmpty else { return 0 }
        if requestedText == candidateText { return 2 }
        if requestedText.contains(candidateText) || candidateText.contains(requestedText) {
            return 1
        }
        return 0
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

/// Reads the fixed-size RIFF/WAVE headers that are available in a remote
/// file's initial byte range. The `data` chunk advertises its complete byte
/// count even when the provided `Data` contains only a small prefix, so this
/// avoids treating a 256 KB metadata Range response as the whole song.
public enum WAVEHeaderParser {
    public struct AudioInfo: Equatable, Sendable {
        public let duration: TimeInterval
        public let sampleRate: Int
        public let bitRateKbps: Int
        public let bitDepth: Int
        public let channelCount: Int

        public init(
            duration: TimeInterval,
            sampleRate: Int,
            bitRateKbps: Int,
            bitDepth: Int,
            channelCount: Int
        ) {
            self.duration = duration
            self.sampleRate = sampleRate
            self.bitRateKbps = bitRateKbps
            self.bitDepth = bitDepth
            self.channelCount = channelCount
        }
    }

    public static func parse(_ data: Data) -> AudioInfo? {
        guard data.count >= 12,
              ascii(data, at: 0) == "RIFF",
              ascii(data, at: 8) == "WAVE" else {
            return nil
        }

        var cursor = 12
        var sampleRate: UInt32?
        var byteRate: UInt32?
        var bitDepth: UInt16?
        var channelCount: UInt16?
        var audioByteCount: UInt32?

        while cursor <= data.count - 8 {
            guard let chunkSize = littleEndianUInt32(data, at: cursor + 4) else { break }
            let chunkID = ascii(data, at: cursor)
            let payloadStart = cursor + 8

            if chunkID == "fmt ", chunkSize >= 16, payloadStart <= data.count - 16 {
                channelCount = littleEndianUInt16(data, at: payloadStart + 2)
                sampleRate = littleEndianUInt32(data, at: payloadStart + 4)
                byteRate = littleEndianUInt32(data, at: payloadStart + 8)
                bitDepth = littleEndianUInt16(data, at: payloadStart + 14)
            } else if chunkID == "data" {
                audioByteCount = chunkSize
                break
            }

            let paddedSize = UInt64(chunkSize) + UInt64(chunkSize & 1)
            let next = UInt64(payloadStart) + paddedSize
            guard next <= UInt64(data.count), next <= UInt64(Int.max) else { break }
            cursor = Int(next)
        }

        guard let sampleRate, sampleRate > 0,
              let byteRate, byteRate > 0,
              let bitDepth, bitDepth > 0,
              let channelCount, channelCount > 0,
              let audioByteCount, audioByteCount > 0 else {
            return nil
        }

        let duration = Double(audioByteCount) / Double(byteRate)
        guard duration.isFinite, duration > 0 else { return nil }

        return AudioInfo(
            duration: duration,
            sampleRate: Int(sampleRate),
            bitRateKbps: (Double(byteRate) * 8.0 / 1000.0).rounded().finiteInt(),
            bitDepth: Int(bitDepth),
            channelCount: Int(channelCount)
        )
    }

    private static func ascii(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii)
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

/// Detects a JPEG sampling layout that some FFmpeg encoders emit and Apple
/// ImageIO cannot decode reliably (`decodeImageImp failed - NULL _blockArray`).
/// The check parses only JPEG marker headers, so callers can reject or replace
/// the data without first triggering ImageIO's decoder.
public enum ArtworkImageCompatibility {
    public static func hasRedundantJPEGSampling(_ data: Data) -> Bool {
        guard data.count >= 12, data[0] == 0xFF, data[1] == 0xD8 else { return false }
        var marker = 2
        while marker + 3 < data.count {
            guard data[marker] == 0xFF else {
                marker += 1
                continue
            }
            while marker < data.count, data[marker] == 0xFF { marker += 1 }
            guard marker < data.count else { return false }
            let code = data[marker]
            marker += 1
            if code == 0xD9 || code == 0xDA { return false }
            if code == 0x01 || (0xD0...0xD7).contains(code) { continue }
            guard marker + 1 < data.count else { return false }
            let length = Int(data[marker]) << 8 | Int(data[marker + 1])
            guard length >= 2, marker + length <= data.count else { return false }

            if [0xC0, 0xC1, 0xC2].contains(code) {
                let payload = marker + 2
                guard payload + 6 <= data.count else { return false }
                let componentCount = Int(data[payload + 5])
                guard componentCount > 1,
                      payload + 6 + componentCount * 3 <= marker + length else {
                    return false
                }
                let samples = (0..<componentCount).map { data[payload + 7 + $0 * 3] }
                return samples.allSatisfy { $0 == samples[0] } && samples[0] != 0x11
            }
            marker += length
        }
        return false
    }
}

/// Validates the non-query portion of an OAuth callback URL.
///
/// Providers that redirect straight back to the app must return the registered
/// custom URL exactly (scheme/host are case-insensitive; path is not). Providers
/// that use an HTTPS relay can only be checked against the custom scheme because
/// their registered HTTPS URL differs from the deep link emitted by the relay.
public enum OAuthCallbackURLMatcher {
    public static func matches(
        _ callbackURL: URL,
        registeredRedirectURI: String,
        callbackScheme: String
    ) -> Bool {
        guard
            let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let actualScheme = callback.scheme?.lowercased(),
            actualScheme == callbackScheme.lowercased(),
            let registered = URLComponents(string: registeredRedirectURI),
            let registeredScheme = registered.scheme?.lowercased(),
            callback.user == nil,
            callback.password == nil,
            registered.user == nil,
            registered.password == nil
        else {
            return false
        }

        // An HTTPS relay ultimately emits a different custom URL. Preserve the
        // existing scheme-only behavior for that flow.
        guard registeredScheme == callbackScheme.lowercased() else {
            return true
        }

        return registeredScheme == actualScheme
            && registered.host?.lowercased() == callback.host?.lowercased()
            && registered.port == callback.port
            && registered.percentEncodedPath == callback.percentEncodedPath
    }
}
