import Foundation

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

/// Reusable lookup index for canonical Apple Music user-library identities.
/// Building the index normalizes library metadata once; individual playback
/// lookups inspect only candidates that share an ID or normalized title.
public struct AppleMusicTrackIdentityIndex: Sendable {
    private struct Candidate: Sendable {
        let identity: AppleMusicTrackIdentity
        let normalizedTitle: String
        let normalizedArtist: String
        let normalizedAlbum: String
    }

    private var candidatesByItemID: [String: Candidate] = [:]
    private var canonicalIDsByMusicItemID: [String: Set<String>] = [:]
    private var canonicalIDsByNormalizedTitle: [String: Set<String>] = [:]

    public init() {}

    public init<Library: Sequence>(_ library: Library)
    where Library.Element == AppleMusicTrackIdentity {
        for identity in library {
            upsert(identity)
        }
    }

    public var count: Int { candidatesByItemID.count }

    /// Replaces an authoritative snapshot, removing identities no longer in it.
    public mutating func replace(with library: [AppleMusicTrackIdentity]) {
        self = Self(library)
    }

    /// Adds or updates identities from an incomplete snapshot without pruning
    /// canonical entries that are absent from that snapshot.
    public mutating func merge(_ library: [AppleMusicTrackIdentity]) {
        for identity in library {
            upsert(identity)
        }
    }

    /// Updates one canonical item and removes every stale index reference that
    /// belonged to the previous value for the same canonical item ID.
    public mutating func upsert(_ identity: AppleMusicTrackIdentity) {
        if let previous = candidatesByItemID[identity.itemID] {
            removeIndexReferences(for: previous)
        }

        let candidate = Candidate(
            identity: identity,
            normalizedTitle: Self.normalize(identity.title),
            normalizedArtist: Self.normalize(identity.artist),
            normalizedAlbum: Self.normalize(identity.album)
        )
        candidatesByItemID[identity.itemID] = candidate

        for musicItemID in identity.alternateIDs.union([identity.itemID]) {
            canonicalIDsByMusicItemID[musicItemID, default: []].insert(identity.itemID)
        }
        if !candidate.normalizedTitle.isEmpty {
            canonicalIDsByNormalizedTitle[candidate.normalizedTitle, default: []]
                .insert(identity.itemID)
        }
    }

    /// Resolves a playback identity back to the canonical user-library item.
    /// ID overlap is authoritative; normalized metadata is a conservative
    /// fallback when `PlayParameters` omit a usable catalog identifier.
    public func canonicalID(for playback: AppleMusicTrackIdentity) -> String? {
        guard !candidatesByItemID.isEmpty else { return nil }

        let playbackIDs = playback.alternateIDs.union([playback.itemID])
        var exactCanonicalIDs = Set<String>()
        for playbackID in playbackIDs {
            exactCanonicalIDs.formUnion(canonicalIDsByMusicItemID[playbackID] ?? [])
        }
        if exactCanonicalIDs.count == 1 { return exactCanonicalIDs.first }

        let normalizedTitle = Self.normalize(playback.title)
        guard !normalizedTitle.isEmpty,
              let titleMatches = canonicalIDsByNormalizedTitle[normalizedTitle],
              !titleMatches.isEmpty else { return nil }

        let playbackArtist = Self.normalize(playback.artist)
        let playbackAlbum = Self.normalize(playback.album)
        let ranked = titleMatches.compactMap { canonicalID -> (itemID: String, score: Int)? in
            guard let candidate = candidatesByItemID[canonicalID] else { return nil }
            return (
                canonicalID,
                Self.metadataScore(
                    playbackArtist: playbackArtist,
                    playbackAlbum: playbackAlbum,
                    playbackDuration: playback.duration,
                    candidate: candidate
                )
            )
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.itemID < $1.itemID
        }

        guard let best = ranked.first, best.score >= 4 else { return nil }
        if ranked.count > 1, ranked[1].score == best.score { return nil }
        return best.itemID
    }

    private mutating func removeIndexReferences(for candidate: Candidate) {
        let canonicalID = candidate.identity.itemID
        for musicItemID in candidate.identity.alternateIDs.union([canonicalID]) {
            guard var matches = canonicalIDsByMusicItemID[musicItemID] else { continue }
            matches.remove(canonicalID)
            canonicalIDsByMusicItemID[musicItemID] = matches.isEmpty ? nil : matches
        }

        if !candidate.normalizedTitle.isEmpty,
           var matches = canonicalIDsByNormalizedTitle[candidate.normalizedTitle] {
            matches.remove(canonicalID)
            canonicalIDsByNormalizedTitle[candidate.normalizedTitle] = matches.isEmpty ? nil : matches
        }
        candidatesByItemID[canonicalID] = nil
    }

    private static func metadataScore(
        playbackArtist: String,
        playbackAlbum: String,
        playbackDuration: TimeInterval?,
        candidate: Candidate
    ) -> Int {
        var score = 0

        if !playbackArtist.isEmpty, playbackArtist == candidate.normalizedArtist { score += 5 }

        if !playbackAlbum.isEmpty, playbackAlbum == candidate.normalizedAlbum { score += 3 }

        if let lhs = playbackDuration, lhs > 0,
           let rhs = candidate.identity.duration, rhs > 0 {
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
