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
/// Both of those read one source at a time, while album grouping spans them
/// all, so an album held in two sources can still come apart: the source whose
/// server never answered an album artist has nobody inside it to learn from.
/// `crossSourceAlbumArtists` closes that last gap by matching the song itself.
public enum AlbumArtistInferencePolicy {
    public struct Track: Sendable, Equatable {
        public let id: String
        public let sourceID: String
        /// Parent directory of the source-relative path; see `directory(ofPath:)`.
        public let directory: String
        public let albumTitle: String?
        public let albumArtistName: String?
        public let trackArtistName: String?
        /// Song title and duration recognise one song across sources; a track
        /// missing either takes no part in that match.
        public let title: String?
        public let duration: TimeInterval

        public init(
            id: String,
            sourceID: String,
            directory: String,
            albumTitle: String?,
            albumArtistName: String?,
            trackArtistName: String?,
            title: String? = nil,
            duration: TimeInterval = 0
        ) {
            self.id = id
            self.sourceID = sourceID
            self.directory = directory
            self.albumTitle = albumTitle
            self.albumArtistName = albumArtistName
            self.trackArtistName = trackArtistName
            self.title = title
            self.duration = duration
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

        // Sources without real folders. Their scope spans a whole album title,
        // so a majority vote would be free to rename a same-titled album by
        // another artist; only an undisputed explicit tag may speak for them.
        var synthetic: Set<String> = []
        for track in tracks where !directoryAuthoritativeSourceIDs.contains(track.sourceID) {
            synthetic.insert(track.sourceID)
        }
        guard !synthetic.isEmpty else { return result }
        for scope in scopes(for: tracks, restrictedTo: synthetic, byDirectory: false)
        where scope.count >= 2 {
            guard let target = target(for: scope, explicitTagsOnly: true) else { continue }
            for track in scope where effective(track) != target {
                result[track.id] = target
            }
        }

        // Last, and only where the source-scoped passes above said nothing:
        // the same song sitting in another source.
        for (id, name) in crossSourceAlbumArtists(for: tracks) where result[id] == nil {
            result[id] = name
        }
        return result
    }

    /// Track ID → the album artist a copy of the same song carries in another
    /// source. Album grouping spans sources — `AlbumGroupingPolicy.identity`
    /// has no source in it — while both passes above read one source at a
    /// time. A library holding one album in fnOS Music and in Emby therefore
    /// keeps the fnOS copy on a card of its own for good: no track inside that
    /// source was ever tagged, so nothing in it can settle the album artist.
    ///
    /// Matching the song and not merely the album title is what makes this safe
    /// to do across sources. Two same-titled albums by different artists share
    /// no track title, so neither can rename the other; two encodings of one
    /// song agree on the title and land within seconds of each other.
    public static func crossSourceAlbumArtists(for tracks: [Track]) -> [String: String] {
        // Nearly every album is all-tagged or all-untagged and can never
        // produce a match, so the song titles — the folding, and the expensive
        // half of this — are only keyed for albums holding both kinds of row.
        var tagged: Set<String> = []
        var untagged: Set<String> = []
        for track in tracks where participates(track) {
            guard let albumTitle = trimmed(track.albumTitle) else { continue }
            if isExplicit(track) {
                tagged.insert(albumTitle)
            } else {
                untagged.insert(albumTitle)
            }
        }
        let mixed = tagged.intersection(untagged)
        guard !mixed.isEmpty else { return [:] }

        // Copies are collected in input order so the chosen spelling stays
        // independent of Dictionary iteration order. The album title is
        // compared the way `AlbumGroupingPolicy` compares it — trimmed, and
        // nothing more — so this can never join two albums the library shows
        // apart; only the song title is folded.
        var grouped: [[Track]] = []
        var indexByKey: [String: Int] = [:]
        for track in tracks where participates(track) {
            guard let albumTitle = trimmed(track.albumTitle), mixed.contains(albumTitle),
                  let songTitle = trimmed(track.title) else { continue }
            let key = "\(albumTitle)\u{1F}\(ArtistIdentityPolicy.groupingKey(songTitle))"
            if let index = indexByKey[key] {
                grouped[index].append(track)
            } else {
                indexByKey[key] = grouped.count
                grouped.append([track])
            }
        }

        var result: [String: String] = [:]
        for copies in grouped where copies.count >= 2 {
            var tally = Tally()
            var taggedCopies: [Track] = []
            for copy in copies where isExplicit(copy) {
                guard let value = effective(copy) else { continue }
                tally.add(value)
                taggedCopies.append(copy)
            }
            // Copies that disagree about the album artist settle nothing.
            guard tally.keyOrder.count == 1,
                  let target = tally.spelling(forKeyAt: 0) else { continue }
            for copy in copies where !isExplicit(copy) && effective(copy) != target {
                guard taggedCopies.contains(where: { withinDurationTolerance($0, copy) })
                else { continue }
                result[copy.id] = target
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
        // A copy of the same song elsewhere already answers for these rows.
        // Rereading them would cost a download on a streaming source and learn
        // nothing the library does not already know.
        let settledByCopies = crossSourceAlbumArtists(for: tracks)
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
            for track in scope where settledByCopies[track.id] == nil {
                result.insert(track.id)
            }
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
    ///
    /// `explicitTagsOnly` drops the majority vote, leaving only the verdict a
    /// scope can reach without the folder having vouched for it.
    private static func target(for scope: [Track], explicitTagsOnly: Bool = false) -> String? {
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
        guard !explicitTagsOnly else { return nil }

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

    /// Two encodings of one song rarely agree to the millisecond; the same
    /// tolerance `DuplicateDetector` uses to bucket them.
    private static let durationTolerance: TimeInterval = 2

    private static func withinDurationTolerance(_ lhs: Track, _ rhs: Track) -> Bool {
        abs(lhs.duration - rhs.duration) <= durationTolerance
    }

    /// A row that can be recognised as one particular song.
    private static func participates(_ track: Track) -> Bool {
        trimmed(track.albumTitle) != nil && trimmed(track.title) != nil && track.duration > 0
    }

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
