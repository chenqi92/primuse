import Foundation

/// Chooses an album artist for tracks whose own tag is missing or is only the
/// per-track fallback, by looking at the tracks that sit next to them.
///
/// A folder of one album whose files lack an album-artist tag falls apart
/// into one "album" per track artist: the OST folder where most files say
/// "鸣潮先约电台" and a few name the individual composer becomes several
/// same-titled albums. The folder is the missing signal. Only sources whose
/// paths carry real folders take part; a media server that exposes every
/// item under one synthetic directory keeps its server-provided grouping.
public enum AlbumArtistInferencePolicy {
    public struct Track: Sendable, Equatable {
        public let id: String
        public let sourceID: String
        /// Parent directory of the source-relative path; see `directory(ofPath:)`.
        public let directory: String
        public let albumTitle: String?
        public let albumArtistName: String?
        public let trackArtistName: String?

        public init(
            id: String,
            sourceID: String,
            directory: String,
            albumTitle: String?,
            albumArtistName: String?,
            trackArtistName: String?
        ) {
            self.id = id
            self.sourceID = sourceID
            self.directory = directory
            self.albumTitle = albumTitle
            self.albumArtistName = albumArtistName
            self.trackArtistName = trackArtistName
        }
    }

    public static func directory(ofPath path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Sources with at least two distinct directories among their tracks.
    public static func directoryAuthoritativeSourceIDs(for tracks: [Track]) -> Set<String> {
        var directoriesBySource: [String: Set<String>] = [:]
        var authoritative: Set<String> = []
        for track in tracks {
            guard !authoritative.contains(track.sourceID) else { continue }
            directoriesBySource[track.sourceID, default: []].insert(track.directory)
            if (directoriesBySource[track.sourceID]?.count ?? 0) >= 2 {
                authoritative.insert(track.sourceID)
                directoriesBySource[track.sourceID] = nil
            }
        }
        return authoritative
    }

    /// Track ID → album artist to use instead of the track's own effective
    /// value. Tracks absent from the result keep `albumArtistName ?? trackArtistName`.
    public static func inferredAlbumArtists(
        for tracks: [Track],
        directoryAuthoritativeSourceIDs: Set<String>
    ) -> [String: String] {
        var result: [String: String] = [:]
        for scope in scopes(for: tracks, restrictedTo: directoryAuthoritativeSourceIDs)
        where scope.count >= 2 {
            guard let target = target(for: scope) else { continue }
            for track in scope where effective(track) != target {
                result[track.id] = target
            }
        }
        return result
    }

    public static func inferredAlbumArtists(for tracks: [Track]) -> [String: String] {
        inferredAlbumArtists(
            for: tracks,
            directoryAuthoritativeSourceIDs: directoryAuthoritativeSourceIDs(for: tracks)
        )
    }

    /// Tracks whose stored album artist carries no information: nobody in the
    /// folder tagged one, so every value is the per-track fallback, and those
    /// fallbacks disagree, which also denies `inferredAlbumArtists` a majority.
    /// The stored value then says nothing about what the file contains — an
    /// OST folder in this state stays split into one same-titled album per
    /// composer forever, because every later pass sees a non-empty album
    /// artist and leaves it alone. Reading the file once is the only way out.
    ///
    /// Folders whose fallbacks already agree are left out: rereading them
    /// cannot change any grouping, and sweeping the whole library for that
    /// would cost one file read per song.
    public static func unconfirmedAlbumArtistTrackIDs(for tracks: [Track]) -> Set<String> {
        var result: Set<String> = []
        // Every source takes part, and the folder is not part of the key.
        // Unlike an inference this only asks for the file to be read again, so
        // it is scoped the way albums themselves are grouped — two tracks with
        // one album title are one album whether or not they sit side by side.
        for scope in scopes(for: tracks, restrictedTo: nil, byDirectory: false)
        where scope.count >= 2 {
            guard !scope.contains(where: isExplicit) else { continue }
            var keys: Set<String> = []
            for track in scope {
                guard let value = effective(track) else { continue }
                keys.insert(ArtistIdentityPolicy.groupingKey(value))
            }
            guard keys.count >= 2, target(for: scope) == nil else { continue }
            for track in scope { result.insert(track.id) }
        }
        return result
    }

    /// Tracks grouped by source, album title and — for an inference, which
    /// rewrites grouping and must stay conservative — the folder too. Input
    /// order is preserved so the chosen spelling and every tie-break stay
    /// independent of Dictionary iteration order.
    private static func scopes(
        for tracks: [Track],
        restrictedTo sourceIDs: Set<String>?,
        byDirectory: Bool = true
    ) -> [[Track]] {
        var scopeIndexByKey: [String: Int] = [:]
        var scopedTracks: [[Track]] = []

        for track in tracks {
            if let sourceIDs, !sourceIDs.contains(track.sourceID) { continue }
            guard let albumTitle = trimmed(track.albumTitle) else { continue }
            let directory = byDirectory ? track.directory : ""
            let key = "\(track.sourceID)\u{1F}\(directory)\u{1F}\(albumTitle)"
            if let index = scopeIndexByKey[key] {
                scopedTracks[index].append(track)
            } else {
                scopeIndexByKey[key] = scopedTracks.count
                scopedTracks.append([track])
            }
        }
        return scopedTracks
    }

    // MARK: - Scope resolution

    /// The album artist the whole scope should use, or nil when the tracks do
    /// not agree strongly enough to overrule their own tags.
    private static func target(for scope: [Track]) -> String? {
        // One tally over the whole scope: it decides both how strong a key is
        // and which spelling of that key the scope actually uses.
        var tally = Tally()
        var missingCount = 0
        for track in scope {
            if let value = effective(track) {
                tally.add(value)
            } else {
                missingCount += 1
            }
        }

        var explicitKeys: [String] = []
        for track in scope where isExplicit(track) {
            guard let value = effective(track) else { continue }
            let key = ArtistIdentityPolicy.groupingKey(value)
            if !explicitKeys.contains(key) { explicitKeys.append(key) }
        }
        if explicitKeys.count == 1 {
            return tally.spelling(forKey: explicitKeys[0])
        }
        if explicitKeys.count > 1 {
            return nil
        }

        guard let top = tally.dominantKeyIndex() else { return nil }
        guard tally.count(forKeyAt: top) * 2 > scope.count else { return nil }
        guard tally.keyOrder.count >= 2 || missingCount > 0 else { return nil }
        return tally.spelling(forKeyAt: top)
    }

    /// Counts grouping keys in first-seen order and remembers, per key, the
    /// most frequent spelling (ties resolved by the spelling seen first).
    private struct Tally {
        private(set) var keyOrder: [String] = []
        private var indexByKey: [String: Int] = [:]
        private var counts: [Int] = []
        private var spellingOrder: [[String]] = []
        private var spellingCounts: [[String: Int]] = []

        mutating func add(_ value: String) {
            let key = ArtistIdentityPolicy.groupingKey(value)
            let index: Int
            if let existing = indexByKey[key] {
                index = existing
            } else {
                index = keyOrder.count
                indexByKey[key] = index
                keyOrder.append(key)
                counts.append(0)
                spellingOrder.append([])
                spellingCounts.append([:])
            }
            counts[index] += 1
            if spellingCounts[index][value] == nil {
                spellingOrder[index].append(value)
            }
            spellingCounts[index][value, default: 0] += 1
        }

        func count(forKeyAt index: Int) -> Int { counts[index] }

        func dominantKeyIndex() -> Int? {
            var best: Int?
            for index in counts.indices where best.map({ counts[index] > counts[$0] }) ?? true {
                best = index
            }
            return best
        }

        func spelling(forKey key: String) -> String? {
            guard let index = indexByKey[key] else { return nil }
            return spelling(forKeyAt: index)
        }

        func spelling(forKeyAt index: Int) -> String? {
            var best: String?
            var bestCount = 0
            for spelling in spellingOrder[index] {
                let count = spellingCounts[index][spelling] ?? 0
                if count > bestCount {
                    best = spelling
                    bestCount = count
                }
            }
            return best
        }
    }

    // MARK: - Track values

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The album artist the track would use today: `AlbumGroupingPolicy` falls
    /// back to the track artist whenever no album-artist tag survives trimming.
    private static func effective(_ track: Track) -> String? {
        trimmed(track.albumArtistName) ?? trimmed(track.trackArtistName)
    }

    /// A tag that says something the per-track fallback does not already say.
    private static func isExplicit(_ track: Track) -> Bool {
        guard let albumArtist = trimmed(track.albumArtistName) else { return false }
        guard let trackArtist = trimmed(track.trackArtistName) else { return true }
        return albumArtist.caseInsensitiveCompare(trackArtist) != .orderedSame
    }
}
