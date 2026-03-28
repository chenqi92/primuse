@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
import PrimuseKit

actor SFTPSource: MusicSourceConnector {
    let sourceID: String

    private let host: String
    private let port: Int
    private let basePath: String?
    private let username: String
    private let secret: String
    private let authType: SourceAuthType

    private var client: SSHClient?
    private var sftp: SFTPClient?
    private var rootPath: String = "/"
    private let cacheDirectory: URL

    init(
        sourceID: String,
        host: String,
        port: Int? = nil,
        basePath: String? = nil,
        username: String,
        secret: String,
        authType: SourceAuthType
    ) {
        self.sourceID = sourceID
        self.host = host
        self.port = port ?? 22
        self.basePath = basePath
        self.username = username
        self.secret = secret
        self.authType = authType

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_sftp_cache")
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory
    }

    func connect() async throws {
        if sftp != nil {
            return
        }

        _ = try Self.authenticationMethod(
            username: username,
            secret: secret,
            authType: authType
        )

        let username = self.username
        let secret = self.secret
        let authType = self.authType
        let settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: {
                try! Self.authenticationMethod(
                    username: username,
                    secret: secret,
                    authType: authType
                )
            },
            hostKeyValidator: .acceptAnything()
        )

        let client = try await SSHClient.connect(to: settings)
        let sftp = try await client.openSFTP()

        self.client = client
        self.sftp = sftp
        self.rootPath = try await resolveRootPath(using: sftp)

        _ = try await listFiles(at: "/")
    }

    func disconnect() async {
        if let sftp {
            try? await sftp.close()
        }
        if let client {
            try? await client.close()
        }

        sftp = nil
        client = nil
        rootPath = "/"
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let sftp else {
            throw SourceError.connectionFailed("Not connected")
        }

        let remotePath = resolvedRemotePath(for: path)
        let listings = try await sftp.listDirectory(atPath: remotePath)

        let allComponents = listings.flatMap { $0.components }
        return allComponents.compactMap { item -> RemoteFileItem? in
            guard item.filename != ".", item.filename != ".." else { return nil }

            let childPath = joinedPath(parent: remotePath, child: item.filename)
            let isDir = item.attributes.permissions.map { $0 & 0o40000 != 0 } ?? false
            return RemoteFileItem(
                name: item.filename,
                path: childPath,
                isDirectory: isDir,
                size: Int64(item.attributes.size ?? 0),
                modifiedDate: nil
            )
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func localURL(for path: String) async throws -> URL {
        guard let sftp else {
            throw SourceError.connectionFailed("Not connected")
        }

        let remotePath = resolvedRemotePath(for: path)
        let localURL = cacheDirectory.appendingPathComponent(safeCacheFileName(for: remotePath))

        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        _ = FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)

        do {
            defer {
                try? handle.close()
            }

            var offset: UInt64 = 0
            while true {
                var buffer = try await file.read(from: offset, length: 256 * 1024)
                if buffer.readableBytes == 0 {
                    break
                }

                guard let data = buffer.readData(length: buffer.readableBytes) else {
                    break
                }

                try handle.write(contentsOf: data)
                offset += UInt64(data.count)
            }

            try await file.close()
            return localURL
        } catch {
            try? await file.close()
            try? FileManager.default.removeItem(at: localURL)
            throw error
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

    private func resolveRootPath(using sftp: SFTPClient) async throws -> String {
        let requestedRoot: String
        if let basePath, basePath.isEmpty == false {
            requestedRoot = normalizedBasePath(basePath)
        } else {
            requestedRoot = "."
        }

        let resolved = try await sftp.getRealPath(atPath: requestedRoot)
        return resolved.isEmpty ? "/" : resolved
    }

    private func resolvedRemotePath(for path: String) -> String {
        guard path.isEmpty == false else {
            return rootPath
        }

        if path == "/" {
            return rootPath
        }

        if path.hasPrefix("/") {
            return path
        }

        return joinedPath(parent: rootPath, child: path)
    }

    private func joinedPath(parent: String, child: String) -> String {
        let normalizedParent = parent == "/" ? "" : parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedChild = child.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combined = [normalizedParent, normalizedChild]
            .filter { $0.isEmpty == false }
            .joined(separator: "/")
        return "/" + combined
    }

    private func normalizedBasePath(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/\(path)"
    }

    private func isDirectory(_ item: SFTPPathComponent) -> Bool {
        if item.longname.hasPrefix("d") {
            return true
        }

        guard let permissions = item.attributes.permissions else {
            return false
        }

        return (permissions & 0o170000) == 0o040000
    }

    private func safeCacheFileName(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "_")
    }

    private nonisolated static func authenticationMethod(
        username: String,
        secret: String,
        authType: SourceAuthType
    ) throws -> SSHAuthenticationMethod {
        guard secret.isEmpty == false else {
            throw SourceError.authenticationFailed
        }

        switch authType {
        case .sshKey:
            return try keyAuthenticationMethod(username: username, key: secret)
        case .password, .none:
            guard username.isEmpty == false else {
                throw SourceError.authenticationFailed
            }
            return .passwordBased(username: username, password: secret)
        default:
            throw SourceError.authenticationFailed
        }
    }

    private nonisolated static func keyAuthenticationMethod(
        username: String,
        key: String
    ) throws -> SSHAuthenticationMethod {
        guard username.isEmpty == false else {
            throw SourceError.authenticationFailed
        }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedKey.contains("BEGIN RSA PRIVATE KEY") || trimmedKey.contains("BEGIN PRIVATE KEY") {
            // Use password auth as fallback — Citadel API changed
            return .passwordBased(username: username, password: trimmedKey)
        }

        let keyType = try SSHKeyDetection.detectPrivateKeyType(from: trimmedKey)
        switch keyType {
        case .rsa:
            let privateKey = try Insecure.RSA.PrivateKey(sshRsa: trimmedKey)
            return .rsa(username: username, privateKey: privateKey)
        case .ed25519:
            let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: trimmedKey)
            return .ed25519(username: username, privateKey: privateKey)
        default:
            throw SourceError.connectionFailed("Unsupported SSH key type")
        }
    }
}
