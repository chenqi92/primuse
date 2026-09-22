import Foundation

public enum EmbeddedTitleSource: Int, Equatable, Sendable {
    case common = 0
    case iTunesSongName
    case quickTimeMetadataTitle
    case quickTimeMetadataDisplayName
    case quickTimeUserDataFullName
    case quickTimeUserDataTrackName
}

public struct EmbeddedTitleCandidate: Equatable, Sendable {
    public let value: String
    public let source: EmbeddedTitleSource

    public init(value: String, source: EmbeddedTitleSource) {
        self.value = value
        self.source = source
    }
}

public enum MetadataTitleResolutionPolicy {
    /// A duplicated artist tag is not enough evidence by itself: the filename
    /// must independently identify that artist at one end of a separated pair.
    public static func titleCorrectingDuplicatedArtist(
        title: String?,
        artist: String?,
        fileStem: String?
    ) -> String? {
        guard let title = MediaMetadataTextRepair.repaired(title),
              let artist = MediaMetadataTextRepair.repaired(artist),
              let stem = MediaMetadataTextRepair.repaired(fileStem),
              !artist.isEmpty,
              equivalent(title, artist),
              !MediaMetadataTextRepair.isSuspicious(artist),
              !MediaMetadataTextRepair.isSuspicious(stem) else { return nil }

        let separators = stem.ranges(of: /\s+[-–—_]\s+/)
        for separator in separators {
            let left = String(stem[..<separator.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(stem[separator.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate: String
            if equivalent(left, artist) {
                candidate = right
            } else if equivalent(right, artist) {
                candidate = left
            } else {
                continue
            }
            guard !candidate.isEmpty,
                  !candidate.allSatisfy(\.isNumber),
                  !equivalent(candidate, artist) else { continue }
            return candidate
        }
        return nil
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }

    public static func preferredEmbeddedTitle(
        from candidates: [EmbeddedTitleCandidate]
    ) -> String? {
        candidates.enumerated().compactMap { index, candidate -> (
            value: String,
            isSuspicious: Bool,
            sourcePriority: Int,
            index: Int
        )? in
            let trimmed = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let repaired = MediaMetadataTextRepair.repaired(trimmed) ?? trimmed
            return (
                value: repaired,
                isSuspicious: MediaMetadataTextRepair.isSuspicious(repaired),
                sourcePriority: candidate.source.rawValue,
                index: index
            )
        }.min { lhs, rhs in
            if lhs.isSuspicious != rhs.isSuspicious {
                return !lhs.isSuspicious
            }
            if lhs.sourcePriority != rhs.sourcePriority {
                return lhs.sourcePriority < rhs.sourcePriority
            }
            return lhs.index < rhs.index
        }?.value
    }

    public static func shouldReinspectFileNameFallback(
        currentTitle: String,
        filePath: String,
        userEdited: Bool,
        isCueTrack: Bool
    ) -> Bool {
        guard !userEdited, !isCueTrack else { return false }
        let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return true }
        if MediaMetadataTextRepair.isSuspicious(title) { return true }

        let component = (filePath as NSString).lastPathComponent
        let rawStem = (component as NSString).deletingPathExtension
        let inferredTitle = MediaMetadataTextRepair.fileNameTitle(from: filePath)
        return [rawStem, inferredTitle].compactMap { $0 }.contains { candidate in
            title.compare(
                candidate,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            ) == .orderedSame
        }
    }
}
