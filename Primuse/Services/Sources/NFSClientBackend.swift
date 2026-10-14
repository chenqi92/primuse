import Foundation
import PrimuseKit

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

/// NFSv3,也是 Auto 的第一选择。挂载方式、导出列表和目录项的路径、修改时间
/// 都与之前的 NFSKit 客户端一致:修改时间进了歌曲的文件版本,算法一变,已扫描
/// 的歌就会被当成换了文件。
final class NFSv3ClientBackend: NFSClientBackend {
    private let host: String
    private let session: LibNFSSession

    init(host: String, sourceID: String) {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.host = host
        self.session = LibNFSSession(
            configuration: .init(
                host: host,
                port: nil,
                version: .v3,
                timeout: RemoteRequestDeadline.standardStallTimeout
            ),
            label: "v3.\(sourceID)"
        )
    }

    func connect(exportPath: String) async throws {
        try await session.mount(exportPath: exportPath)
    }

    func disconnect() async {
        await session.unmount()
    }

    func listExports() async throws -> [String] {
        try await LibNFSSession.exports(host: host, timeout: RemoteRequestDeadline.standardStallTimeout)
    }

    func listDirectory(path: String) async throws -> [NFSRemoteEntry] {
        try await session.listDirectory(path).map { entry in
            NFSRemoteEntry(
                name: entry.name,
                path: (path as NSString).appendingPathComponent(entry.name),
                isDirectory: entry.isNFS3Directory,
                size: Int64(clamping: entry.size),
                modifiedDate: NFSv3EntryDatePolicy.modifiedDate(
                    seconds: entry.mtimeSeconds,
                    nanoseconds: entry.mtimeNanoseconds
                )
            )
        }
    }

    func fileSize(path: String) async throws -> Int64 {
        Int64(clamping: try await session.fileSize(path))
    }

    func read(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard let end = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
            return Data()
        }
        return try await session.read(
            path,
            offset: UInt64(offset),
            length: Int(clamping: end - offset)
        )
    }

    func remove(path: String) async throws {
        try await session.remove(path)
    }

    func download(path: String, to localURL: URL) async throws {
        try await session.download(path, to: localURL)
    }

    func upload(localURL: URL, to path: String) async throws {
        try await session.upload(from: localURL, to: path, createFlags: O_RDWR | O_CREAT | O_EXCL)
    }

    func rename(path: String, to newPath: String) async throws {
        try await session.rename(path, to: newPath)
    }
}

/// NFSv4。没有 MOUNT 协议,伪文件系统的根总能浏览;配置了端口时直接连那个端口。
final class NFSv4ClientBackend: NFSClientBackend {
    private let session: LibNFSSession

    init(host: String, port: Int?, sourceID: String) {
        self.session = LibNFSSession(
            configuration: .init(
                host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                port: port,
                version: .v4,
                timeout: 30
            ),
            label: "v4.\(sourceID)"
        )
    }

    func connect(exportPath: String) async throws {
        try await session.mount(exportPath: exportPath)
    }

    func disconnect() async {
        await session.unmount()
    }

    func listExports() async throws -> [String] {
        // NFSv4 has no separate MOUNT export-discovery protocol. Its pseudo
        // filesystem root is always browsable; a configured export path is
        // mounted directly by NFSSource instead.
        ["/"]
    }

    func listDirectory(path: String) async throws -> [NFSRemoteEntry] {
        let normalizedParent = NFSSelectionPathCodec.normalizedRelativePath(path)
        return try await session.listDirectory(path).map { entry in
            let seconds = TimeInterval(entry.mtimeSeconds)
            let microseconds = TimeInterval(entry.mtimeMicroseconds) / 1_000_000
            return NFSRemoteEntry(
                name: entry.name,
                path: normalizedParent == "/" ? "/\(entry.name)" : "\(normalizedParent)/\(entry.name)",
                isDirectory: entry.isModeDirectory || entry.isNFS3Directory,
                size: Int64(clamping: entry.size),
                modifiedDate: seconds > 0 ? Date(timeIntervalSince1970: seconds + microseconds) : nil
            )
        }
    }

    func fileSize(path: String) async throws -> Int64 {
        Int64(clamping: try await session.fileSize(path))
    }

    func read(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        return try await session.read(path, offset: UInt64(offset), length: Int(clamping: length))
    }

    func remove(path: String) async throws {
        try await session.remove(path)
    }

    func download(path: String, to localURL: URL) async throws {
        try await session.download(path, to: localURL)
    }

    func upload(localURL: URL, to path: String) async throws {
        try await session.upload(from: localURL, to: path, createFlags: nil)
    }

    func rename(path: String, to newPath: String) async throws {
        try await session.rename(path, to: newPath)
    }
}
