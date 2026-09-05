import Foundation

public final class WiFiTransferClient: @unchecked Sendable {
    private let baseURL: URL
    private let code: String
    private let session: URLSession

    public init(address: String, code: String) throws {
        guard let url = Self.localURL(address), code.count == 6, code.allSatisfy(\.isNumber) else {
            throw WiFiTransferError.invalidAddress
        }
        baseURL = url
        self.code = code
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    deinit { session.invalidateAndCancel() }

    public static func localURL(_ address: String) -> URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text.contains("://") ? text : "http://" + text),
              parts.scheme == "http", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let host = parts.host else { return nil }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = octets.compactMap { part -> Int? in
            guard let value = Int(part), (0...255).contains(value), String(value) == part else { return nil }
            return value
        }
        guard bytes.count == 4,
              bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254),
              parts.port.map({ (1...65535).contains($0) }) ?? false else { return nil }
        return parts.url
    }

    public func destination() async throws -> WiFiTransferDestination {
        try await json(request("GET", route: "/api/info"))
    }

    public func invite(sender: String, fileCount: Int, byteCount: Int64) async throws -> WiFiTransferTicket {
        var request = request("POST", route: "/api/transfer")
        request.setValue(String(sender.prefix(60)).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), forHTTPHeaderField: "X-Primuse-Sender")
        request.setValue(String(fileCount), forHTTPHeaderField: "X-Primuse-File-Count")
        request.setValue(String(byteCount), forHTTPHeaderField: "X-Primuse-Byte-Count")
        return try await json(request)
    }

    public func waitForAcceptance(_ ticket: String) async throws {
        for _ in 0..<120 {
            try Task.checkCancellation()
            let state: WiFiTransferTicket = try await json(request("GET", route: "/api/transfer", path: ticket))
            if state.state == "accepted" { return }
            if state.state == "rejected" { throw WiFiTransferError.rejected }
            try await Task.sleep(for: .seconds(1))
        }
        throw WiFiTransferError.unavailable
    }

    public func upload(file: URL, path: String, size: Int64, ticket: String,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = request("PUT", route: "/api/files", path: path)
        request.setValue(ticket, forHTTPHeaderField: "X-Primuse-Transfer")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.upload(for: request, fromFile: file, delegate: UploadProgress(progress))
        try validate(data, response)
    }

    public func finish(_ ticket: String) async {
        _ = try? await session.data(for: request("DELETE", route: "/api/transfer", path: ticket))
    }

    private func request(_ method: String, route: String, path: String = "") -> URLRequest {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.path = route
        parts.queryItems = [URLQueryItem(name: "path", value: path)]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.setValue(code, forHTTPHeaderField: "X-Primuse-Code")
        return request
    }

    private func json<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(data, response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validate(_ data: Data, _ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw WiFiTransferError.unavailable }
        guard (200..<300).contains(response.statusCode) else {
            let body = try? JSONDecoder().decode([String: String].self, from: data)
            throw body?["error"].flatMap(WiFiTransferError.init(rawValue:)) ?? .unavailable
        }
    }

    private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let update: @Sendable (Int64) -> Void
        init(_ update: @escaping @Sendable (Int64) -> Void) { self.update = update }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            update(totalBytesSent)
        }
    }
}

public struct WiFiTransferOutgoingFile: Identifiable, Sendable {
    public let url: URL
    public let path: String
    public let size: Int64
    public var id: String { url.path }
}

/// Owns the security scopes for the whole selection, including any folder descendants.
public final class WiFiTransferSelection: @unchecked Sendable {
    public let files: [WiFiTransferOutgoingFile]
    public let skipped: Int
    public var byteCount: Int64 { files.reduce(0) { $0 + $1.size } }
    private let scopes: [URL]

    private init(files: [WiFiTransferOutgoingFile], skipped: Int, scopes: [URL]) {
        self.files = files
        self.skipped = skipped
        self.scopes = scopes
    }

    deinit { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }

    public static func prepare(_ urls: [URL]) async throws -> WiFiTransferSelection {
        let scopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        do {
            let worker = Task.detached(priority: .utility) {
                let fm = FileManager.default
                var files: [WiFiTransferOutgoingFile] = []
                var skipped = 0
                var seen = Set<String>()
                var pending = urls.map { ($0, $0.lastPathComponent) }
                while let (url, path) = pending.popLast() {
                    try Task.checkCancellation()
                    guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard !url.lastPathComponent.hasPrefix("."), values.isSymbolicLink != true else { skipped += 1; continue }
                    guard path.split(separator: "/").count <= 32, files.count < 10000 else { throw WiFiTransferError.tooLarge }
                    if values.isDirectory == true {
                        let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        pending += children.map { ($0, path + "/" + $0.lastPathComponent) }
                    } else if values.isRegularFile == true, WiFiTransferFiles.extensions.contains(url.pathExtension.lowercased()) {
                        let size = Int64(values.fileSize ?? 0)
                        guard size > 0, size <= WiFiTransferFiles.maximumFileSize else { throw WiFiTransferError.tooLarge }
                        files.append(.init(url: url, path: path, size: size))
                    } else { skipped += 1 }
                }
                return WiFiTransferSelection(files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, skipped: skipped, scopes: scopes)
            }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        } catch {
            scopes.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    public static func stage(_ file: WiFiTransferOutgoingFile, in directory: URL) async throws -> URL {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let target = directory.appendingPathComponent(UUID().uuidString)
            var coordinationError: NSError?
            var readError: Error?
            NSFileCoordinator().coordinate(readingItemAt: file.url, options: [], error: &coordinationError) { url in
                do {
                    guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw WiFiTransferError.notEnoughSpace }
                    let input = try FileHandle(forReadingFrom: url)
                    defer { try? input.close() }
                    let output = try FileHandle(forWritingTo: target)
                    defer { try? output.close() }
                    var count: Int64 = 0
                    while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
                        try Task.checkCancellation()
                        count += Int64(data.count)
                        guard count <= file.size else { throw WiFiTransferError.invalidRequest }
                        try output.write(contentsOf: data)
                    }
                    guard count == file.size else { throw WiFiTransferError.invalidRequest }
                } catch { readError = error }
            }
            if let error = coordinationError ?? readError as NSError? {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            return target
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
