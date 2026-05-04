import Foundation
import PrimuseKit
import CryptoKit

/// S3-compatible storage source (AWS S3 / MinIO / Cloudflare R2 / Backblaze B2)
/// Uses AWS Signature V4 for authentication — pure Swift, no SDK dependency.
actor S3Source: MusicSourceConnector {
    let sourceID: String
    private let endpoint: String  // e.g. "s3.amazonaws.com" or "minio.example.com:9000"
    private let region: String
    private let bucket: String
    private let accessKey: String
    private let secretKey: String
    private let useSsl: Bool
    private let cacheDirectory: URL

    /// 长生命周期 session, fetchRange 复用 HTTP keep-alive。
    /// S3 协议天然支持 Range header (GetObject with Range), 不需要签名。
    private lazy var rangeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    init(
        sourceID: String, endpoint: String, region: String,
        bucket: String, accessKey: String, secretKey: String, useSsl: Bool
    ) {
        self.sourceID = sourceID
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.useSsl = useSsl

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("primuse_s3_cache/\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        // Test connection by listing root
        _ = try await listFiles(at: "")
    }

    func disconnect() async {}

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let prefix = path.isEmpty ? "" : (path.hasSuffix("/") ? path : "\(path)/")
        let scheme = useSsl ? "https" : "http"
        var components = URLComponents(string: "\(scheme)://\(endpoint)/\(bucket)")!
        components.queryItems = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "prefix", value: prefix),
            URLQueryItem(name: "delimiter", value: "/"),
            URLQueryItem(name: "max-keys", value: "1000"),
        ]
        guard let url = components.url else { throw SourceError.connectionFailed("Invalid URL") }

        let request = try signedRequest(url: url, method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SourceError.connectionFailed("S3 list failed: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        return parseListResponse(data: data, prefix: prefix)
    }

    func localURL(for path: String) async throws -> URL {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let cachedURL = cacheDirectory.appendingPathComponent(sanitized)
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        let scheme = useSsl ? "https" : "http"
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = URL(string: "\(scheme)://\(endpoint)/\(bucket)/\(encodedPath)")!
        let request = try signedRequest(url: url, method: "GET")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let (tempURL, response) = try await URLSession(configuration: config).download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SourceError.fileNotFound(path)
        }

        try? FileManager.default.removeItem(at: cachedURL)
        try FileManager.default.moveItem(at: tempURL, to: cachedURL)
        return cachedURL
    }

    /// HTTP Range GET on S3 GetObject。S3 协议规范支持 Range header
    /// (RFC 7233), 不算 signed header 不影响签名。让 CloudPlaybackSource
    /// 边下边播替代整文件下载。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let scheme = useSsl ? "https" : "http"
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "\(scheme)://\(endpoint)/\(bucket)/\(encodedPath)") else {
            throw SourceError.fileNotFound(path)
        }
        var request = try signedRequest(url: url, method: "GET")
        let rangeHeader = offset < 0
            ? "bytes=\(offset)"
            : "bytes=\(offset)-\(offset + length - 1)"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.timeoutInterval = 60

        let (data, response) = try await rangeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid S3 range response")
        }
        switch http.statusCode {
        case 206:
            return data
        case 200:
            let total = Int64(data.count)
            let actualOffset = offset < 0 ? max(0, total + offset) : offset
            guard actualOffset < total else { return Data() }
            let upper = min(actualOffset + length, total)
            return data.subdata(in: Int(actualOffset)..<Int(upper))
        default:
            throw SourceError.connectionFailed("S3 range request failed: HTTP \(http.statusCode)")
        }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { handle.closeFile() }
                    while true {
                        let data = handle.readData(ofLength: 64 * 1024)
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
        AsyncThrowingStream { continuation in
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

    // MARK: - S3 Signature V4

    private func signedRequest(url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: now)
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: now)

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(url.host ?? endpoint, forHTTPHeaderField: "Host")
        let payloadHash = SHA256.hash(data: Data()).compactMap { String(format: "%02x", $0) }.joined()
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Canonical request
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query ?? ""
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalHeaders = "host:\(url.host ?? endpoint)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let canonicalRequest = "\(method)\n\(path)\n\(query)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let canonicalHash = SHA256.hash(data: Data(canonicalRequest.utf8)).compactMap { String(format: "%02x", $0) }.joined()

        // String to sign
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(canonicalHash)"

        // Signing key
        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data("s3".utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let auth = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(auth, forHTTPHeaderField: "Authorization")

        return request
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    // MARK: - XML Parsing

    private func parseListResponse(data: Data, prefix: String) -> [RemoteFileItem] {
        let parser = S3ListParser(prefix: prefix)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.items
    }

    // MARK: - Private scan

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
}

// MARK: - S3 XML Response Parser

private class S3ListParser: NSObject, XMLParserDelegate {
    let prefix: String
    var items: [RemoteFileItem] = []

    private var currentElement = ""
    private var currentKey = ""
    private var currentSize: Int64 = 0
    private var currentPrefix = ""
    private var inContents = false
    private var inCommonPrefix = false

    init(prefix: String) {
        self.prefix = prefix
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = element
        if element == "Contents" { inContents = true; currentKey = ""; currentSize = 0 }
        if element == "CommonPrefixes" { inCommonPrefix = true; currentPrefix = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if inContents {
            if currentElement == "Key" { currentKey += trimmed }
            if currentElement == "Size" { currentSize = Int64(trimmed) ?? 0 }
        }
        if inCommonPrefix && currentElement == "Prefix" {
            currentPrefix += trimmed
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "Contents" && !currentKey.isEmpty {
            let name = (currentKey as NSString).lastPathComponent
            items.append(RemoteFileItem(name: name, path: currentKey, isDirectory: false, size: currentSize, modifiedDate: nil))
            inContents = false
        }
        if element == "CommonPrefixes" && !currentPrefix.isEmpty {
            let trimmedPrefix = currentPrefix.hasSuffix("/") ? String(currentPrefix.dropLast()) : currentPrefix
            let name = (trimmedPrefix as NSString).lastPathComponent
            items.append(RemoteFileItem(name: name, path: currentPrefix, isDirectory: true, size: 0, modifiedDate: nil))
            inCommonPrefix = false
        }
    }
}
