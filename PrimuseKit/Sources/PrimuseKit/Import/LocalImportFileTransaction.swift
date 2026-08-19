import CryptoKit
import Foundation
import GRDB

/// Bounded, app-owned file transaction used by the iOS Files import path.
/// Staged files stay in a hidden directory on the destination volume so the
/// final move is a same-volume atomic rename.
public final class LocalImportFileTransaction: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var copyBufferSize: Int
        public var maximumFileNameBytes: Int
        public var minimumFreeSpaceReserve: Int64
        public var stagingDirectoryName: String

        public init(
            copyBufferSize: Int = 256 * 1024,
            maximumFileNameBytes: Int = 240,
            minimumFreeSpaceReserve: Int64 = 16 * 1024 * 1024,
            stagingDirectoryName: String = ".primuse-import-staging"
        ) {
            self.copyBufferSize = max(4 * 1024, copyBufferSize)
            self.maximumFileNameBytes = max(64, maximumFileNameBytes)
            self.minimumFreeSpaceReserve = max(0, minimumFreeSpaceReserve)
            self.stagingDirectoryName = stagingDirectoryName
        }
    }

    public struct StagedFile: Sendable, Equatable {
        public let url: URL
        public let sha256: String
        public let byteCount: Int64
        public let originalModificationDate: Date?
    }

    public struct CommittedFile: Sendable, Equatable {
        public let url: URL
        public let sha256: String
        public let byteCount: Int64
        public let originalModificationDate: Date?
    }

    public enum TransactionError: Error, LocalizedError, Equatable {
        case stagingOwnershipMissing
        case sourceIsNotRegularFile
        case insufficientSpace(required: Int64, available: Int64)
        case failedToCreateStagingFile
        case stagedFileMissing

        public var errorDescription: String? {
            switch self {
            case .stagingOwnershipMissing:
                "The import staging directory is missing its ownership marker."
            case .sourceIsNotRegularFile:
                "The selected item is not a regular file."
            case .insufficientSpace(let required, let available):
                "Not enough free space (required \(required) bytes, available \(available) bytes)."
            case .failedToCreateStagingFile:
                "The import staging file could not be created."
            case .stagedFileMissing:
                "The import staging file disappeared before commit."
            }
        }
    }

    public typealias ChunkObserver = (_ copiedByteCount: Int64) throws -> Void

    private static let ownershipMarkerName = ".primuse-owned-staging-v1"
    private static let ownershipMarkerContents = Data("Primuse Local Import Staging v1\n".utf8)
    private static let stagedFilePrefix = "primuse-import-"

    public let destinationDirectory: URL
    public let configuration: Configuration

    public var stagingDirectory: URL {
        destinationDirectory.appendingPathComponent(
            configuration.stagingDirectoryName,
            isDirectory: true
        )
    }

    public init(
        destinationDirectory: URL,
        configuration: Configuration = Configuration()
    ) {
        self.destinationDirectory = destinationDirectory.standardizedFileURL
        self.configuration = configuration
    }

    /// Establishes ownership on first use, then removes only transaction files
    /// whose names match Primuse's private staging prefix.
    public func prepareAndCleanStaging() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: stagingDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, hasValidOwnershipMarker(fileManager: fileManager) else {
                throw TransactionError.stagingOwnershipMissing
            }
        } else {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false
            )
            try Self.ownershipMarkerContents.write(
                to: ownershipMarkerURL,
                options: .atomic
            )
        }
        try cleanOwnedStagingFiles(fileManager: fileManager)
    }

    public func stageCopy(
        from source: URL,
        originalFileName: String,
        onChunk: ChunkObserver? = nil
    ) throws -> StagedFile {
        let fileManager = FileManager.default
        guard hasValidOwnershipMarker(fileManager: fileManager) else {
            throw TransactionError.stagingOwnershipMissing
        }

        let sourceValues = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard sourceValues.isRegularFile == true else {
            throw TransactionError.sourceIsNotRegularFile
        }

        let sourceSize = Int64(sourceValues.fileSize ?? 0)
        try verifyAvailableSpace(for: sourceSize)

        let fileExtension = (originalFileName as NSString).pathExtension
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension.lowercased())"
        let stagedName = "\(Self.stagedFilePrefix)\(UUID().uuidString).partial\(suffix)"
        let stagedURL = stagingDirectory.appendingPathComponent(stagedName)
        guard fileManager.createFile(atPath: stagedURL.path, contents: nil) else {
            throw TransactionError.failedToCreateStagingFile
        }

        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: stagedURL)
            defer {
                try? input.close()
                try? output.close()
            }

            var hasher = SHA256()
            var copiedByteCount: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: configuration.copyBufferSize) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                copiedByteCount += Int64(chunk.count)
                try onChunk?(copiedByteCount)
            }
            try output.synchronize()

            if let modificationDate = sourceValues.contentModificationDate {
                var values = URLResourceValues()
                values.contentModificationDate = modificationDate
                var mutableStagedURL = stagedURL
                try? mutableStagedURL.setResourceValues(values)
            }

            return StagedFile(
                url: stagedURL,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                byteCount: copiedByteCount,
                originalModificationDate: sourceValues.contentModificationDate
            )
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
    }

    /// Moves a validated staged file into its final, importable name. The
    /// staging directory is a child of `destinationDirectory`, so moveItem is
    /// an atomic rename rather than a second byte copy.
    public func commit(
        _ staged: StagedFile,
        suggestedFileName: String
    ) throws -> CommittedFile {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: staged.url.path) else {
            throw TransactionError.stagedFileMissing
        }
        let destination = uniqueDestination(
            for: Self.safeFileName(
                suggestedFileName,
                maximumUTF8Bytes: configuration.maximumFileNameBytes
            ),
            fileManager: fileManager
        )
        try fileManager.moveItem(at: staged.url, to: destination)
        return CommittedFile(
            url: destination,
            sha256: staged.sha256,
            byteCount: staged.byteCount,
            originalModificationDate: staged.originalModificationDate
        )
    }

    public func discard(_ staged: StagedFile) {
        let fileManager = FileManager.default
        guard staged.url.deletingLastPathComponent().standardizedFileURL == stagingDirectory else {
            return
        }
        guard staged.url.lastPathComponent.hasPrefix(Self.stagedFilePrefix) else { return }
        try? fileManager.removeItem(at: staged.url)
    }

    public func removeCommittedFile(_ committed: CommittedFile) throws {
        let standardized = committed.url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == destinationDirectory,
              standardized.lastPathComponent.hasPrefix(".") == false else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: standardized)
    }

    public func ownedStagingFileCount() throws -> Int {
        let fileManager = FileManager.default
        guard hasValidOwnershipMarker(fileManager: fileManager) else { return 0 }
        return try fileManager.contentsOfDirectory(atPath: stagingDirectory.path).filter {
            $0.hasPrefix(Self.stagedFilePrefix)
        }.count
    }

    public static func sha256(
        of url: URL,
        bufferSize: Int = 256 * 1024,
        onChunk: ChunkObserver? = nil
    ) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var readByteCount: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: max(4 * 1024, bufferSize)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            readByteCount += Int64(chunk.count)
            try onChunk?(readByteCount)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func safeFileName(
        _ proposedName: String,
        maximumUTF8Bytes: Int = 240
    ) -> String {
        let normalized = proposedName.precomposedStringWithCanonicalMapping
        let rawExtension = (normalized as NSString).pathExtension
        let normalizedExtension = rawExtension.precomposedStringWithCanonicalMapping
        var base = (normalized as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." { base = "Imported Audio" }
        if base.hasPrefix(".") { base = "_" + base.dropFirst() }

        let suffix = normalizedExtension.isEmpty ? "" : ".\(normalizedExtension)"
        let byteLimit = max(64, maximumUTF8Bytes)
        while !base.isEmpty && (base + suffix).utf8.count > byteLimit {
            base.removeLast()
        }
        if base.isEmpty { base = "Imported Audio" }
        return base + suffix
    }

    private var ownershipMarkerURL: URL {
        stagingDirectory.appendingPathComponent(Self.ownershipMarkerName)
    }

    private func hasValidOwnershipMarker(fileManager: FileManager) -> Bool {
        guard let contents = try? Data(contentsOf: ownershipMarkerURL) else { return false }
        return contents == Self.ownershipMarkerContents
    }

    private func cleanOwnedStagingFiles(fileManager: FileManager) throws {
        for child in try fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        ) where child.lastPathComponent.hasPrefix(Self.stagedFilePrefix) {
            try fileManager.removeItem(at: child)
        }
    }

    private func verifyAvailableSpace(for sourceSize: Int64) throws {
        let (sum, overflow) = max(0, sourceSize).addingReportingOverflow(
            configuration.minimumFreeSpaceReserve
        )
        let required = overflow ? Int64.max : sum
        guard let values = try? destinationDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
        ]), let available = values.volumeAvailableCapacityForImportantUsage else {
            return
        }
        guard available >= required else {
            throw TransactionError.insufficientSpace(required: required, available: available)
        }
    }

    private func uniqueDestination(
        for fileName: String,
        fileManager: FileManager
    ) -> URL {
        let first = destinationDirectory.appendingPathComponent(fileName)
        guard !fileManager.fileExists(atPath: first.path) else {
            let base = (fileName as NSString).deletingPathExtension
            let fileExtension = (fileName as NSString).pathExtension
            var index = 2
            while true {
                let suffix = " \(index)"
                let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
                var truncatedBase = base
                while !truncatedBase.isEmpty,
                      (truncatedBase + suffix + extensionSuffix).utf8.count
                        > configuration.maximumFileNameBytes {
                    truncatedBase.removeLast()
                }
                let candidateName = truncatedBase + suffix + extensionSuffix
                let candidate = destinationDirectory.appendingPathComponent(candidateName)
                if !fileManager.fileExists(atPath: candidate.path) { return candidate }
                index += 1
            }
        }
        return first
    }
}

public struct LocalImportIdentityEntry: Sendable, Equatable {
    public let sha256: String
    public let relativePath: String
    public let byteCount: Int64
    public let modificationDate: Date?

    public init(
        sha256: String,
        relativePath: String,
        byteCount: Int64,
        modificationDate: Date?
    ) {
        self.sha256 = sha256
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }
}

/// Disk-backed content identity index. Lookup memory stays constant as the
/// library grows, and each batch is committed in one SQLite transaction.
public final class LocalImportIdentityStore: @unchecked Sendable {
    private let database: DatabaseQueue

    public init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.label = "Primuse local import identity store"
        database = try DatabaseQueue(path: path, configuration: configuration)
        try migrate()
    }

    public func entry(forSHA256 sha256: String) throws -> LocalImportIdentityEntry? {
        try database.read { db in
            try row(
                try Row.fetchOne(
                    db,
                    sql: "SELECT sha256, relativePath, byteCount, modificationTime FROM localImportIdentity WHERE sha256 = ?",
                    arguments: [sha256]
                )
            )
        }
    }

    public func entry(forRelativePath relativePath: String) throws -> LocalImportIdentityEntry? {
        try database.read { db in
            try row(
                try Row.fetchOne(
                    db,
                    sql: "SELECT sha256, relativePath, byteCount, modificationTime FROM localImportIdentity WHERE relativePath = ?",
                    arguments: [relativePath]
                )
            )
        }
    }

    public func recordBatch(_ entries: [LocalImportIdentityEntry]) throws {
        guard !entries.isEmpty else { return }
        try database.write { db in
            for entry in entries {
                try db.execute(
                    sql: """
                        INSERT INTO localImportIdentity
                            (sha256, relativePath, byteCount, modificationTime, committedAt)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(sha256) DO UPDATE SET
                            relativePath = excluded.relativePath,
                            byteCount = excluded.byteCount,
                            modificationTime = excluded.modificationTime,
                            committedAt = excluded.committedAt
                        """,
                    arguments: [
                        entry.sha256,
                        entry.relativePath,
                        entry.byteCount,
                        entry.modificationDate?.timeIntervalSince1970,
                        Date().timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    public func remove(sha256: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM localImportIdentity WHERE sha256 = ?",
                arguments: [sha256]
            )
        }
    }

    public func remove(relativePath: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM localImportIdentity WHERE relativePath = ?",
                arguments: [relativePath]
            )
        }
    }

    public func count() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM localImportIdentity") ?? 0
        }
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_local_import_identity") { db in
            try db.create(table: "localImportIdentity") { table in
                table.primaryKey("sha256", .text)
                table.column("relativePath", .text).notNull().unique()
                table.column("byteCount", .integer).notNull()
                table.column("modificationTime", .double)
                table.column("committedAt", .double).notNull()
            }
        }
        try migrator.migrate(database)
    }

    private func row(_ row: Row?) throws -> LocalImportIdentityEntry? {
        guard let row else { return nil }
        let timestamp: Double? = row["modificationTime"]
        return LocalImportIdentityEntry(
            sha256: row["sha256"],
            relativePath: row["relativePath"],
            byteCount: row["byteCount"],
            modificationDate: timestamp.map(Date.init(timeIntervalSince1970:))
        )
    }
}
