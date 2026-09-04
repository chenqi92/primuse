import CryptoKit
import Foundation

/// Pure policy shared by the tvOS streaming scanner and its regression tests.
/// Keeping identity, batching and re-scan reconciliation here prevents the TV
/// catalogue from drifting from the generic connector scanner.
public enum TVScanPipelinePolicy {
    public static let publicationBatchSize = 20
    public static let metadataConcurrency = 2

    public static func songID(
        sourceID: String,
        path: String,
        providerID: String? = nil,
        usesStableProviderIdentity: Bool = false
    ) -> String {
        let itemIdentity = SourceSongIdentityMaterialPolicy.itemIdentity(
            path: path,
            providerID: providerID,
            usesStableProviderIdentity: usesStableProviderIdentity
        )
        return hash32("\(sourceID):\(itemIdentity)")
    }

    public static func cueSongID(
        sourceID: String,
        path: String,
        providerID: String? = nil,
        usesStableProviderIdentity: Bool = false,
        cuePath: String,
        trackNumber: Int
    ) -> String {
        let itemIdentity = SourceSongIdentityMaterialPolicy.itemIdentity(
            path: path,
            providerID: providerID,
            usesStableProviderIdentity: usesStableProviderIdentity
        )
        return hash32(
            "\(sourceID):\(itemIdentity)#cue:\(cuePath)#track:\(trackNumber)"
        )
    }

    /// Server clients historically returned a full SHA-256 string. Their
    /// material is already correct, so truncating to the first 16 digest bytes
    /// produces the same ID as the generic scanner without re-keying by a
    /// different input.
    public static func canonicalSongID(_ value: String) -> String {
        let lowercased = value.lowercased()
        guard lowercased.count == 64,
              lowercased.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            return value
        }
        return String(lowercased.prefix(32))
    }

    public static func hash32(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Removes duplicate roots while preserving the user's order. Descendant
    /// paths are deliberately retained: opaque provider IDs do not encode
    /// ancestry, and the scanner's global scheduled-directory set safely
    /// collapses an overlapping child once the parent lists it.
    public static func normalizedScanRoots(_ roots: [String]) -> [String] {
        var seen: Set<String> = []
        return roots.compactMap { raw in
            let root = normalizedPath(raw)
            guard seen.insert(root).inserted else { return nil }
            return root
        }
    }

    public static func batches<Element>(
        _ elements: [Element],
        size: Int = publicationBatchSize
    ) -> [[Element]] {
        guard size > 0, !elements.isEmpty else { return [] }
        return stride(from: 0, to: elements.count, by: size).map { offset in
            Array(elements[offset..<min(offset + size, elements.count)])
        }
    }

    /// Builds the Phase-A record shown immediately on TV. An unchanged file
    /// keeps its previously enriched technical metadata, while a replaced file
    /// starts from the new skeleton. Both paths preserve explicit user edits
    /// and the original library insertion date.
    public static func reconciledSkeleton(
        existing: Song?,
        candidate: Song
    ) -> Song {
        guard let existing else { return candidate }

        let contentChanged = contentChanged(
            existing: existing,
            candidate: candidate
        )
        var result: Song
        if contentChanged {
            result = SongUserMetadataPolicy.preservingUserEdits(
                from: existing,
                in: candidate
            )
        } else {
            result = existing
            result.id = candidate.id
            result.filePath = candidate.filePath
            result.sourceID = candidate.sourceID
            if !candidate.isStreamDescriptor {
                result.fileFormat = candidate.fileFormat
                result.fileSize = candidate.fileSize
            }
            result.lastModified = candidate.lastModified
            if !candidate.isStreamDescriptor { result.revision = candidate.revision }
            result.cueSheetPath = candidate.cueSheetPath
            result.cueStartTime = candidate.cueStartTime
            result.cueEndTime = candidate.cueEndTime
            if let cover = candidate.coverArtFileName { result.coverArtFileName = cover }
            if let lyrics = candidate.lyricsFileName { result.lyricsFileName = lyrics }
            if let video = candidate.mvPath { result.mvPath = video }
        }
        result.dateAdded = existing.dateAdded
        return result
    }

    /// A strong unchanged-content signal plus a useful prior duration lets a
    /// resumed/incremental scan avoid reopening the remote file. Skeleton-only
    /// rows have duration zero and are retried on the next scan.
    public static func canReuseMetadata(existing: Song?, candidate: Song) -> Bool {
        guard let existing else { return false }
        if candidate.isStreamDescriptor {
            return STRMRevision.wrapperMatches(
                songRevision: existing.revision,
                wrapperRevision: candidate.revision,
                wrapperSize: candidate.fileSize,
                wrapperModifiedDate: candidate.lastModified
            )
        }
        guard existing.duration > 0 else { return false }
        let hasStableRevision = existing.revision?.isEmpty == false
            && candidate.revision?.isEmpty == false
        let hasStableModifiedDate = existing.lastModified != nil
            && candidate.lastModified != nil
        guard hasStableRevision || hasStableModifiedDate else { return false }
        return !contentChanged(existing: existing, candidate: candidate)
    }

    public static func normalizedPath(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "/" }
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static func contentChanged(existing: Song, candidate: Song) -> Bool {
        if candidate.isStreamDescriptor,
           STRMRevision.wrapperMatches(
            songRevision: existing.revision,
            wrapperRevision: candidate.revision,
            wrapperSize: candidate.fileSize,
            wrapperModifiedDate: candidate.lastModified
           ) {
            return false
        }
        return ServerSongCatalogMergePolicy.contentChanged(
            existing: existing,
            incoming: candidate
        )
    }
}
