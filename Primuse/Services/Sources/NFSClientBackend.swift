import Darwin
import Foundation
import NFSKit
import PrimuseKit
import nfs

struct NFSRemoteEntry: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
}

protocol NFSClientBackend: AnyObject, Sendable {
    func connect(exportPath: String) async throws
    func disconnect() async
    func listExports() async throws -> [String]
    func listDirectory(path: String) async throws -> [NFSRemoteEntry]
    func fileSize(path: String) async throws -> Int64
    func read(path: String, offset: Int64, length: Int64) async throws -> Data
    func remove(path: String) async throws
    func download(path: String, to localURL: URL) async throws
    func upload(localURL: URL, to path: String) async throws
    func rename(path: String, to newPath: String) async throws
}

/// Adapts the existing callback-based NFSKit client. NFSKit currently creates
/// libnfs contexts with the library default (NFSv3), so this backend is used
/// for explicit v3 and as the first attempt for Auto.
final class NFSKitClientBackend: NFSClientBackend, @unchecked Sendable {
    private let client: NFSClient
    private let stateLock = NSLock()
    private var connectedExportPath: String?

    init(url: URL) throws {
        guard let client = try NFSClient(url: url) else {
            throw SourceError.connectionFailed("Invalid NFS host")
        }
        self.client = client
    }

    func connect(exportPath: String) async throws {
        if stateLock.withLock({ connectedExportPath == exportPath }) {
            return
        }

        await disconnect()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            client.connect(export: exportPath) { [weak self] error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    self?.stateLock.withLock {
                        self?.connectedExportPath = exportPath
                    }
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func disconnect() async {
        guard let exportPath = stateLock.withLock({ connectedExportPath }) else {
            return
        }

        await withCheckedContinuation { continuation in
            client.disconnect(export: exportPath, gracefully: true) { [weak self] _ in
                self?.stateLock.withLock {
                    self?.connectedExportPath = nil
                }
                continuation.resume()
            }
        }
    }

    func listExports() async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            client.listExports { result in
                continuation.resume(with: result)
            }
        }
    }

    func listDirectory(path: String) async throws -> [NFSRemoteEntry] {
        try await withCheckedThrowingContinuation { continuation in
            client.contentsOfDirectory(atPath: path) { result in
                continuation.resume(with: result.map { entries in
                    entries.compactMap { entry in
                        guard let name = entry.name,
                              name != ".",
                              name != "..",
                              let remotePath = entry.path else {
                            return nil
                        }

                        return NFSRemoteEntry(
                            name: name,
                            path: remotePath,
                            isDirectory: entry.isDirectory || entry.fileResourceType == .directory,
                            size: entry.fileSize ?? 0,
                            modifiedDate: entry.contentModificationDate
                                ?? entry.attributeModificationDate
                                ?? entry.creationDate
                        )
                    }
                })
            }
        }
    }

    func fileSize(path: String) async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            client.attributesOfItem(atPath: path) { result in
                switch result {
                case .success(let attributes):
                    if let size = (attributes[.fileSizeKey] as? Int64)
                        ?? (attributes[.fileSizeKey] as? Int).map(Int64.init) {
                        continuation.resume(returning: size)
                    } else {
                        continuation.resume(throwing: SourceError.fileNotFound(path))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func read(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard let end = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
            return Data()
        }

        return try await withCheckedThrowingContinuation { continuation in
            client.contents(atPath: path, range: offset..<end, progress: nil) { result in
                continuation.resume(with: result)
            }
        }
    }

    func remove(path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            client.removeFile(atPath: path) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func download(path: String, to localURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            client.downloadItem(atPath: path, to: localURL, progress: { _, _ in true }) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func upload(localURL: URL, to path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            client.uploadItem(at: localURL, toPath: path, progress: { _ in true }) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func rename(path: String, to newPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            client.moveItem(atPath: path, toPath: newPath) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

/// Small libnfs-backed client used for NFSv4. NFSKit does not expose its
/// `nfs_context`, but its transitive C module exposes the stable libnfs API.
/// A private serial queue owns the context so no pointer crosses concurrent
/// operations.
final class NFSv4ClientBackend: NFSClientBackend, @unchecked Sendable {
    private let host: String
    private let port: Int?
    private let queue: DispatchQueue
    private var context: UnsafeMutablePointer<nfs_context>?
    private var connectedExportPath: String?

    init(host: String, port: Int?, sourceID: String) {
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = port
        self.queue = DispatchQueue(label: "primuse.nfs.v4.\(sourceID)")
    }

    deinit {
        destroyContext()
    }

    func connect(exportPath: String) async throws {
        try await perform {
            if self.connectedExportPath == exportPath, self.context != nil {
                return
            }

            self.destroyContext()
            guard let context = nfs_init_context() else {
                throw SourceError.connectionFailed("Unable to create NFSv4 context")
            }

            nfs_set_timeout(context, 30_000)
            if let port = self.port, port > 0 {
                nfs_set_nfsport(context, Int32(port))
            }

            let versionStatus = nfs_set_version(context, Int32(NFS_V4))
            guard versionStatus == 0 else {
                let error = self.makeError(context: context, status: versionStatus, operation: "set version")
                nfs_destroy_context(context)
                throw error
            }

            let mountStatus = self.host.withCString { hostPointer in
                exportPath.withCString { exportPointer in
                    nfs_mount(context, hostPointer, exportPointer)
                }
            }
            guard mountStatus == 0 else {
                let error = self.makeError(context: context, status: mountStatus, operation: "mount")
                nfs_destroy_context(context)
                throw error
            }

            self.context = context
            self.connectedExportPath = exportPath
        }
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.destroyContext()
                continuation.resume()
            }
        }
    }

    func listExports() async throws -> [String] {
        // NFSv4 has no separate MOUNT export-discovery protocol. Its pseudo
        // filesystem root is always browsable; a configured export path is
        // mounted directly by NFSSource instead.
        ["/"]
    }

    func listDirectory(path: String) async throws -> [NFSRemoteEntry] {
        try await perform {
            let context = try self.requireContext()
            var directory: UnsafeMutablePointer<nfsdir>?
            let openStatus = path.withCString { nfs_opendir(context, $0, &directory) }
            guard openStatus == 0, let directory else {
                throw self.makeError(context: context, status: openStatus, operation: "open directory")
            }
            defer { nfs_closedir(context, directory) }

            var entries: [NFSRemoteEntry] = []
            while let pointer = nfs_readdir(context, directory) {
                let entry = pointer.pointee
                guard let namePointer = entry.name else { continue }
                let name = String(cString: namePointer)
                guard name != ".", name != ".." else { continue }

                let normalizedParent = NFSSelectionPathCodec.normalizedRelativePath(path)
                let childPath = normalizedParent == "/"
                    ? "/\(name)"
                    : "\(normalizedParent)/\(name)"
                let modeDirectory = (entry.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
                let typeDirectory = entry.type == UInt32(NF3DIR.rawValue)
                let seconds = TimeInterval(entry.mtime.tv_sec)
                let microseconds = TimeInterval(entry.mtime.tv_usec) / 1_000_000

                entries.append(
                    NFSRemoteEntry(
                        name: name,
                        path: childPath,
                        isDirectory: modeDirectory || typeDirectory,
                        size: Int64(clamping: entry.size),
                        modifiedDate: seconds > 0 ? Date(timeIntervalSince1970: seconds + microseconds) : nil
                    )
                )
            }
            return entries
        }
    }

    func fileSize(path: String) async throws -> Int64 {
        try await perform {
            let context = try self.requireContext()
            var attributes = nfs_stat_64()
            let status = path.withCString { nfs_stat64(context, $0, &attributes) }
            guard status == 0 else {
                throw self.makeError(context: context, status: status, operation: "stat")
            }
            return Int64(clamping: attributes.nfs_size)
        }
    }

    func read(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }

        return try await perform {
            let context = try self.requireContext()
            var fileHandle: UnsafeMutablePointer<nfsfh>?
            let openStatus = path.withCString { nfs_open(context, $0, O_RDONLY, &fileHandle) }
            guard openStatus == 0, let fileHandle else {
                throw self.makeError(context: context, status: openStatus, operation: "open file")
            }
            defer { _ = nfs_close(context, fileHandle) }

            let requested = Int(min(length, Int64(Int.max)))
            var data = Data(count: requested)
            let readStatus = data.withUnsafeMutableBytes { buffer in
                nfs_pread(context, fileHandle, UInt64(offset), UInt64(requested), buffer.baseAddress)
            }
            guard readStatus >= 0 else {
                throw self.makeError(context: context, status: readStatus, operation: "read")
            }
            data.count = Int(readStatus)
            return data
        }
    }

    func remove(path: String) async throws {
        try await perform {
            let context = try self.requireContext()
            let status = path.withCString { nfs_unlink(context, $0) }
            guard status == 0 else {
                throw self.makeError(context: context, status: status, operation: "delete")
            }
        }
    }

    func download(path: String, to localURL: URL) async throws {
        try await perform {
            let context = try self.requireContext()
            var fileHandle: UnsafeMutablePointer<nfsfh>?
            let openStatus = path.withCString { nfs_open(context, $0, O_RDONLY, &fileHandle) }
            guard openStatus == 0, let fileHandle else {
                throw self.makeError(context: context, status: openStatus, operation: "open file")
            }
            defer { _ = nfs_close(context, fileHandle) }

            _ = FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let localHandle = try FileHandle(forWritingTo: localURL)
            defer { try? localHandle.close() }

            var offset: UInt64 = 0
            let chunkSize = 1_048_576
            var buffer = Data(count: chunkSize)
            while true {
                let readStatus = buffer.withUnsafeMutableBytes { bytes in
                    nfs_pread(context, fileHandle, offset, UInt64(chunkSize), bytes.baseAddress)
                }
                guard readStatus >= 0 else {
                    throw self.makeError(context: context, status: readStatus, operation: "download")
                }
                guard readStatus > 0 else { break }

                try localHandle.write(contentsOf: buffer.prefix(Int(readStatus)))
                offset += UInt64(readStatus)
            }
        }
    }

    func upload(localURL: URL, to path: String) async throws {
        try await perform {
            let context = try self.requireContext()
            let input = try FileHandle(forReadingFrom: localURL)
            defer { try? input.close() }

            var remoteHandle: UnsafeMutablePointer<nfsfh>?
            let createStatus = path.withCString {
                nfs_creat(context, $0, 0o600, &remoteHandle)
            }
            guard createStatus == 0, let remoteHandle else {
                throw self.makeError(
                    context: context,
                    status: createStatus,
                    operation: "create upload file"
                )
            }
            defer { _ = nfs_close(context, remoteHandle) }

            var offset: UInt64 = 0
            while true {
                let chunk = try input.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                let written = chunk.withUnsafeBytes { bytes in
                    nfs_pwrite(
                        context,
                        remoteHandle,
                        offset,
                        UInt64(chunk.count),
                        bytes.baseAddress
                    )
                }
                guard written == chunk.count else {
                    let status = Int32(clamping: written)
                    throw self.makeError(
                        context: context,
                        status: status,
                        operation: "upload"
                    )
                }
                offset += UInt64(written)
            }
        }
    }

    func rename(path: String, to newPath: String) async throws {
        try await perform {
            let context = try self.requireContext()
            let status = path.withCString { sourcePointer in
                newPath.withCString { destinationPointer in
                    nfs_rename(context, sourcePointer, destinationPointer)
                }
            }
            guard status == 0 else {
                throw self.makeError(context: context, status: status, operation: "rename")
            }
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func requireContext() throws -> UnsafeMutablePointer<nfs_context> {
        guard let context else {
            throw SourceError.connectionFailed("NFSv4 share is not connected")
        }
        return context
    }

    private func destroyContext() {
        guard let context else { return }
        _ = nfs_umount(context)
        nfs_destroy_context(context)
        self.context = nil
        connectedExportPath = nil
    }

    private func makeError(
        context: UnsafeMutablePointer<nfs_context>,
        status: Int32,
        operation: String
    ) -> SourceError {
        let detail = String(cString: nfs_get_error(context))
        return .connectionFailed("NFSv4 \(operation) failed (\(status)): \(detail)")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
