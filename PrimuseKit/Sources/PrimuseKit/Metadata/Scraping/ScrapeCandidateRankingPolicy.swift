import Foundation

/// A deterministic rank for scrape candidates. Title compatibility remains
/// the identity gate. Within that gate, every usable duration ranks ahead of a
/// missing duration, then exact duration distance, title, and artist decide the
/// order. Metadata completeness only breaks remaining identity ties.
public struct ScrapeCandidateRank: Sendable, Equatable {
    public enum DurationTier: Int, Sendable, Equatable {
        case close = 0
        case plausible = 1
        case mismatch = 2
        case unknown = 3
        case unavailable = 4
    }

    public enum ArtistTier: Int, Sendable, Equatable {
        case exact = 0
        case partial = 1
        case unavailable = 2
        case conflict = 3
    }

    public let confidence: Double
    public let titleMatchLevel: Int
    public let artistMatchLevel: Int
    public let artistTier: ArtistTier
    public let durationTier: DurationTier
    public let durationDeltaMs: Int?
    public let metadataCompleteness: Int
}

public enum ScrapeCandidateRankingPolicy {
    public static func rank(
        requestedTitle: String,
        requestedArtist: String?,
        targetDurationMs: Int?,
        candidateTitle: String,
        candidateArtist: String?,
        candidateDurationMs: Int?,
        candidateAlbum: String? = nil,
        candidateYear: Int? = nil,
        candidateHasArtwork: Bool = false,
        candidateTrackNumber: Int? = nil,
        candidateGenreCount: Int = 0
    ) -> ScrapeCandidateRank {
        let titleMatchLevel = textMatchLevel(
            requested: requestedTitle,
            candidate: candidateTitle
        )
        let artistMatchLevel = textMatchLevel(
            requested: requestedArtist,
            candidate: candidateArtist
        )
        let normalizedRequestedArtist = normalized(requestedArtist)
        let normalizedCandidateArtist = normalized(candidateArtist)
        let artistTier: ScrapeCandidateRank.ArtistTier
        if normalizedRequestedArtist.isEmpty || normalizedCandidateArtist.isEmpty {
            artistTier = .unavailable
        } else if artistMatchLevel == 2 {
            artistTier = .exact
        } else if artistMatchLevel == 1 {
            artistTier = .partial
        } else {
            artistTier = .conflict
        }

        var score = 0.0
        var maximumScore = 30.0
        score += titleMatchLevel == 2 ? 30 : (titleMatchLevel == 1 ? 15 : 0)

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
                let plausibleToleranceMs = max(10_000, min(30_000, targetMs / 10))
                if delta < 2_000 {
                    score += 50
                } else if delta < 5_000 {
                    score += 30
                } else if delta < 10_000 {
                    score += 10
                } else if delta <= plausibleToleranceMs {
                    score += 5
                } else {
                    score -= 20
                }
                if delta < 10_000 {
                    durationTier = .close
                } else if delta <= plausibleToleranceMs {
                    durationTier = .plausible
                } else {
                    durationTier = .mismatch
                }
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
        let metadataCompleteness = informationCompleteness(
            durationMs: validCandidateMs,
            album: candidateAlbum,
            year: candidateYear,
            hasArtwork: candidateHasArtwork,
            trackNumber: candidateTrackNumber,
            genreCount: candidateGenreCount
        )
        return ScrapeCandidateRank(
            confidence: confidence,
            titleMatchLevel: titleMatchLevel,
            artistMatchLevel: artistMatchLevel,
            artistTier: artistTier,
            durationTier: durationTier,
            durationDeltaMs: durationDeltaMs,
            metadataCompleteness: metadataCompleteness
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

        if lhs.durationTier != rhs.durationTier {
            return lhs.durationTier.rawValue < rhs.durationTier.rawValue
        }
        if let lhsDelta = lhs.durationDeltaMs,
           let rhsDelta = rhs.durationDeltaMs,
           lhsDelta != rhsDelta {
            return lhsDelta < rhsDelta
        }
        if lhs.titleMatchLevel != rhs.titleMatchLevel {
            return lhs.titleMatchLevel > rhs.titleMatchLevel
        }
        if lhs.artistTier != rhs.artistTier {
            return lhs.artistTier.rawValue < rhs.artistTier.rawValue
        }
        if lhs.metadataCompleteness != rhs.metadataCompleteness {
            return lhs.metadataCompleteness > rhs.metadataCompleteness
        }

        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        return false
    }

    private static func informationCompleteness(
        durationMs: Int?,
        album: String?,
        year: Int?,
        hasArtwork: Bool,
        trackNumber: Int?,
        genreCount: Int
    ) -> Int {
        var score = 0
        if durationMs != nil { score += 2 }
        if !normalized(album).isEmpty { score += 2 }
        if hasArtwork { score += 2 }
        if let year, year > 0 { score += 1 }
        if let trackNumber, trackNumber > 0 { score += 1 }
        if genreCount > 0 { score += 1 }
        return score
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
