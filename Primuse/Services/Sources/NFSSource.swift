import CryptoKit
import Foundation
import NFSKit
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
    private var client: NFSClient?
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
        let normalizedExport = exportPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configuredExportPath = normalizedExport?.isEmpty == false
            ? NFSSelectionPathCodec.normalizedExportPath(normalizedExport!)
            : nil

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_nfs_cache")
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory

        _ = nfsVersion
    }

    func connect() async throws {
        _ = try resolveClient()
        if let configuredExportPath {
            try await ensureConnected(to: configuredExportPath)
        }
    }

    func disconnect() async {
        guard let client else {
            return
        }

        if let connectedExportPath {
            await disconnect(client: client, exportPath: connectedExportPath)
        }

        self.client = nil
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
        let client = try resolveClient()
        try await ensureConnected(to: selection.exportPath)

        let localURL = cacheDirectory.appendingPathComponent(cacheFileName(for: selection))
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        do {
            try await download(
                client: client,
                remotePath: selection.relativePath,
                to: localURL
            )
            return localURL
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            throw SourceError.connectionFailed(error.localizedDescription)
        }
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

            let ext = (item.name as NSString).pathExtension.lowercased()
            if PrimuseConstants.supportedAudioExtensions.contains(ext) {
                continuation.yield(item)
            }
        }
    }

    private func resolveClient() throws -> NFSClient {
        if let client {
            return client
        }

        let client = try makeClient()
        self.client = client
        return client
    }

    private func makeClient() throws -> NFSClient {
        var components = URLComponents()
        components.scheme = "nfs"
        components.host = host

        if let port, port > 0 {
            components.port = port
        }

        guard let url = components.url,
              let client = try NFSClient(url: url) else {
            throw SourceError.connectionFailed("Invalid NFS host")
        }

        return client
    }

    private func loadExports(forceRefresh: Bool = false) async throws -> [String] {
        if forceRefresh == false, let cachedExports, cachedExports.isEmpty == false {
            return cachedExports
        }

        let client = try resolveClient()
        let exports = try await withCheckedThrowingContinuation { continuation in
            client.listExports { result in
                continuation.resume(with: result)
            }
        }
        .map(NFSSelectionPathCodec.normalizedExportPath)
        .sorted { $0.localizedCompare($1) == .orderedAscending }

        if exports.isEmpty {
            throw SourceError.connectionFailed("No NFS exports found")
        }

        cachedExports = exports
        return exports
    }

    private func ensureConnected(to exportPath: String) async throws {
        let client = try resolveClient()
        let normalizedExportPath = NFSSelectionPathCodec.normalizedExportPath(exportPath)

        if connectedExportPath == normalizedExportPath {
            return
        }

        if let connectedExportPath {
            await disconnect(client: client, exportPath: connectedExportPath)
            self.connectedExportPath = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            client.connect(export: normalizedExportPath) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        connectedExportPath = normalizedExportPath
    }

    private func disconnect(client: NFSClient, exportPath: String) async {
        await withCheckedContinuation { continuation in
            client.disconnect(export: exportPath, gracefully: true) { _ in
                continuation.resume()
            }
        }
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
        let client = try resolveClient()
        try await ensureConnected(to: exportPath)

        return try await withCheckedThrowingContinuation { continuation in
            client.contentsOfDirectory(atPath: relativePath) { result in
                switch result {
                case .success(let entries):
                    let items = entries.compactMap { entry -> RemoteFileItem? in
                        guard let name = entry.name, name != ".", name != "..",
                              let remotePath = entry.path else {
                            return nil
                        }

                        let normalizedPath = NFSSelectionPathCodec.normalizedRelativePath(remotePath)
                        let isDirectory = entry.isDirectory || entry.fileResourceType == .directory

                        return RemoteFileItem(
                            name: name,
                            path: NFSSelectionPathCodec.makeSelectionPath(
                                exportPath: exportPath,
                                relativePath: normalizedPath
                            ),
                            isDirectory: isDirectory,
                            size: entry.fileSize ?? 0,
                            modifiedDate: entry.contentModificationDate
                                ?? entry.attributeModificationDate
                                ?? entry.creationDate
                        )
                    }
                    .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                    continuation.resume(returning: items)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func download(
        client: NFSClient,
        remotePath: String,
        to localURL: URL
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            client.downloadItem(atPath: remotePath, to: localURL, progress: { _, _ in true }) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func cacheFileName(for selection: NFSSelectionPathCodec.SelectionPath) -> String {
        let key = "\(selection.exportPath):\(selection.relativePath)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = (selection.relativePath as NSString).pathExtension
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }
}
