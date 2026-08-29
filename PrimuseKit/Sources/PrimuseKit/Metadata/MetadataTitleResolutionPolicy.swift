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
    public static func preferredEmbeddedTitle(
        from candidates: [EmbeddedTitleCandidate]
    ) -> String? {
        candidates.enumerated().compactMap { index, candidate in
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
