import Foundation

/// Limits tvOS decoded-playback cleanup to files created in the immediate
/// temporary directory with the app-owned prefix. The guard prevents an
/// unexpected URL from turning lifecycle cleanup into an arbitrary deletion.
public enum TVDecodedTemporaryFilePolicy {
    public static let fileNamePrefix = "tvsfb-"

    public static func makeURL(
        in temporaryDirectory: URL,
        fileExtension: String,
        identifier: UUID = UUID()
    ) -> URL {
        let sanitizedExtension = fileExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let resolvedExtension = sanitizedExtension.isEmpty ? "bin" : sanitizedExtension
        return temporaryDirectory.appendingPathComponent(
            "\(fileNamePrefix)\(identifier.uuidString).\(resolvedExtension)",
            isDirectory: false
        )
    }

    public static func isManagedFile(
        _ fileURL: URL,
        in temporaryDirectory: URL
    ) -> Bool {
        guard fileURL.isFileURL, temporaryDirectory.isFileURL else { return false }
        let standardizedFile = fileURL.standardizedFileURL
        let standardizedDirectory = temporaryDirectory.standardizedFileURL
        return standardizedFile.deletingLastPathComponent().path == standardizedDirectory.path
            && standardizedFile.lastPathComponent.hasPrefix(fileNamePrefix)
    }

    @discardableResult
    public static func removeIfManaged(
        _ fileURL: URL,
        in temporaryDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard isManagedFile(fileURL, in: temporaryDirectory),
              fileManager.fileExists(atPath: fileURL.path) else {
            return false
        }
        try fileManager.removeItem(at: fileURL)
        return true
    }
}

/// Validates the byte-accounting boundaries shared by tvOS whole-file decoder
/// downloads. Short nonempty chunks may continue, but empty/oversized chunks
/// and any final byte-count mismatch must fail closed.
public enum ExactChunkedDownloadPolicy {
    public enum ChunkDecision: Equatable, Sendable {
        case append
        case rejectEmpty
        case rejectOversized
    }

    public static func contentLengthIsValid(_ contentLength: Int64) -> Bool {
        contentLength >= 0
    }

    public static func chunkDecision(
        requestedLength: Int64,
        receivedLength: Int
    ) -> ChunkDecision {
        guard receivedLength > 0 else { return .rejectEmpty }
        guard requestedLength > 0,
              Int64(receivedLength) <= requestedLength else {
            return .rejectOversized
        }
        return .append
    }

    public static func isComplete(
        expectedLength: Int64,
        writtenLength: Int64
    ) -> Bool {
        expectedLength >= 0 && writtenLength == expectedLength
    }
}
