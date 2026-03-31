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
    private let cacheDirectory: URL

    init(sourceID: String, host: String, port: Int = 445, sharePath: String, username: String, password: String) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.sharePath = sharePath
        self.username = username
        self.password = password

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("primuse_smb_cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        if client != nil {
            return
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverURL = try Self.buildSMBUrl(host: trimmedHost, port: port)
        NSLog("ℹ️ SMB connecting to \(serverURL.absoluteString) (original host: \(trimmedHost))")

        let credential = URLCredential(
            user: username,
            password: password,
            persistence: .forSession
        )

        client = SMB2Manager(url: serverURL, credential: credential)

        // Test connection by listing shares
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client?.listShares { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: SourceError.connectionFailed(error.localizedDescription))
                }
            }
        }

        // Connect to the specific share
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client?.connectShare(name: sharePath) { error in
                if let error {
                    continuation.resume(throwing: SourceError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func disconnect() async {
        client?.disconnectShare { _ in }
        client = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let client else { throw SourceError.connectionFailed("Not connected") }

        return try await withCheckedThrowingContinuation { continuation in
            client.contentsOfDirectory(atPath: path) { result in
                switch result {
                case .success(let items):
                    let fileItems = items
                        .filter { ($0[.nameKey] as? String)?.hasPrefix(".") == false }
                        .map { item -> RemoteFileItem in
                            let name = item[.nameKey] as? String ?? ""
                            let isDir = (item[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                            let size = item[.fileSizeKey] as? Int64 ?? 0
                            let modified = item[.contentModificationDateKey] as? Date

                            return RemoteFileItem(
                                name: name,
                                path: (path as NSString).appendingPathComponent(name),
                                isDirectory: isDir,
                                size: size,
                                modifiedDate: modified
                            )
                        }
                        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

                    continuation.resume(returning: fileItems)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func localURL(for path: String) async throws -> URL {
        guard let client else { throw SourceError.connectionFailed("Not connected") }

        let localURL = cacheDirectory.appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "_")
        )

        // Check if already cached
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        // Download file
        return try await withCheckedThrowingContinuation { continuation in
            client.downloadItem(atPath: path, to: localURL) { bytesReceived, totalBytes -> Bool in
                return true // continue downloading
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: localURL)
                }
            }
        }
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
            // Step 1: try reverse-DNS to get hostname (e.g. "LL-NAS.local")
            if let hostname = reverseResolve(ipv6: host) {
                NSLog("ℹ️ SMB: Reverse DNS '\(host)' → '\(hostname)'")
                // Step 2: try forward-resolve to IPv4
                if let ipv4 = forwardResolveIPv4(hostname) {
                    NSLog("ℹ️ SMB: Resolved '\(hostname)' → '\(ipv4)'")
                    connectHost = ipv4
                } else {
                    // No IPv4 record, but hostname itself works with libsmb2
                    NSLog("ℹ️ SMB: No IPv4 for '\(hostname)', using hostname directly")
                    connectHost = hostname
                }
            } else {
                NSLog("⚠️ SMB: Reverse DNS failed for '\(host)', using bracketed IPv6")
                // Last resort: bracketed IPv6 in URL (may still fail in libsmb2)
            }
        }

        // Build the URL string
        let hostPart: String
        if connectHost.contains(":") {
            hostPart = "[\(connectHost)]"  // Bracket IPv6 literals
        } else {
            hostPart = connectHost
        }

        let urlString = "smb://\(hostPart):\(port)"
        guard let url = URL(string: urlString) else {
            throw SourceError.connectionFailed("Invalid SMB URL: \(urlString)")
        }
        return url
    }

    /// Forward-resolve a hostname to an IPv4 address.
    private static func forwardResolveIPv4(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        defer { if result != nil { freeaddrinfo(result) } }

        guard status == 0, let addrInfo = result else { return nil }

        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addrInfo.pointee.ai_addr, socklen_t(addrInfo.pointee.ai_addrlen),
                          &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }

        return String(cString: buf)
    }

    /// Reverse-resolve an IPv6 address to a hostname (e.g. "LL-NAS.local").
    private static func reverseResolve(ipv6 address: String) -> String? {
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else { return nil }

        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getnameinfo(sockPtr, socklen_t(MemoryLayout<sockaddr_in6>.size),
                            &buf, socklen_t(buf.count), nil, 0, 0)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(cString: buf)
        // getnameinfo may return the numeric address back if no PTR record exists
        return name.contains(":") ? nil : name
    }

    func writeFile(data: Data, to path: String) async throws {
        guard let client else { throw SourceError.connectionFailed("Not connected") }

        // Write data to temp file first
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smb_upload_\(UUID().uuidString)")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.uploadItem(at: tempURL, toPath: path, progress: { _ in return true }) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
