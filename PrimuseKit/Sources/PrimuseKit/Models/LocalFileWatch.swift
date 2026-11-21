import Foundation

// MARK: - Path spellings

/// The same local file can reach the app under several spellings: a bookmark
/// may resolve to `/var/…` while file events say `/private/var/…`, the Data
/// volume is reachable as `/System/Volumes/Data/Users/…` and `/Users/…`, names
/// can be stored composed or decomposed, and a case-insensitive volume accepts
/// any letter case. Watched roots and event paths are compared through these
/// helpers so none of those differences hides a change.
public enum LocalFileWatchPath {
    private static let privateAliases: Set<String> = ["var", "tmp", "etc"]

    /// Components of an absolute path with `.`/`..` applied and the firmlink
    /// and `/private` alias prefixes removed.
    public static func components(_ path: String) -> [String] {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        guard path.hasPrefix("/") else { return parts }
        if parts.count >= 3, parts[0] == "System", parts[1] == "Volumes", parts[2] == "Data" {
            parts.removeFirst(3)
        }
        if parts.count >= 2, parts[0] == "private", privateAliases.contains(parts[1]) {
            parts.removeFirst()
        }
        return parts
    }

    /// One spelling per file, usable as a dictionary key or log fingerprint.
    public static func key(_ path: String) -> String {
        ("/" + components(path).joined(separator: "/")).precomposedStringWithCanonicalMapping
    }

    /// `key` for comparisons that ignore letter case.
    public static func caseFoldedKey(_ path: String) -> String {
        key(path).folding(options: [.caseInsensitive], locale: nil)
    }

    /// The part of `item` below `root`, in the item's own spelling: an empty
    /// string for the root itself, nil when `item` is outside it. Exact
    /// (canonically equivalent) components are tried first, then a
    /// case-insensitive comparison when allowed.
    public static func relativePath(
        of item: String,
        under root: String,
        allowsCaseInsensitiveMatch: Bool = true
    ) -> String? {
        let rootParts = components(root)
        let itemParts = components(item)
        guard itemParts.count >= rootParts.count else { return nil }
        let pairs = zip(rootParts, itemParts)
        let exact = pairs.allSatisfy { lhs, rhs in lhs == rhs }
        let matches = exact || (allowsCaseInsensitiveMatch && pairs.allSatisfy { lhs, rhs in
            lhs.compare(rhs, options: [.caseInsensitive]) == .orderedSame
        })
        guard matches else { return nil }
        return itemParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    /// Which alias prefix an unmatched event path used, for diagnostics.
    public static func aliasForm(_ path: String) -> String {
        if path.hasPrefix("/System/Volumes/Data/") { return "data-volume" }
        if path.hasPrefix("/private/") { return "private" }
        // Swift's == treats both Unicode forms as equal; compare the scalars.
        if !path.unicodeScalars.elementsEqual(path.precomposedStringWithCanonicalMapping.unicodeScalars) {
            return "decomposed"
        }
        return "plain"
    }
}

// MARK: - Event classification

/// File-event flags the watcher cares about, independent of the platform API.
public struct LocalFileEventFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let created = Self(rawValue: 1 << 0)
    public static let removed = Self(rawValue: 1 << 1)
    public static let renamed = Self(rawValue: 1 << 2)
    public static let modified = Self(rawValue: 1 << 3)
    public static let inodeMetadataChanged = Self(rawValue: 1 << 4)
    public static let extendedAttributesChanged = Self(rawValue: 1 << 5)
    public static let cloned = Self(rawValue: 1 << 6)
    public static let isDirectory = Self(rawValue: 1 << 7)
    /// The system coalesced changes below this path or the watched root moved.
    public static let mustRescan = Self(rawValue: 1 << 8)
    /// The system dropped events; nothing below the watched roots can be trusted.
    public static let eventsDropped = Self(rawValue: 1 << 9)
}

public enum LocalFileEventDisposition: Equatable, Sendable {
    case ignore
    case rescanAll
    case rescanItem
    /// Read the file again even when size and dates look unchanged.
    case fileContentChanged
    /// Compare the file's size and dates first; read only when they differ.
    case fileAttributesChanged
    case fileRemoved
    case folderContentsChanged
    case folderMoved
}

public enum LocalFileEventClassifier {
    /// `existsNow` is asked only for rename and removal events.
    public static func disposition(
        for flags: LocalFileEventFlags,
        name: String,
        existsNow: () -> Bool
    ) -> LocalFileEventDisposition {
        if flags.contains(.eventsDropped) { return .rescanAll }
        if flags.contains(.mustRescan) { return .rescanItem }
        guard !name.hasPrefix(".") else { return .ignore }
        if flags.contains(.isDirectory) {
            if !flags.isDisjoint(with: [.removed, .renamed]) { return .folderMoved }
            if !flags.isDisjoint(with: [.created, .modified, .inodeMetadataChanged]) { return .folderContentsChanged }
            return .ignore
        }
        if !flags.isDisjoint(with: [.removed, .renamed]) {
            // Editors and iCloud land a new version by renaming it over the old
            // file; the path then still holds a file whose content changed.
            return existsNow() ? .fileContentChanged : .fileRemoved
        }
        if !flags.isDisjoint(with: [.created, .modified, .cloned]) { return .fileContentChanged }
        if flags.contains(.inodeMetadataChanged) { return .fileAttributesChanged }
        // Extended attributes change when files are opened, tagged in Finder
        // or synced; the audio content is untouched.
        return .ignore
    }
}

// MARK: - Deferred reads

public enum LocalFileWatchSchedule {
    /// Minimum spacing between two comparisons of all individually added
    /// files when the Mac app becomes active again.
    public static let individualFileCheckInterval: TimeInterval = 30
}

/// Why a changed file could not be read yet.
public enum LocalFileReadDeferral: String, Sendable, CaseIterable {
    /// iCloud is downloading the file.
    case downloading
    /// A local copy exists but iCloud has a newer version.
    case outdated
    /// Only a placeholder is here and nothing is downloading it.
    case notDownloaded
    /// Size or dates moved during the read, or the file is still too short.
    case changing
    /// Nothing is at the path right now.
    case missing
    /// The reader found neither tags nor audio properties.
    case unreadable
    /// The file exists but this app may not read it.
    case inaccessible
}

public enum LocalFileRefreshRetryPolicy {
    private static let downloadDelays: [TimeInterval] = [2, 4, 8, 16, 30, 30]
    private static let changingDelays: [TimeInterval] = [2, 4, 8, 16]
    private static let unreadableDelays: [TimeInterval] = [4, 15]
    /// One short wait before a vanished file counts as deleted: providers can
    /// briefly leave the path empty while replacing a file.
    private static let missingDelays: [TimeInterval] = [2]

    /// Delay before retry number `attempt` (1-based, counting the read that
    /// just failed). Nil means stop retrying.
    public static func delay(for reason: LocalFileReadDeferral, attempt: Int, notified: Bool) -> TimeInterval? {
        let delays: [TimeInterval]
        switch reason {
        case .downloading: delays = downloadDelays
        // Without a download in progress only a reported change is worth
        // waiting for; a row merely shown on screen is checked again next time.
        case .outdated: delays = notified ? downloadDelays : []
        case .changing: delays = changingDelays
        case .unreadable: delays = unreadableDelays
        case .missing: delays = notified ? missingDelays : []
        // The next download or permission grant produces its own notification.
        case .notDownloaded, .inaccessible: delays = []
        }
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

// MARK: - Own writes

/// What `stat` says about one file: device, inode, size and both timestamps.
public struct LocalFileIdentity: Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modifiedNanoseconds: Int64
    public var changedNanoseconds: Int64

    public init(device: UInt64, inode: UInt64, size: Int64, modifiedNanoseconds: Int64, changedNanoseconds: Int64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedNanoseconds = changedNanoseconds
    }
}

/// Files this app has just written, so the change notifications its own
/// writes produce do not trigger another read. An entry only matches while
/// the file is exactly as written; any later change by someone else alters
/// the inode, size or a timestamp and is read normally.
public struct LocalOwnWriteLedger: Sendable {
    public static let lifetime: TimeInterval = 120

    private struct Entry: Sendable {
        let identity: LocalFileIdentity
        let recordedAt: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func record(_ identity: LocalFileIdentity, for path: String, at date: Date = Date()) {
        entries = entries.filter { date.timeIntervalSince($0.value.recordedAt) < Self.lifetime }
        entries[path] = Entry(identity: identity, recordedAt: date)
    }

    public mutating func isOwnWrite(_ identity: LocalFileIdentity?, for path: String, at date: Date = Date()) -> Bool {
        guard let entry = entries[path] else { return false }
        guard date.timeIntervalSince(entry.recordedAt) < Self.lifetime, let identity, identity == entry.identity else {
            entries[path] = nil
            return false
        }
        return true
    }
}

// MARK: - Diagnostics

public enum LocalFileWatchLog {
    /// Size, modification time and change stamp before and after, for one
    /// log line. Revisions end in `|<change stamp>` on local files.
    public static func identityChange(
        beforeSize: Int64, beforeModified: Date?, beforeRevision: String?,
        afterSize: Int64, afterModified: Date?, afterRevision: String?
    ) -> String {
        let size = beforeSize == afterSize ? "same" : "\(beforeSize)->\(afterSize)"
        let modified: String
        switch (beforeModified, afterModified) {
        case let (before?, after?):
            let delta = after.timeIntervalSince(before)
            modified = abs(delta) < 0.001 ? "same" : String(format: "%+.1fs", delta)
        case (nil, nil): modified = "none"
        default: modified = "changed"
        }
        func stamp(_ revision: String?) -> String? {
            guard let revision, let separator = revision.lastIndex(of: "|") else { return nil }
            return String(revision[revision.index(after: separator)...])
        }
        let before = stamp(beforeRevision)
        let after = stamp(afterRevision)
        let stampState = before == after ? (before == nil ? "none" : "same") : "changed"
        return "size=\(size) mtime=\(modified) stamp=\(stampState)"
    }

    /// Names of the user-visible fields that differ after a read.
    public static func changedFields(from before: Song, to after: Song) -> [String] {
        var fields: [String] = []
        if before.title != after.title { fields.append("title") }
        if before.artistName != after.artistName { fields.append("artist") }
        if before.albumTitle != after.albumTitle { fields.append("album") }
        if before.albumArtistName != after.albumArtistName { fields.append("albumArtist") }
        if before.genre != after.genre { fields.append("genre") }
        if before.year != after.year { fields.append("year") }
        if before.trackNumber != after.trackNumber || before.discNumber != after.discNumber { fields.append("track") }
        if before.coverArtFileName != after.coverArtFileName { fields.append("cover") }
        if before.lyricsFileName != after.lyricsFileName { fields.append("lyrics") }
        if abs(before.duration - after.duration) >= 0.5 { fields.append("duration") }
        return fields
    }
}
