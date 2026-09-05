import Foundation

public enum WiFiTransferError: String, Error, Sendable {
    case invalidPath, unsupportedFile, conflict, notFound, notEnoughSpace
    case invalidRequest, tooLarge, unauthorized, tooManyAttempts, unavailable
    case browserDisabled, rejected, invalidAddress

    var status: Int {
        switch self {
        case .invalidPath, .invalidRequest, .invalidAddress: 400
        case .unauthorized, .browserDisabled, .rejected: 401
        case .notFound: 404
        case .conflict: 409
        case .tooLarge: 413
        case .unsupportedFile: 415
        case .tooManyAttempts: 429
        case .notEnoughSpace: 507
        case .unavailable: 503
        }
    }
}

public struct WiFiTransferFile: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
}

/// All operations, including streaming writes, run on the server's serial queue.
final class WiFiTransferFiles {
    private final class StagingRegistry: @unchecked Sendable {
        let lock = NSLock()
        var active: Set<String> = []
    }
    private static let stagingRegistry = StagingRegistry()
    private static let stagingMarker = Data("Primuse Wi-Fi transfer v1".utf8)
    static let maximumFileSize: Int64 = 8 * 1024 * 1024 * 1024
    static let extensions = PrimuseConstants.supportedAudioExtensions
        .union(PrimuseConstants.supportedCueSheetExtensions)
        .union(PrimuseConstants.supportedLyricsExtensions)
        .union(PrimuseConstants.supportedCoverExtensions)
    let root: URL
    private let staging: URL
    private let fm = FileManager.default

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        self.staging = root.appendingPathComponent(".wifi-transfer-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw WiFiTransferError.invalidPath
        }
        try Self.stagingRegistry.lock.withLock {
            // A process termination bypasses deinit. Only reclaim directories
            // carrying our exact marker; concurrent sessions retain their own.
            for directory in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                let prefix = ".wifi-transfer-"
                guard directory.lastPathComponent.hasPrefix(prefix),
                      UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil,
                      !Self.stagingRegistry.active.contains(directory.standardizedFileURL.path),
                      (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      (try? Data(contentsOf: directory.appendingPathComponent(".owner"))) == Self.stagingMarker else { continue }
                try fm.removeItem(at: directory)
            }
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            do { try Self.stagingMarker.write(to: staging.appendingPathComponent(".owner")) }
            catch { try? fm.removeItem(at: staging); throw error }
            Self.stagingRegistry.active.insert(staging.standardizedFileURL.path)
        }
    }

    deinit {
        Self.stagingRegistry.lock.withLock {
            try? fm.removeItem(at: staging)
            _ = Self.stagingRegistry.active.remove(staging.standardizedFileURL.path)
        }
    }

    func resolve(_ path: String, allowRoot: Bool = false) throws -> URL {
        if path.isEmpty, allowRoot { return root }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 32, path.utf8.count <= 2048,
              !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && $0.utf8.count <= 255 }) else {
            throw WiFiTransferError.invalidPath
        }
        var result = root
        for part in parts {
            result.appendPathComponent(String(part))
            // Reject links even when their targets stay inside the managed folder.
            // Otherwise another local writer could retarget a validated component.
            if (try? result.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw WiFiTransferError.invalidPath
            }
        }
        let resolved = result.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
            throw WiFiTransferError.invalidPath
        }
        return result
    }

    func list(_ path: String) throws -> [WiFiTransferFile] {
        let directory = try resolve(path, allowRoot: true)
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw WiFiTransferError.notFound
        }
        return try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let relative = path.isEmpty ? url.lastPathComponent : path + "/" + url.lastPathComponent
            guard (try? resolve(relative)) != nil else { return nil }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            let directory = values.isDirectory == true
            guard directory || (values.isRegularFile == true && Self.extensions.contains(url.pathExtension.lowercased())) else {
                return nil
            }
            return WiFiTransferFile(name: url.lastPathComponent, path: relative,
                                    isDirectory: directory, size: Int64(values.fileSize ?? 0))
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func makeDirectory(_ path: String) throws {
        let url = try resolve(path)
        if fm.fileExists(atPath: url.path) { throw WiFiTransferError.conflict }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func beginUpload(path: String, size: Int64) throws -> Upload {
        let url = try resolve(path)
        guard Self.extensions.contains(url.pathExtension.lowercased()) else { throw WiFiTransferError.unsupportedFile }
        guard size > 0 else { throw WiFiTransferError.invalidRequest }
        guard size <= Self.maximumFileSize else { throw WiFiTransferError.tooLarge }
        guard !fm.fileExists(atPath: url.path) else { throw WiFiTransferError.conflict }
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        if let available, Int64(available) < size + 64 * 1024 * 1024 {
            throw WiFiTransferError.notEnoughSpace
        }
        return try Upload(path: path, expectedSize: size,
                          temporaryURL: staging.appendingPathComponent(UUID().uuidString))
    }

    func commit(_ upload: Upload) throws {
        guard upload.receivedSize == upload.expectedSize else { throw WiFiTransferError.invalidRequest }
        try upload.handle.synchronize()
        try upload.handle.close()
        let destination = try resolve(upload.path)
        guard !fm.fileExists(atPath: destination.path) else { throw WiFiTransferError.conflict }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try resolve(upload.path)
        // moveItem refuses to replace an existing file, including a concurrent upload.
        try fm.moveItem(at: upload.temporaryURL, to: destination)
    }

    func delete(_ path: String) throws {
        let url = try resolve(path)
        guard fm.fileExists(atPath: url.path) else { throw WiFiTransferError.notFound }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            // Nonempty folders are deliberately not recursively deleted from a browser.
            guard try fm.contentsOfDirectory(atPath: url.path).isEmpty else { throw WiFiTransferError.conflict }
        } else if values.isRegularFile != true || !Self.extensions.contains(url.pathExtension.lowercased()) {
            throw WiFiTransferError.unsupportedFile
        }
        try fm.removeItem(at: url)
    }

    final class Upload {
        let path: String
        let expectedSize: Int64
        let temporaryURL: URL
        let handle: FileHandle
        private(set) var receivedSize: Int64 = 0

        init(path: String, expectedSize: Int64, temporaryURL: URL) throws {
            self.path = path
            self.expectedSize = expectedSize
            self.temporaryURL = temporaryURL
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw WiFiTransferError.notEnoughSpace
            }
            handle = try FileHandle(forWritingTo: temporaryURL)
        }

        func append(_ data: Data) throws {
            guard Int64(data.count) <= expectedSize - receivedSize else { throw WiFiTransferError.invalidRequest }
            try handle.write(contentsOf: data)
            receivedSize += Int64(data.count)
        }

        deinit {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}
