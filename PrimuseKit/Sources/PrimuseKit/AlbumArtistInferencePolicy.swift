import Foundation

/// Chooses an album artist for tracks whose own tag is missing or is only the
/// per-track fallback, by looking at the tracks that sit next to them.
///
/// A folder of one album whose files lack an album-artist tag falls apart
/// into one "album" per track artist: the OST folder where most files say
/// "鸣潮先约电台" and a few name the individual composer becomes several
/// same-titled albums. The folder is the missing signal, and a source whose
/// paths carry real folders is judged folder by folder, majority included.
///
/// A source that addresses tracks by ID (fnOS Music, Subsonic, Audio Station,
/// a media server) synthesises one flat path for every track, so it has no
/// folder to judge by. It splits the same album all the same, whenever the
/// server answers the album artist for some of its tracks and not the rest.
/// Those sources are grouped by album title alone and only the unambiguous
/// verdict is taken: one explicit tag in the album, everyone else untagged.
///
/// Cloud drives that address files by item ID (Google Drive, OneDrive, 123…)
/// do have real folders, only not in the path. `AlbumArtistFolderIndex`
/// carries the parent each file was listed under, and a track whose parent is
/// not known yet has no directory: it takes the explicit-tag verdict only.
public enum AlbumArtistInferencePolicy {
    public struct Track: Sendable, Equatable {
        public let id: String
        public let sourceID: String
        /// Parent directory of the source-relative path (see `directory(ofPath:)`),
        /// or nil when the source's paths carry no folder and the track's
        /// folder is not known.
        public let directory: String?
        public let albumTitle: String?
        public let albumArtistName: String?
        public let trackArtistName: String?

        public init(
            id: String,
            sourceID: String,
            directory: String?,
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
            guard !authoritative.contains(track.sourceID),
                  let directory = track.directory else { continue }
            directoriesBySource[track.sourceID, default: []].insert(directory)
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
        var keys = GroupingKeys()
        for scope in scopes(for: tracks, among: tracks.indices, restrictedTo: directoryAuthoritativeSourceIDs)
        where scope.count >= 2 {
            let values = ScopeValues(tracks, scope)
            guard let target = target(for: values, keys: &keys) else { continue }
            for (offset, index) in scope.enumerated() where values.effective[offset] != target {
                result[tracks[index].id] = target
            }
        }

        // Sources without real folders, and tracks whose folder is not known.
        // Their scope spans a whole album title, so a majority vote would be
        // free to rename a same-titled album by another artist; only an
        // undisputed explicit tag may speak for them.
        let unfoldered = tracks.indices.filter {
            !directoryAuthoritativeSourceIDs.contains(tracks[$0].sourceID) || tracks[$0].directory == nil
        }
        guard !unfoldered.isEmpty else { return result }
        for scope in scopes(for: tracks, among: unfoldered, restrictedTo: nil, byDirectory: false)
        where scope.count >= 2 {
            let values = ScopeValues(tracks, scope)
            guard let target = target(for: values, explicitTagsOnly: true, keys: &keys) else { continue }
            for (offset, index) in scope.enumerated() where values.effective[offset] != target {
                result[tracks[index].id] = target
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
        var groupingKeys = GroupingKeys()
        // Every source takes part, and the folder is not part of the key.
        // Unlike an inference this only asks for the file to be read again, so
        // it is scoped the way albums themselves are grouped — two tracks with
        // one album title are one album whether or not they sit side by side.
        for scope in scopes(for: tracks, among: tracks.indices, restrictedTo: nil, byDirectory: false)
        where scope.count >= 2 {
            let values = ScopeValues(tracks, scope)
            guard !values.explicit.contains(true) else { continue }
            var keys: Set<String> = []
            for value in values.effective {
                guard let value else { continue }
                keys.insert(groupingKeys.key(value))
            }
            guard keys.count >= 2, target(for: values, keys: &groupingKeys) == nil else { continue }
            for index in scope { result.insert(tracks[index].id) }
        }
        return result
    }

    /// Tracks grouped by source, album title and — for an inference, which
    /// rewrites grouping and must stay conservative — the folder too. Input
    /// order is preserved so the chosen spelling and every tie-break stay
    /// independent of Dictionary iteration order. Scopes hold indices into
    /// `tracks`: copying each track (six strings) into its scope dominated a
    /// library-wide pass.
    private static func scopes<Indices: Sequence<Int>>(
        for tracks: [Track],
        among indices: Indices,
        restrictedTo sourceIDs: Set<String>?,
        byDirectory: Bool = true
    ) -> [[Int]] {
        var scopeIndexByKey: [String: Int] = [:]
        var scopedTracks: [[Int]] = []

        for index in indices {
            let track = tracks[index]
            if let sourceIDs, !sourceIDs.contains(track.sourceID) { continue }
            guard let albumTitle = trimmed(track.albumTitle) else { continue }
            let directory: String
            if byDirectory {
                guard let known = track.directory else { continue }
                directory = known
            } else {
                directory = ""
            }
            let key = "\(track.sourceID)\u{1F}\(directory)\u{1F}\(albumTitle)"
            if let scope = scopeIndexByKey[key] {
                scopedTracks[scope].append(index)
            } else {
                scopeIndexByKey[key] = scopedTracks.count
                scopedTracks.append([index])
            }
        }
        return scopedTracks
    }

    // MARK: - Scope resolution

    /// The album artist the whole scope should use, or nil when the tracks do
    /// not agree strongly enough to overrule their own tags.
    ///
    /// `explicitTagsOnly` drops the majority vote, leaving only the verdict a
    /// scope can reach without the folder having vouched for it.
    private static func target(
        for values: ScopeValues,
        explicitTagsOnly: Bool = false,
        keys: inout GroupingKeys
    ) -> String? {
        // One tally over the whole scope: it decides both how strong a key is
        // and which spelling of that key the scope actually uses.
        var tally = Tally()
        var missingCount = 0
        for value in values.effective {
            if let value {
                tally.add(value, key: keys.key(value))
            } else {
                missingCount += 1
            }
        }

        var explicitKeys: [String] = []
        for (index, isExplicit) in values.explicit.enumerated() where isExplicit {
            guard let value = values.effective[index] else { continue }
            let key = keys.key(value)
            if !explicitKeys.contains(key) { explicitKeys.append(key) }
        }
        if explicitKeys.count == 1 {
            return tally.spelling(forKey: explicitKeys[0])
        }
        if explicitKeys.count > 1 {
            return nil
        }
        guard !explicitTagsOnly else { return nil }

        guard let top = tally.dominantKeyIndex() else { return nil }
        guard tally.count(forKeyAt: top) * 2 > values.effective.count else { return nil }
        guard tally.keyOrder.count >= 2 || missingCount > 0 else { return nil }
        return tally.spelling(forKeyAt: top)
    }

    /// `ArtistIdentityPolicy.groupingKey` remembered for one pass: every track
    /// of an album usually carries the same name, and folding is the expensive
    /// part of a library-wide inference.
    private struct GroupingKeys {
        private var keyByValue: [String: String] = [:]

        mutating func key(_ value: String) -> String {
            if let key = keyByValue[value] { return key }
            let key = ArtistIdentityPolicy.groupingKey(value)
            keyByValue[value] = key
            return key
        }
    }

    /// Counts grouping keys in first-seen order and remembers, per key, the
    /// most frequent spelling (ties resolved by the spelling seen first).
    private struct Tally {
        private(set) var keyOrder: [String] = []
        private var indexByKey: [String: Int] = [:]
        private var counts: [Int] = []
        private var spellingOrder: [[String]] = []
        private var spellingCounts: [[String: Int]] = []

        mutating func add(_ value: String, key: String) {
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

    /// Leading or trailing whitespace is rare in tags; checking both ends
    /// first skips the Foundation trim, which a library-wide pass otherwise
    /// paid several times per track.
    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars
        if let first = scalars.first, let last = scalars.last,
           !whitespace.contains(first), !whitespace.contains(last) {
            return value
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let whitespace = CharacterSet.whitespacesAndNewlines

    /// Per-track values of one scope, computed once per pass.
    ///
    /// - `effective`: the album artist the track would use today —
    ///   `AlbumGroupingPolicy` falls back to the track artist whenever no
    ///   album-artist tag survives trimming.
    /// - `explicit`: a tag that says something the per-track fallback does
    ///   not already say.
    private struct ScopeValues {
        var effective: [String?] = []
        var explicit: [Bool] = []

        init(_ tracks: [Track], _ scope: [Int]) {
            effective.reserveCapacity(scope.count)
            explicit.reserveCapacity(scope.count)
            for index in scope {
                let track = tracks[index]
                let albumArtist = AlbumArtistInferencePolicy.trimmed(track.albumArtistName)
                let trackArtist = AlbumArtistInferencePolicy.trimmed(track.trackArtistName)
                effective.append(albumArtist ?? trackArtist)
                if let albumArtist {
                    explicit.append(trackArtist.map { albumArtist.caseInsensitiveCompare($0) != .orderedSame } ?? true)
                } else {
                    explicit.append(false)
                }
            }
        }
    }
}

/// Parent folders of tracks whose `filePath` is a provider item ID. The path
/// of such a track carries no folder, while the scan's sync index keeps the
/// parent the provider listed the file under — the same rows the folder view
/// is built from. A source present here is judged by these folders; one of its
/// files missing from the map has no known folder. A source absent from it
/// keeps the folder of its path.
public struct AlbumArtistFolderIndex: Sendable, Equatable {
    public static let empty = AlbumArtistFolderIndex(parentsBySource: [:])

    /// sourceID → file path (the provider item ID) → parent folder identifier.
    public let parentsBySource: [String: [String: String]]

    public init(parentsBySource: [String: [String: String]]) {
        self.parentsBySource = parentsBySource.filter { !$0.value.isEmpty }
    }

    public func directory(sourceID: String, filePath: String) -> String? {
        guard let parents = parentsBySource[sourceID] else {
            return AlbumArtistInferencePolicy.directory(ofPath: filePath)
        }
        return parents[filePath]
    }

    /// File path → parent folder from one source's sync index. Keyed by the
    /// file rather than the song so CUE tracks cut from one file, and songs
    /// whose IDs were migrated, still find their folder.
    public static func parents(
        fromSyncIndex index: [String: SourceSyncIndexedItem]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for item in index.values where !item.isDirectory {
            guard let parent = item.parentPath, !parent.isEmpty else { continue }
            // A file listed by two rows would otherwise follow Dictionary
            // order; keep the verdict stable across launches.
            if let existing = result[item.path], existing <= parent { continue }
            result[item.path] = parent
        }
        return result
    }
}
