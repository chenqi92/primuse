import CryptoKit
import Darwin
import Foundation
import PrimuseKit

actor UPnPSource: SongScanningConnector {
    let sourceID: String

    private let session: URLSession
    private let cacheDirectory: URL
    private var discoveredServers: [String: UPnPMediaServer] = [:]
    private var lastDiscoveryAt: Date?

    init(sourceID: String) {
        self.sourceID = sourceID

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
        self.session = URLSession(configuration: configuration)

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_upnp_cache")
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory
    }

    func connect() async throws {
        _ = try await discoverServers(forceRefresh: false)
    }

    func disconnect() async {
        discoveredServers.removeAll()
        lastDiscoveryAt = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        if path == "/" {
            let servers = try await discoverServers(forceRefresh: false)
            return servers.map { server in
                RemoteFileItem(
                    name: server.name,
                    path: makeSelectionPath(
                        serverID: server.id,
                        objectID: "0",
                        breadcrumbs: [server.name]
                    ),
                    isDirectory: true,
                    size: 0,
                    modifiedDate: nil
                )
            }
        }

        let selection = try parseSelectionPath(path)
        var containers: [RemoteFileItem] = []
        var startIndex = 0
        let pageSize = 200

        while true {
            let page = try await browseChildren(
                serverID: selection.serverID,
                objectID: selection.objectID,
                startIndex: startIndex,
                requestedCount: pageSize
            )

            for node in page.nodes where node.kind == .container {
                containers.append(
                    RemoteFileItem(
                        name: node.title,
                        path: makeSelectionPath(
                            serverID: selection.serverID,
                            objectID: node.objectID,
                            breadcrumbs: selection.breadcrumbs + [node.title]
                        ),
                        isDirectory: true,
                        size: 0,
                        modifiedDate: nil
                    )
                )
            }

            guard let nextStartIndex = nextStartIndex(
                currentStartIndex: startIndex,
                page: page,
                requestedCount: pageSize
            ) else {
                break
            }
            startIndex = nextStartIndex
        }

        return containers.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func localURL(for path: String) async throws -> URL {
        let remoteURL = try playbackURL(for: path)

        let localURL = cacheDirectory.appendingPathComponent(cacheFileName(for: remoteURL))
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        let (data, response) = try await session.data(from: remoteURL)
        try validate(response)
        try data.write(to: localURL, options: .atomic)
        return localURL
    }

    func streamingURL(for path: String) async throws -> URL? {
        try playbackURL(for: path)
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0 else { return Data() }

        let remoteURL = try playbackURL(for: path)
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if offset < 0 {
            request.setValue("bytes=\(offset)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid UPnP range response")
        }

        switch httpResponse.statusCode {
        case 206:
            return data
        case 200:
            let totalSize = Int64(data.count)
            let actualOffset = offset < 0 ? max(0, totalSize + offset) : offset
            guard actualOffset < totalSize else { return Data() }
            let upperBound = min(actualOffset + length, totalSize)
            return data.subdata(in: Int(actualOffset)..<Int(upperBound))
        default:
            throw SourceError.connectionFailed("UPnP range request failed: HTTP \(httpResponse.statusCode)")
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

    private func playbackURL(for path: String) throws -> URL {
        guard let remoteURL = URL(string: path), remoteURL.scheme?.hasPrefix("http") == true else {
            throw SourceError.fileNotFound(path)
        }
        return remoteURL
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let stream = try await scanSongs(from: path)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await scannedSong in stream {
                        continuation.yield(
                            RemoteFileItem(
                                name: scannedSong.displayName,
                                path: scannedSong.song.filePath,
                                isDirectory: false,
                                size: scannedSong.song.fileSize,
                                modifiedDate: scannedSong.song.lastModified
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        let selection = try parseSelectionPath(path)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await scanContainer(
                        serverID: selection.serverID,
                        objectID: selection.objectID,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func scanContainer(
        serverID: String,
        objectID: String,
        continuation: AsyncThrowingStream<ConnectorScannedSong, Error>.Continuation
    ) async throws {
        var startIndex = 0
        let pageSize = 200

        while true {
            try Task.checkCancellation()
            let page = try await browseChildren(
                serverID: serverID,
                objectID: objectID,
                startIndex: startIndex,
                requestedCount: pageSize
            )

            for node in page.nodes {
                switch node.kind {
                case .container:
                    try Task.checkCancellation()
                    try await scanContainer(
                        serverID: serverID,
                        objectID: node.objectID,
                        continuation: continuation
                    )
                case .item:
                    guard let song = buildSong(serverID: serverID, node: node) else {
                        continue
                    }
                    continuation.yield(
                        ConnectorScannedSong(
                            song: song,
                            displayName: song.title
                        )
                    )
                }
            }

            guard let nextStartIndex = nextStartIndex(
                currentStartIndex: startIndex,
                page: page,
                requestedCount: pageSize
            ) else {
                break
            }
            startIndex = nextStartIndex
        }
    }

    private func buildSong(serverID: String, node: UPnPNode) -> Song? {
        guard node.kind == .item, let resourceURL = node.resourceURL else {
            return nil
        }

        let format = audioFormat(for: resourceURL, protocolInfo: node.protocolInfo)
        guard let format else {
            return nil
        }

        let songID = hash("\(sourceID):\(resourceURL.absoluteString)")
        let artistID = node.artist.map { hash($0.lowercased()) }
        let albumID: String? = if let artist = node.artist, let album = node.album {
            hash("\(artist.lowercased()):\(album.lowercased())")
        } else {
            nil
        }

        return Song(
            id: songID,
            title: node.title,
            albumID: albumID,
            artistID: artistID,
            albumTitle: node.album,
            artistName: node.artist,
            trackNumber: node.trackNumber,
            discNumber: nil,
            duration: parseDuration(node.durationString),
            fileFormat: format,
            filePath: resourceURL.absoluteString,
            sourceID: sourceID,
            fileSize: Int64(node.size ?? 0),
            bitRate: node.bitrate,
            sampleRate: node.sampleRate,
            bitDepth: node.bitDepth,
            genre: nil,
            year: parseYear(node.dateString),
            lastModified: parseDate(node.dateString),
            dateAdded: Date(),
            coverArtFileName: node.albumArtURL?.absoluteString,
            lyricsFileName: nil
        )
    }

    private func browseChildren(
        serverID: String,
        objectID: String,
        startIndex: Int,
        requestedCount: Int
    ) async throws -> BrowsePage {
        let server = try await server(for: serverID)
        let request = makeBrowseRequest(
            controlURL: server.controlURL,
            objectID: objectID,
            startIndex: startIndex,
            requestedCount: requestedCount
        )

        let (data, response) = try await session.data(for: request)
        try validate(response)

        let soapResult = try SOAPBrowseResponseParser.parse(data: data)
        let nodes = try DIDLParser.parse(
            xmlString: soapResult.resultXML,
            baseURL: server.baseURL
        )

        return BrowsePage(
            nodes: nodes,
            numberReturned: soapResult.numberReturned,
            totalMatches: soapResult.totalMatches
        )
    }

    private func nextStartIndex(
        currentStartIndex: Int,
        page: BrowsePage,
        requestedCount: Int
    ) -> Int? {
        let returnedCount = max(page.numberReturned, page.nodes.count)
        guard page.nodes.isEmpty == false, returnedCount > 0 else {
            return nil
        }

        let nextStartIndex = currentStartIndex + returnedCount
        if page.totalMatches > 0 {
            return nextStartIndex < page.totalMatches ? nextStartIndex : nil
        }

        return returnedCount >= requestedCount ? nextStartIndex : nil
    }

    private func server(for serverID: String) async throws -> UPnPMediaServer {
        if let server = discoveredServers[serverID] {
            return server
        }

        _ = try await discoverServers(forceRefresh: true)
        if let server = discoveredServers[serverID] {
            return server
        }

        throw SourceError.connectionFailed("UPnP media server is offline")
    }

    private func discoverServers(forceRefresh: Bool) async throws -> [UPnPMediaServer] {
        if forceRefresh == false,
           let lastDiscoveryAt,
           Date().timeIntervalSince(lastDiscoveryAt) < 120,
           discoveredServers.isEmpty == false {
            return discoveredServers.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }

        let responses = try await discoverSSDPResponses()
        var servers: [String: UPnPMediaServer] = [:]

        for response in responses {
            guard let location = response.location else {
                continue
            }

            do {
                let server = try await fetchServer(at: location)
                servers[server.id] = server
            } catch {
                continue
            }
        }

        guard servers.isEmpty == false else {
            throw SourceError.connectionFailed("No UPnP media servers found")
        }

        discoveredServers = servers
        lastDiscoveryAt = Date()
        return servers.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func fetchServer(at location: URL) async throws -> UPnPMediaServer {
        let (data, response) = try await session.data(from: location)
        try validate(response)

        let description = try UPnPDeviceDescriptionParser.parse(data: data, location: location)
        guard let contentDirectory = description.services.first(where: { $0.serviceType.contains("ContentDirectory") }) else {
            throw SourceError.connectionFailed("UPnP server does not expose ContentDirectory")
        }

        let serverID = description.udn.isEmpty == false ? description.udn : location.absoluteString
        return UPnPMediaServer(
            id: serverID,
            name: description.friendlyName.isEmpty ? (location.host ?? "UPnP Server") : description.friendlyName,
            baseURL: description.baseURL ?? location.deletingLastPathComponent(),
            controlURL: contentDirectory.controlURL
        )
    }

    private func makeBrowseRequest(
        controlURL: URL,
        objectID: String,
        startIndex: Int,
        requestedCount: Int
    ) -> URLRequest {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
              <ObjectID>\(escapeXML(objectID))</ObjectID>
              <BrowseFlag>BrowseDirectChildren</BrowseFlag>
              <Filter>*</Filter>
              <StartingIndex>\(startIndex)</StartingIndex>
              <RequestedCount>\(requestedCount)</RequestedCount>
              <SortCriteria></SortCriteria>
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.httpBody = Data(envelope.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"", forHTTPHeaderField: "SOAPACTION")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid server response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SourceError.connectionFailed("HTTP \(httpResponse.statusCode)")
        }
    }

    private func makeSelectionPath(
        serverID: String,
        objectID: String,
        breadcrumbs: [String]
    ) -> String {
        let displayPath = "/" + breadcrumbs.map(sanitizePathComponent).joined(separator: "/")
        return "upnp::\(encodeToken(serverID))::\(encodeToken(objectID))::\(displayPath)"
    }

    private func parseSelectionPath(_ path: String) throws -> SelectionPath {
        guard path.hasPrefix("upnp::") else {
            throw SourceError.pathNotFound(path)
        }

        let payload = String(path.dropFirst("upnp::".count))
        guard let firstSeparator = payload.range(of: "::"),
              let secondSeparator = payload[firstSeparator.upperBound...].range(of: "::") else {
            throw SourceError.pathNotFound(path)
        }

        let serverToken = String(payload[..<firstSeparator.lowerBound])
        let objectToken = String(payload[firstSeparator.upperBound..<secondSeparator.lowerBound])
        let displayPath = String(payload[secondSeparator.upperBound...])

        let breadcrumbs = displayPath
            .split(separator: "/")
            .map { unsanitizePathComponent(String($0)) }

        guard let serverID = decodeToken(serverToken),
              let objectID = decodeToken(objectToken) else {
            throw SourceError.pathNotFound(path)
        }

        return SelectionPath(
            serverID: serverID,
            objectID: objectID,
            breadcrumbs: breadcrumbs
        )
    }

    private func sanitizePathComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "∕")
            .replacingOccurrences(of: ":", with: "꞉")
    }

    private func unsanitizePathComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "∕", with: "/")
            .replacingOccurrences(of: "꞉", with: ":")
    }

    private func encodeToken(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeToken(_ value: String) -> String? {
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

    private func cacheFileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        return "\(hash).\(ext)"
    }

    private func hash(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func parseDuration(_ value: String?) -> TimeInterval {
        guard let value, value.isEmpty == false else {
            return 0
        }

        let parts = value.split(separator: ":")
        guard parts.count >= 2 else {
            return 0
        }

        var multiplier: Double = 1
        var total: Double = 0
        for part in parts.reversed() {
            total += (Double(String(part)) ?? 0) * multiplier
            multiplier *= 60
        }
        return total
    }

    private func parseYear(_ value: String?) -> Int? {
        guard let value else {
            return nil
        }

        let yearPrefix = value.prefix(4)
        return Int(String(yearPrefix))
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value, value.isEmpty == false else {
            return nil
        }

        let isoParser = ISO8601DateFormatter()
        if let date = isoParser.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: value)
    }

    private func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private nonisolated func discoverSSDPResponses() async throws -> [SSDPDiscoveryResponse] {
        // The SSDP discovery uses a blocking recv loop (SO_RCVTIMEO=2s, reset on each
        // packet) that must not run on a Swift Concurrency cooperative thread: it would
        // pin that thread and freeze the actor for the whole discovery window. Hop onto a
        // dedicated background queue and suspend the caller until it finishes.
        try await withCheckedThrowingContinuation { continuation in
            ssdpDiscoveryQueue.async {
                do {
                    let responses = try Self.performSSDPDiscovery()
                    continuation.resume(returning: responses)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func performSSDPDiscovery() throws -> [SSDPDiscoveryResponse] {
        let socketFD = socket(AF_INET, Int32(SOCK_DGRAM), IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw SourceError.connectionFailed("Unable to open SSDP socket")
        }
        defer { Darwin.close(socketFD) }

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = in_port_t(0).bigEndian
        bindAddress.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &bindAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw SourceError.connectionFailed("Unable to bind SSDP socket")
        }

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(1900).bigEndian
        target.sin_addr = in_addr(s_addr: inet_addr("239.255.255.250"))

        var didSendDiscovery = false
        for searchTarget in upnpSSDPSearchTargets {
            let request = [
                "M-SEARCH * HTTP/1.1",
                "HOST: 239.255.255.250:1900",
                "MAN: \"ssdp:discover\"",
                "MX: 2",
                "ST: \(searchTarget)",
                "USER-AGENT: Primuse/1.0 UPnP/1.1",
                "",
                "",
            ].joined(separator: "\r\n")

            let sendResult = request.withCString { pointer in
                withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socketFD, pointer, strlen(pointer), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            didSendDiscovery = didSendDiscovery || sendResult >= 0
        }
        guard didSendDiscovery else {
            throw SourceError.connectionFailed("Unable to send SSDP discovery")
        }

        var responses: [String: SSDPDiscoveryResponse] = [:]
        while true {
            let bufferSize = 8192
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let byteCount = buffer.withUnsafeMutableBufferPointer { rawBuffer in
                recv(socketFD, rawBuffer.baseAddress, bufferSize, 0)
            }
            if byteCount <= 0 {
                break
            }

            guard let text = String(bytes: buffer.prefix(Int(byteCount)), encoding: .utf8) else {
                continue
            }

            let response = SSDPDiscoveryResponse(text: text)
            let key = response.location?.absoluteString ?? response.usn
            if !key.isEmpty {
                responses[key] = response
            }
        }

        return Array(responses.values)
    }
}

private let upnpSSDPSearchTargets = [
    "urn:schemas-upnp-org:device:MediaServer:1",
    "urn:schemas-upnp-org:service:ContentDirectory:1",
    "upnp:rootdevice",
    "ssdp:all",
]

private let ssdpDiscoveryQueue = DispatchQueue(
    label: "com.primuse.upnp.ssdp-discovery",
    qos: .utility
)

private func audioFormat(for url: URL, protocolInfo: String?) -> AudioFormat? {
    let ext = url.pathExtension.lowercased()
    return AudioFormat.from(fileExtension: ext) ?? audioFormat(fromProtocolInfo: protocolInfo)
}

private func audioFormat(fromProtocolInfo protocolInfo: String?) -> AudioFormat? {
    guard let protocolInfo, protocolInfo.isEmpty == false else {
        return nil
    }

    let mimeCandidate: String
    let parts = protocolInfo.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count >= 3 {
        mimeCandidate = String(parts[2])
    } else {
        mimeCandidate = protocolInfo
    }

    let mimeType = mimeCandidate
        .split(separator: ";", maxSplits: 1)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    switch mimeType {
    case "audio/flac", "audio/x-flac", "application/flac":
        return .flac
    case "audio/alac", "audio/x-alac":
        return .alac
    case "audio/x-wav", "audio/wav", "audio/wave", "audio/vnd.wave":
        return .wav
    case "audio/aiff", "audio/x-aiff":
        return .aiff
    case "audio/aac", "audio/aacp", "audio/mp4a-latm":
        return .aac
    case "audio/mp4", "audio/x-m4a", "audio/m4a":
        return .m4a
    case "audio/ogg", "application/ogg":
        return .ogg
    case "audio/opus":
        return .opus
    case "audio/x-ms-wma":
        return .wma
    case "audio/mpeg", "audio/mp3", "audio/x-mpeg", "audio/mpeg3":
        return .mp3
    case "audio/x-ape", "audio/ape", "audio/x-monkeys-audio":
        return .ape
    case "audio/x-wavpack", "audio/wavpack":
        return .wv
    case "audio/x-dsf", "audio/dsf":
        return .dsf
    case "audio/x-dff", "audio/dff":
        return .dff
    default:
        return nil
    }
}

private struct BrowsePage: Sendable {
    let nodes: [UPnPNode]
    let numberReturned: Int
    let totalMatches: Int
}

private struct SelectionPath: Sendable {
    let serverID: String
    let objectID: String
    let breadcrumbs: [String]
}

private struct SSDPDiscoveryResponse: Sendable {
    let location: URL?
    let usn: String

    init(text: String) {
        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let rawLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = rawLine.firstIndex(of: ":") else {
                continue
            }

            let key = rawLine[..<separator].uppercased()
            let value = rawLine[rawLine.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        self.location = headers["LOCATION"].flatMap(URL.init(string:))
        self.usn = headers["USN"] ?? ""
    }
}

private struct UPnPMediaServer: Sendable {
    let id: String
    let name: String
    let baseURL: URL
    let controlURL: URL
}

private struct UPnPDeviceDescription: Sendable {
    struct Service: Sendable {
        let serviceType: String
        let controlURL: URL
    }

    let friendlyName: String
    let udn: String
    let baseURL: URL?
    let services: [Service]
}

private enum UPnPNodeKind: Sendable {
    case container
    case item
}

private struct UPnPNode: Sendable {
    let kind: UPnPNodeKind
    let objectID: String
    let title: String
    let className: String?
    let artist: String?
    let album: String?
    let resourceURL: URL?
    let albumArtURL: URL?
    let durationString: String?
    let protocolInfo: String?
    let dateString: String?
    let trackNumber: Int?
    let size: UInt64?
    let bitrate: Int?
    let sampleRate: Int?
    let bitDepth: Int?
}

private struct UPnPResource: Sendable {
    let url: URL
    let protocolInfo: String?
    let durationString: String?
    let size: UInt64?
    let bitrate: Int?
    let sampleRate: Int?
    let bitDepth: Int?
}

private enum SOAPBrowseResponseParser {
    static func parse(data: Data) throws -> (resultXML: String, numberReturned: Int, totalMatches: Int) {
        let parserDelegate = SOAPBrowseResponseParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = parserDelegate

        guard parser.parse() else {
            throw parser.parserError ?? SourceError.connectionFailed("Invalid UPnP browse response")
        }

        return (
            resultXML: parserDelegate.resultXML,
            numberReturned: parserDelegate.numberReturned,
            totalMatches: parserDelegate.totalMatches
        )
    }
}

private final class SOAPBrowseResponseParserDelegate: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""

    var resultXML = ""
    var numberReturned = 0
    var totalMatches = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Result":
            resultXML = text
        case "NumberReturned":
            numberReturned = Int(text) ?? 0
        case "TotalMatches":
            totalMatches = Int(text) ?? 0
        default:
            break
        }
        currentText = ""
    }
}

private enum DIDLParser {
    static func parse(xmlString: String, baseURL: URL) throws -> [UPnPNode] {
        guard let data = xmlString.data(using: .utf8) else {
            throw SourceError.connectionFailed("Invalid DIDL-Lite response")
        }

        let delegate = DIDLParserDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate

        guard parser.parse() else {
            throw parser.parserError ?? SourceError.connectionFailed("Invalid DIDL-Lite response")
        }

        return delegate.nodes
    }
}

private final class DIDLParserDelegate: NSObject, XMLParserDelegate {
    private struct Builder {
        var kind: UPnPNodeKind
        var objectID: String
        var title: String = ""
        var className: String?
        var artist: String?
        var album: String?
        var albumArtURL: URL?
        var dateString: String?
        var trackNumber: Int?
        var resources: [UPnPResource] = []
    }

    private struct ResourceBuilder {
        var protocolInfo: String?
        var durationString: String?
        var size: UInt64?
        var bitrate: Int?
        var sampleRate: Int?
        var bitDepth: Int?
    }

    private let baseURL: URL
    private var currentElement = ""
    private var currentText = ""
    private var currentNode: Builder?
    private var currentResource: ResourceBuilder?

    private(set) var nodes: [UPnPNode] = []

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "container":
            currentNode = Builder(
                kind: .container,
                objectID: attributeDict["id"] ?? UUID().uuidString
            )
        case "item":
            currentNode = Builder(
                kind: .item,
                objectID: attributeDict["id"] ?? UUID().uuidString
            )
        case "res":
            currentResource = ResourceBuilder(
                protocolInfo: attributeDict["protocolInfo"],
                durationString: attributeDict["duration"],
                size: attributeDict["size"].flatMap(UInt64.init),
                bitrate: attributeDict["bitrate"].flatMap(Int.init),
                sampleRate: attributeDict["sampleFrequency"].flatMap(Int.init),
                bitDepth: attributeDict["bitsPerSample"].flatMap(Int.init)
            )
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var node = currentNode else {
            currentText = ""
            return
        }

        switch elementName {
        case "title":
            if node.title.isEmpty {
                node.title = text
            }
        case "class":
            node.className = text
        case "artist", "creator":
            if node.artist == nil, text.isEmpty == false {
                node.artist = text
            }
        case "album":
            node.album = text
        case "albumArtURI":
            if node.albumArtURL == nil, let url = resolveURL(text, baseURL: baseURL) {
                node.albumArtURL = url
            }
        case "originalTrackNumber":
            node.trackNumber = Int(text)
        case "date":
            node.dateString = text
        case "res":
            if let currentResource, let url = resolveURL(text, baseURL: baseURL) {
                node.resources.append(
                    UPnPResource(
                        url: url,
                        protocolInfo: currentResource.protocolInfo,
                        durationString: currentResource.durationString,
                        size: currentResource.size,
                        bitrate: currentResource.bitrate,
                        sampleRate: currentResource.sampleRate,
                        bitDepth: currentResource.bitDepth
                    )
                )
            }
            currentResource = nil
        case "container", "item":
            if node.title.isEmpty {
                node.title = "Unknown"
            }
            let selectedResource = selectBestResource(from: node.resources)
            nodes.append(
                UPnPNode(
                    kind: node.kind,
                    objectID: node.objectID,
                    title: node.title,
                    className: node.className,
                    artist: node.artist,
                    album: node.album,
                    resourceURL: selectedResource?.url,
                    albumArtURL: node.albumArtURL,
                    durationString: selectedResource?.durationString,
                    protocolInfo: selectedResource?.protocolInfo,
                    dateString: node.dateString,
                    trackNumber: node.trackNumber,
                    size: selectedResource?.size,
                    bitrate: selectedResource?.bitrate,
                    sampleRate: selectedResource?.sampleRate,
                    bitDepth: selectedResource?.bitDepth
                )
            )
            currentNode = nil
        default:
            break
        }

        currentNode = node
        if elementName == "container" || elementName == "item" {
            currentNode = nil
        }
        currentText = ""
    }

    private func resolveURL(_ value: String, baseURL: URL) -> URL? {
        guard value.isEmpty == false else {
            return nil
        }

        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }

        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private func selectBestResource(from resources: [UPnPResource]) -> UPnPResource? {
        let playableResources = resources.filter {
            audioFormat(for: $0.url, protocolInfo: $0.protocolInfo) != nil
        }
        let candidates = playableResources.isEmpty ? resources : playableResources

        return candidates.first {
            let scheme = $0.url.scheme?.lowercased()
            return scheme == "http" || scheme == "https"
        } ?? candidates.first
    }
}

private enum UPnPDeviceDescriptionParser {
    static func parse(data: Data, location: URL) throws -> UPnPDeviceDescription {
        let delegate = UPnPDeviceDescriptionParserDelegate(location: location)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate

        guard parser.parse() else {
            throw parser.parserError ?? SourceError.connectionFailed("Invalid UPnP device description")
        }

        return UPnPDeviceDescription(
            friendlyName: delegate.friendlyName,
            udn: delegate.udn,
            baseURL: delegate.baseURL,
            services: delegate.services
        )
    }
}

private final class UPnPDeviceDescriptionParserDelegate: NSObject, XMLParserDelegate {
    private struct ServiceBuilder {
        var serviceType: String = ""
        var controlURL: String = ""
    }

    private let location: URL
    private var currentElement = ""
    private var currentText = ""
    private var currentService: ServiceBuilder?

    private(set) var friendlyName = ""
    private(set) var udn = ""
    private(set) var baseURL: URL?
    private(set) var services: [UPnPDeviceDescription.Service] = []

    init(location: URL) {
        self.location = location
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""
        if elementName == "service" {
            currentService = ServiceBuilder()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "URLBase":
            if baseURL == nil, let url = URL(string: text) {
                baseURL = url
            }
        case "friendlyName":
            if currentService == nil, friendlyName.isEmpty {
                friendlyName = text
            }
        case "UDN":
            if currentService == nil, udn.isEmpty {
                udn = text
            }
        case "serviceType":
            currentService?.serviceType = text
        case "controlURL":
            currentService?.controlURL = text
        case "service":
            if let service = currentService,
               let controlURL = resolveURL(service.controlURL) {
                services.append(
                    UPnPDeviceDescription.Service(
                        serviceType: service.serviceType,
                        controlURL: controlURL
                    )
                )
            }
            currentService = nil
        default:
            break
        }
        currentText = ""
    }

    private func resolveURL(_ value: String) -> URL? {
        guard value.isEmpty == false else {
            return nil
        }

        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }

        let baseURL = baseURL ?? location.deletingLastPathComponent()
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }
}
