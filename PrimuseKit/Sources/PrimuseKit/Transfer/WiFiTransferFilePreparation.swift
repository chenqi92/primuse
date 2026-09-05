import Foundation

public enum WiFiTransferFilePreparation {
    public static let maximumFileSize: Int64 = 8 * 1024 * 1024 * 1024

    public static func unavailableReason(song: Song, sourceType: MusicSourceType) -> String? {
        if sourceType == .appleMusic { return "libraryProtected" }
        if sourceType.isAwaitingPublicAPI { return "librarySourceUnavailable" }
        if song.cueSheetPath?.isEmpty == false { return "libraryCue" }
        if song.isStreamDescriptor { return "libraryStream" }
        if !PrimuseConstants.supportedAudioExtensions.contains(song.fileFormat.rawValue) { return "unsupportedFile" }
        if song.fileSize <= 0, sourceType != .local, sourceType != .appleMusicLibrary { return "libraryUnknownSize" }
        if song.fileSize > maximumFileSize { return "tooLarge" }
        return nil
    }

    public static func safeComponent(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) ? "_" : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= 180 else { break }
            result.append(character)
        }
        while result.hasPrefix(".") { result.removeFirst() }
        return result.isEmpty ? "Music" : result
    }

    public static func fileName(for song: Song) -> String {
        let originalExtension = (song.filePath as NSString).pathExtension.lowercased()
        let fileExtension = PrimuseConstants.supportedAudioExtensions.contains(originalExtension)
            ? originalExtension : song.fileFormat.rawValue
        return safeComponent(song.title) + "." + fileExtension
    }

    /// A playback cache may tolerate short files; exports require the exact source size.
    public static func isCompleteCache(_ url: URL, expectedSize: Int64) -> Bool {
        guard expectedSize > 0,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return Int64(values.fileSize ?? -1) == expectedSize
    }

    public static func download(
        to destination: URL,
        size: Int64,
        read: @escaping @Sendable (Int64, Int64) async throws -> Data,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        guard size > 0, size <= maximumFileSize else { throw WiFiTransferError.tooLarge }
        let worker = Task.detached(priority: .utility) {
            try checkSpace(at: destination.deletingLastPathComponent(), additionalBytes: size)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw WiFiTransferError.conflict }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw WiFiTransferError.notEnoughSpace
            }
            let output = try FileHandle(forWritingTo: destination)
            var succeeded = false
            defer {
                try? output.close()
                if !succeeded { try? FileManager.default.removeItem(at: destination) }
            }
            var offset: Int64 = 0
            while offset < size {
                try Task.checkCancellation()
                let length = min(1024 * 1024, size - offset)
                let data = try await read(offset, length)
                try Task.checkCancellation()
                guard data.count == length else { throw WiFiTransferError.invalidRequest }
                try output.write(contentsOf: data)
                offset += length
                await progress(offset)
            }
            try Task.checkCancellation()
            try output.synchronize()
            succeeded = true
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    public static func checkSpace(at directory: URL, additionalBytes: Int64) throws {
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        if let available, Int64(available) < additionalBytes + 64 * 1024 * 1024 {
            throw WiFiTransferError.notEnoughSpace
        }
    }
}
