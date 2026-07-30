import CryptoKit
import Foundation
import PrimuseKit

enum NFSSelectionPathCodec {
    struct SelectionPath: Sendable {
        let exportPath: String
        let relativePath: String
    }

    static func makeSelectionPath(exportPath: String, relativePath: String) -> String {
        "nfs::\(encodeToken(normalizedExportPath(exportPath)))::\(encodeToken(normalizedRelativePath(relativePath)))"
    }

    static func parse(_ path: String) throws -> SelectionPath {
        guard path.hasPrefix("nfs::") else {
            throw SourceError.pathNotFound(path)
        }

        let payload = String(path.dropFirst("nfs::".count))
        guard let separator = payload.range(of: "::") else {
            throw SourceError.pathNotFound(path)
        }

        let exportToken = String(payload[..<separator.lowerBound])
        let relativeToken = String(payload[separator.upperBound...])

        guard let exportPath = decodeToken(exportToken),
              let relativePath = decodeToken(relativeToken) else {
            throw SourceError.pathNotFound(path)
        }

        return SelectionPath(
            exportPath: normalizedExportPath(exportPath),
            relativePath: normalizedRelativePath(relativePath)
        )
    }

    static func displayComponents(for path: String) -> [String] {
        guard let selection = try? parse(path) else {
            return []
        }

        let exportName = displayName(forExportPath: selection.exportPath)
        let children = selection.relativePath
            .split(separator: "/")
            .map(String.init)

        return [exportName] + children
    }

    static func displayName(forExportPath exportPath: String) -> String {
        let trimmed = exportPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? exportPath : name
    }

    static func normalizedRelativePath(_ path: String) -> String {
        if path.isEmpty || path == "/" {
            return "/"
        }

        return path.hasPrefix("/") ? path : "/\(path)"
    }

    static func normalizedExportPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "/"
        }

        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private static func encodeToken(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeToken(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = base64.count % 4
        if padding != 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }

        guard let data = Data(base64Encoded: base64) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

actor NFSSource: MusicSourceConnector {
    let sourceID: String

    private let host: String
    private let port: Int?
    private let configuredExportPath: String?
    private let nfsVersion: NFSVersion
    private var client: (any NFSClientBackend)?
    private var activeVersion: NFSVersion?
    private var connectedExportPath: String?
    private var cachedExports: [String]?
    private let cacheDirectory: URL

    init(
        sourceID: String,
        host: String,
        port: Int? = nil,
        exportPath: String? = nil,
        nfsVersion: NFSVersion = .auto
    ) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.nfsVersion = nfsVersion
        let normalizedExport = exportPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configuredExportPath = normalizedExport?.isEmpty == false
            ? NFSSelectionPathCodec.normalizedExportPath(normalizedExport!)
            : nil

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_nfs_cache")
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory

    }

    func connect() async throws {
        _ = try resolveClient()
        if let configuredExportPath {
            _ = try await ensureConnected(to: configuredExportPath)
        }
    }

    func disconnect() async {
        guard let client else {
            return
        }

        await client.disconnect()

        self.client = nil
        self.activeVersion = nil
        self.connectedExportPath = nil
        self.cachedExports = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        if path == "/", let configuredExportPath {
            return try await listDirectory(
                exportPath: configuredExportPath,
                relativePath: "/"
            )
        }

        if path == "/" {
            let exports = try await loadExports()
            return exports
                .map { exportPath in
                    RemoteFileItem(
                        name: NFSSelectionPathCodec.displayName(forExportPath: exportPath),
                        path: NFSSelectionPathCodec.makeSelectionPath(
                            exportPath: exportPath,
                            relativePath: "/"
                        ),
                        isDirectory: true,
                        size: 0,
                        modifiedDate: nil
                    )
                }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }

        let selection = try resolveSelectionPath(for: path)
        return try await listDirectory(
            exportPath: selection.exportPath,
            relativePath: selection.relativePath
        )
    }

    func localURL(for path: String) async throws -> URL {
        let selection = try resolveSelectionPath(for: path)
        let client = try await ensureConnected(to: selection.exportPath)

        let localURL = cacheDirectory.appendingPathComponent(cacheFileName(for: selection))
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        do {
            try await client.download(path: selection.relativePath, to: localURL)
            return localURL
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            throw SourceError.connectionFailed(error.localizedDescription)
        }
    }

    func deleteFile(at path: String) async throws {
        let selection = try resolveSelectionPath(for: path)
        let client = try await ensureConnected(to: selection.exportPath)

        try await client.remove(path: selection.relativePath)
    }

    /// NFSv3/v4 都通过 libnfs 执行 NFS_READ (offset + count)，协议级支持
    /// 任意 offset 读取，让 CloudPlaybackSource 边下边播替代整文件下载。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0 else { return Data() }
        let selection = try resolveSelectionPath(for: path)
        let client = try await ensureConnected(to: selection.exportPath)

        // offset < 0 表示从末尾倒数，先 stat 拿 size 转正。
        let actualRange: Range<Int64>
        if offset < 0 {
            // 区分"大小拿不到"与"0 字节文件": 前者无法换算 suffix range,
            // 返回空会被回填误判为"无尾部标签"而静默丢标签, 应抛错。
            let total = try await client.fileSize(path: selection.relativePath)
            let start = max(0, total + offset)
            guard let requestedEnd = SafeByteRange.exclusiveEnd(offset: start, length: length) else {
                return Data()
            }
            let end = min(total, requestedEnd)
            guard start < end else { return Data() }
            actualRange = start..<end
        } else {
            guard let end = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
                return Data()
            }
            actualRange = offset..<end
        }

        return try await client.read(
            path: selection.relativePath,
            offset: actualRange.lowerBound,
            length: actualRange.upperBound - actualRange.lowerBound
        )
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { try? handle.close() }

                    while true {
                        let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                        if data.isEmpty {
                            break
                        }
                        continuation.yield(data)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await scanDirectory(at: path, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func scanDirectory(
        at path: String,
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        let items = try await listFiles(at: path)

        for item in items {
            if item.isDirectory {
                try await scanDirectory(at: item.path, continuation: continuation)
                continue
            }

            if let scannable = SidecarHintResolver.scannableItem(item, siblings: items) {
                continuation.yield(scannable)
            }
        }
    }

    private func resolveClient() throws -> any NFSClientBackend {
        if let client {
            return client
        }

        let version = nfsVersion.connectionAttemptOrder[0]
        let client = try makeClient(version: version)
        self.client = client
        self.activeVersion = version
        return client
    }

    private func makeClient(version: NFSVersion) throws -> any NFSClientBackend {
        if version == .v4 {
            return NFSv4ClientBackend(host: host, port: port, sourceID: sourceID)
        }

        // IPv6 addresses must be wrapped in brackets for URL construction
        let urlHost = host.contains(":") && !host.hasPrefix("[")
            ? "[\(host)]"
            : host
        var components = URLComponents()
        components.scheme = "nfs"
        components.host = urlHost

        if let port, port > 0 {
            components.port = port
        }

        guard let url = components.url else {
            throw SourceError.connectionFailed("Invalid NFS host")
        }

        return try NFSKitClientBackend(url: url)
    }

    private func loadExports(forceRefresh: Bool = false) async throws -> [String] {
        if forceRefresh == false, let cachedExports, cachedExports.isEmpty == false {
            return cachedExports
        }

        var client = try resolveClient()
        let exports: [String]
        do {
            let loaded = try await client.listExports()
            guard loaded.isEmpty == false else {
                throw SourceError.connectionFailed("No NFS exports found")
            }
            exports = loaded
        } catch {
            client = try await switchToV4ForAuto(after: error)
            exports = try await client.listExports()
        }

        let normalizedExports = exports
            .map(NFSSelectionPathCodec.normalizedExportPath)
            .sorted { $0.localizedCompare($1) == .orderedAscending }

        if normalizedExports.isEmpty {
            throw SourceError.connectionFailed("No NFS exports found")
        }

        cachedExports = normalizedExports
        return normalizedExports
    }

    private func ensureConnected(to exportPath: String) async throws -> any NFSClientBackend {
        var activeClient = try resolveClient()
        let normalizedExportPath = NFSSelectionPathCodec.normalizedExportPath(exportPath)

        if connectedExportPath == normalizedExportPath {
            return activeClient
        }

        if connectedExportPath != nil {
            await activeClient.disconnect()
            self.connectedExportPath = nil
        }

        do {
            try await activeClient.connect(exportPath: normalizedExportPath)
        } catch {
            let fallback = try await switchToV4ForAuto(after: error)
            try await fallback.connect(exportPath: normalizedExportPath)
            activeClient = fallback
        }

        connectedExportPath = normalizedExportPath
        return activeClient
    }

    private func switchToV4ForAuto(after originalError: any Error) async throws -> any NFSClientBackend {
        guard nfsVersion.connectionAttemptOrder.count > 1,
              nfsVersion.connectionAttemptOrder.contains(.v4),
              activeVersion != .v4 else {
            throw originalError
        }

        if let client {
            await client.disconnect()
        }

        let fallback = try makeClient(version: .v4)
        client = fallback
        activeVersion = .v4
        connectedExportPath = nil
        cachedExports = nil
        return fallback
    }

    private func resolveSelectionPath(for path: String) throws -> NFSSelectionPathCodec.SelectionPath {
        if path.hasPrefix("nfs::") {
            return try NFSSelectionPathCodec.parse(path)
        }

        if let configuredExportPath {
            return .init(
                exportPath: configuredExportPath,
                relativePath: NFSSelectionPathCodec.normalizedRelativePath(path)
            )
        }

        throw SourceError.pathNotFound(path)
    }

    private func listDirectory(
        exportPath: String,
        relativePath: String
    ) async throws -> [RemoteFileItem] {
        let client = try await ensureConnected(to: exportPath)

        return try await client.listDirectory(path: relativePath)
            .map { entry in
                let normalizedPath = NFSSelectionPathCodec.normalizedRelativePath(entry.path)
                return RemoteFileItem(
                    name: entry.name,
                    path: NFSSelectionPathCodec.makeSelectionPath(
                        exportPath: exportPath,
                        relativePath: normalizedPath
                    ),
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    modifiedDate: entry.modifiedDate
                )
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func cacheFileName(for selection: NFSSelectionPathCodec.SelectionPath) -> String {
        let key = "\(selection.exportPath):\(selection.relativePath)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = (selection.relativePath as NSString).pathExtension
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }
}
