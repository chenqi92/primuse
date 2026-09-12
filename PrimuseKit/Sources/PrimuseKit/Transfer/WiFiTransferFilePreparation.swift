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

    // MARK: - Off-main filesystem primitives

    /// Staging a library selection touches the filesystem once per song and, on
    /// teardown, unlinks a tree proportional to the staged bytes. Callers that
    /// live on the main actor `await` these wrappers, so their revalidation
    /// guards keep the exact order they have today while the syscalls run on a
    /// utility thread.
    ///
    /// Cancellation is observed before the operation starts, so a cancelled
    /// caller fails fast instead of extending the staging tree. `removeItem` is
    /// deliberately exempt: it is the cleanup path, and a cancelled caller still
    /// needs the partially staged folder gone before the tree is enumerated.
    public static func createDirectory(at url: URL) async throws {
        try await offMain {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public static func moveItem(at source: URL, to destination: URL) async throws {
        try await offMain {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    public static func removeItem(at url: URL) async throws {
        try await offMain(honoringCancellation: false) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func checkSpaceAsync(at directory: URL, additionalBytes: Int64) async throws {
        try await offMain {
            try checkSpace(at: directory, additionalBytes: additionalBytes)
        }
    }

    public static func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) async throws {
        try await offMain {
            try data.write(to: url, options: options)
        }
    }

    /// The cancellation check happens here, before the worker exists: a
    /// detached task does not inherit cancellation, so checking inside the
    /// body would race `onCancel` and let an already-cancelled caller still
    /// extend the staging tree. `honoringCancellation: false` is the cleanup
    /// path, which must run to completion precisely when the caller was
    /// cancelled.
    private static func offMain(
        honoringCancellation: Bool = true,
        _ body: @escaping @Sendable () throws -> Void
    ) async throws {
        if honoringCancellation { try Task.checkCancellation() }
        let worker = Task.detached(priority: .utility, operation: body)
        guard honoringCancellation else { return try await worker.value }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

public struct WiFiTransferLibraryGroupID: Hashable, Sendable {
    public let sourceID: String
    public let album: AlbumGroupingIdentity?

    public init(song: Song) {
        sourceID = song.sourceID
        album = AlbumGroupingPolicy.identity(albumTitle: song.albumTitle, albumArtistName: song.albumArtistName,
                                             trackArtistName: song.artistName, unknownArtistName: "")
    }
}

public enum WiFiTransferLibraryGrouping {
    public static let selectionLimit = 3_000

    public static func matches(_ song: Song, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [song.title, song.artistName ?? "", song.albumTitle ?? ""].contains {
            $0.localizedStandardContains(query)
        }
    }

    public static func toggling(_ eligibleIDs: [String], in selected: Set<String>) throws -> Set<String> {
        let group = Set(eligibleIDs)
        if group.isSubset(of: selected) { return selected.subtracting(group) }
        let result = selected.union(group)
        guard result.count <= selectionLimit else { throw WiFiTransferError.tooLarge }
        return result
    }
}
