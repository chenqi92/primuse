import Foundation
import AMSMB2
import PrimuseKit

actor SMBSource: MusicSourceConnector {
    let sourceID: String
    private let host: String
    private let port: Int
    private let sharePath: String
    private let username: String
    private let password: String
    private var client: SMB2Manager?
    private var connectedShareName: String?
    private let cacheDirectory: URL

    private enum ResolvedPath {
        case serverRoot
        case share(name: String, relativePath: String)
    }

    init(sourceID: String, host: String, port: Int = 445, sharePath: String, username: String, password: String) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.sharePath = Self.normalizeShareName(sharePath)
        self.username = username
        self.password = password

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("primuse_smb_cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        _ = try await ensureServerConnection()

        if sharePath.isEmpty == false {
            _ = try await ensureConnectedShare(named: sharePath)
        }
    }

    func disconnect() async {
        if let client, connectedShareName != nil {
            try? await client.disconnectShare()
        }

        connectedShareName = nil
        client = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let normalizedPath = Self.normalizeRemotePath(path)
        _ = try await ensureServerConnection()

        switch try resolve(path: normalizedPath) {
        case .serverRoot:
            return try await listShares()
                .map { share in
                    RemoteFileItem(
                        name: share.name,
                        path: Self.appendPathComponent(share.name, to: normalizedPath),
                        isDirectory: true,
                        size: 0,
                        modifiedDate: nil
                    )
                }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        case .share(let shareName, let relativePath):
            let client = try await ensureConnectedShare(named: shareName)
            let items = try await client.contentsOfDirectory(atPath: relativePath)

            return items
                .filter { ($0[.nameKey] as? String)?.hasPrefix(".") == false }
                .map { item in
                    let name = item[.nameKey] as? String ?? ""
                    let isDir = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                    let size = item[.fileSizeKey] as? Int64 ?? 0
                    let modified = item[.contentModificationDateKey] as? Date

                    return RemoteFileItem(
                        name: name,
                        path: Self.appendPathComponent(name, to: normalizedPath),
                        isDirectory: isDir,
                        size: size,
                        modifiedDate: modified
                    )
                }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    func localURL(for path: String) async throws -> URL {
        let normalizedPath = Self.normalizeRemotePath(path)
        let resolvedPath = try resolve(path: normalizedPath)

        guard case let .share(shareName, relativePath) = resolvedPath else {
            throw SourceError.connectionFailed("SMB share not selected")
        }

        let client = try await ensureConnectedShare(named: shareName)
        let localURL = cacheDirectory.appendingPathComponent(
            Self.cacheFileName(for: normalizedPath)
        )

        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        try await client.downloadItem(atPath: relativePath, to: localURL) { _, _ in
            true
        }
        return localURL
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { handle.closeFile() }
                    let chunkSize = 64 * 1024
                    while true {
                        let data = handle.readData(ofLength: chunkSize)
                        if data.isEmpty { break }
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
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await scanDirectory(path: path, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func writeFile(data: Data, to path: String) async throws {
        let normalizedPath = Self.normalizeRemotePath(path)
        let resolvedPath = try resolve(path: normalizedPath)

        guard case let .share(shareName, relativePath) = resolvedPath else {
            throw SourceError.connectionFailed("SMB share not selected")
        }

        let client = try await ensureConnectedShare(named: shareName)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smb_upload_\(UUID().uuidString)")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await client.uploadItem(at: tempURL, toPath: relativePath) { _ in
            true
        }
    }

    private func scanDirectory(
        path: String,
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        let items = try await listFiles(at: path)

        for item in items {
            if item.isDirectory {
                try await scanDirectory(path: item.path, continuation: continuation)
            } else {
                let ext = (item.name as NSString).pathExtension.lowercased()
                if PrimuseConstants.supportedAudioExtensions.contains(ext) {
                    continuation.yield(item)
                }
            }
        }
    }

    private func ensureServerConnection() async throws -> SMB2Manager {
        if let client {
            return client
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverURL = try Self.buildSMBUrl(host: trimmedHost, port: port)
        NSLog("ℹ️ SMB connecting to \(serverURL.absoluteString) (original host: \(trimmedHost))")

        let credential = URLCredential(
            user: username,
            password: password,
            persistence: .forSession
        )

        guard let client = SMB2Manager(url: serverURL, credential: credential) else {
            throw SourceError.connectionFailed("Invalid SMB server configuration")
        }
        _ = try await client.listShares()

        self.client = client
        return client
    }

    private func ensureConnectedShare(named shareName: String) async throws -> SMB2Manager {
        let normalizedShareName = Self.normalizeShareName(shareName)
        guard normalizedShareName.isEmpty == false else {
            throw SourceError.connectionFailed("SMB share not selected")
        }

        let client = try await ensureServerConnection()
        if connectedShareName == normalizedShareName {
            return client
        }

        try await client.connectShare(name: normalizedShareName)
        connectedShareName = normalizedShareName
        return client
    }

    private func listShares() async throws -> [(name: String, comment: String)] {
        let client = try await ensureServerConnection()
        return try await client.listShares()
    }

    private func resolve(path: String) throws -> ResolvedPath {
        let normalizedPath = Self.normalizeRemotePath(path)

        if sharePath.isEmpty == false {
            let prefixedShareRoot = "/\(sharePath)"
            if normalizedPath == prefixedShareRoot {
                return .share(name: sharePath, relativePath: "/")
            }
            if normalizedPath.hasPrefix(prefixedShareRoot + "/") {
                let relativePath = String(normalizedPath.dropFirst(prefixedShareRoot.count))
                return .share(name: sharePath, relativePath: relativePath.isEmpty ? "/" : relativePath)
            }
            return .share(name: sharePath, relativePath: normalizedPath)
        }

        guard normalizedPath != "/" else {
            return .serverRoot
        }

        let components = normalizedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard let shareName = components.first else {
            return .serverRoot
        }

        let relativeComponents = components.dropFirst()
        let relativePath = relativeComponents.isEmpty ? "/" : "/" + relativeComponents.joined(separator: "/")
        return .share(name: shareName, relativePath: relativePath)
    }

    private static func normalizeShareName(_ shareName: String) -> String {
        shareName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func normalizeRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "/"
        }

        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard components.isEmpty == false else {
            return "/"
        }

        return "/" + components.joined(separator: "/")
    }

    private static func appendPathComponent(_ component: String, to path: String) -> String {
        let normalizedBase = normalizeRemotePath(path)
        let sanitizedComponent = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard sanitizedComponent.isEmpty == false else {
            return normalizedBase
        }

        if normalizedBase == "/" {
            return "/" + sanitizedComponent
        }

        return normalizedBase + "/" + sanitizedComponent
    }

    private static func cacheFileName(for path: String) -> String {
        normalizeRemotePath(path).replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - SMB URL Construction
    //
    // Supports hostname, IPv4, and IPv6. AMSMB2/libsmb2 has a bug where it
    // concatenates host:port as a flat string, breaking IPv6 (e.g. "::1:445").
    // Workaround: when the input is an IPv6 literal, resolve to IPv4 via
    // reverse-DNS → forward-DNS. If the host only has IPv6 (no IPv4 record),
    // pass the hostname (from reverse-DNS) so libsmb2 can resolve it natively.

    private static func buildSMBUrl(host: String, port: Int) throws -> URL {
        let isIPv4 = host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
        let isIPv6 = host.contains(":") && !isIPv4

        var connectHost = host

        if isIPv6 {
            if let hostname = reverseResolve(ipv6: host) {
                NSLog("ℹ️ SMB: Reverse DNS '\(host)' → '\(hostname)'")
                if let ipv4 = forwardResolveIPv4(hostname) {
                    NSLog("ℹ️ SMB: Resolved '\(hostname)' → '\(ipv4)'")
                    connectHost = ipv4
                } else {
                    NSLog("ℹ️ SMB: No IPv4 for '\(hostname)', using hostname directly")
                    connectHost = hostname
                }
            } else {
                NSLog("⚠️ SMB: Reverse DNS failed for '\(host)', using bracketed IPv6")
            }
        }

        let hostPart: String
        if connectHost.contains(":") {
            hostPart = "[\(connectHost)]"
        } else {
            hostPart = connectHost
        }

        let urlString = "smb://\(hostPart):\(port)"
        guard let url = URL(string: urlString) else {
            throw SourceError.connectionFailed("Invalid SMB URL: \(urlString)")
        }
        return url
    }

    private static func forwardResolveIPv4(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        defer { if result != nil { freeaddrinfo(result) } }

        guard status == 0, let addrInfo = result else { return nil }

        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            addrInfo.pointee.ai_addr,
            socklen_t(addrInfo.pointee.ai_addrlen),
            &buf,
            socklen_t(buf.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 else {
            return nil
        }

        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func reverseResolve(ipv6 address: String) -> String? {
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else { return nil }

        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getnameinfo(
                    sockPtr,
                    socklen_t(MemoryLayout<sockaddr_in6>.size),
                    &buf,
                    socklen_t(buf.count),
                    nil,
                    0,
                    0
                )
            }
        }
        guard rc == 0 else { return nil }
        let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.contains(":") ? nil : name
    }
}
