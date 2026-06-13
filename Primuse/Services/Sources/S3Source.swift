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

    /// 长生命周期 session, fetchRange / localURL 复用 HTTP keep-alive。
    /// S3 协议天然支持 Range header (GetObject with Range), 不需要签名。
    /// disconnect() 中 finishTasksAndInvalidate(), 避免 session/线程/fd 泄漏。
    private var _rangeSession: URLSession?
    private var rangeSession: URLSession {
        if let session = _rangeSession { return session }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        let session = URLSession(configuration: config)
        _rangeSession = session
        return session
    }

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

    func disconnect() async {
        // 自建 session 必须显式 invalidate, 否则其内部工作队列/连接缓存
        // 在进程退出前不会释放 (connector 反复重建时累积线程/fd)。
        _rangeSession?.finishTasksAndInvalidate()
        _rangeSession = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let prefix = path.isEmpty ? "" : (path.hasSuffix("/") ? path : "\(path)/")
        var items: [RemoteFileItem] = []
        // ListObjectsV2 caps a single response at max-keys (≤1000) and signals
        // more pages via IsTruncated / NextContinuationToken. A flat directory
        // with >1000 entries would otherwise return only the first page, and
        // ConnectorScanner treats the missing songs as deleted. Follow the
        // continuation token until the listing is complete.
        var continuationToken: String? = nil
        repeat {
            guard var components = URLComponents(url: try bucketURL(), resolvingAgainstBaseURL: false) else {
                throw SourceError.connectionFailed("Invalid S3 URL")
            }
            var queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
                URLQueryItem(name: "delimiter", value: "/"),
                URLQueryItem(name: "max-keys", value: "1000"),
            ]
            if let token = continuationToken {
                queryItems.append(URLQueryItem(name: "continuation-token", value: token))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw SourceError.connectionFailed("Invalid URL") }

            let request = try signedRequest(url: url, method: "GET")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw SourceError.connectionFailed("S3 list failed: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }

            let page = parseListResponse(data: data, prefix: prefix)
            items.append(contentsOf: page.items)
            continuationToken = page.isTruncated ? page.nextContinuationToken : nil
        } while continuationToken != nil

        return items
    }

    func localURL(for path: String) async throws -> URL {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let cachedURL = cacheDirectory.appendingPathComponent(sanitized)
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        let url = try objectURL(for: path)
        var request = try signedRequest(url: url, method: "GET")
        // 整文件下载放宽超时 (大文件), 复用长生命周期 rangeSession 避免
        // 每首歌新建 session 泄漏。per-request timeout 覆盖 session 默认值。
        request.timeoutInterval = 300

        let (tempURL, response) = try await rangeSession.download(for: request)
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
        let url = try objectURL(for: path)
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

    private func bucketURL() throws -> URL {
        let scheme = useSsl ? "https" : "http"
        guard var url = NetworkURLBuilder.baseURL(host: endpoint, scheme: scheme) else {
            throw SourceError.connectionFailed("Invalid S3 endpoint")
        }
        for component in bucket.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }

    private func objectURL(for path: String) throws -> URL {
        var url = try bucketURL()
        for component in path.split(separator: "/") where component.isEmpty == false {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
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

        // Canonical request — must follow SigV4 byte-for-byte, otherwise the
        // server recomputes a different signature → SignatureDoesNotMatch (403).
        let path = canonicalURI(for: url)
        let query = canonicalQueryString(for: url)
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

    /// SigV4 canonical URI: percent-encode each path segment with the AWS
    /// unreserved set (A-Za-z0-9-._~), keeping `/` as the separator. Uses the
    /// raw (already percent-encoded) path so non-ASCII / space keys match the
    /// bytes actually sent on the wire; `url.path` would decode them and break
    /// the signature.
    private func canonicalURI(for url: URL) -> String {
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard rawPath.isEmpty == false else { return "/" }
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            // Decode then re-encode each segment so the result is exactly one
            // layer of AWS-style encoding regardless of how the URL was built.
            let decoded = segment.removingPercentEncoding ?? String(segment)
            return Self.awsURIEncode(decoded)
        }
        let joined = segments.joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }

    /// SigV4 canonical query string: sort params by name (byte order),
    /// AWS-encode both name and value (so `/` → %2F), join `name=value` with `&`.
    private func canonicalQueryString(for url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let encoded = items.map { item -> (String, String) in
            (Self.awsURIEncode(item.name), Self.awsURIEncode(item.value ?? ""))
        }
        return encoded
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// AWS SigV4 percent-encoding: everything except the unreserved set
    /// (A-Za-z0-9, `-`, `.`, `_`, `~`) is %XX-encoded with uppercase hex.
    private static func awsURIEncode(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    // MARK: - XML Parsing

    private struct S3ListPage {
        let items: [RemoteFileItem]
        let isTruncated: Bool
        let nextContinuationToken: String?
    }

    private func parseListResponse(data: Data, prefix: String) -> S3ListPage {
        let parser = S3ListParser(prefix: prefix)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return S3ListPage(
            items: parser.items,
            isTruncated: parser.isTruncated,
            nextContinuationToken: parser.nextContinuationToken
        )
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
    var isTruncated = false
    var nextContinuationToken: String?

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
        // Top-level pagination markers (children of ListBucketResult, not inside
        // Contents/CommonPrefixes) — drive continuation-token paging.
        if !inContents && !inCommonPrefix {
            if currentElement == "IsTruncated" { isTruncated = (trimmed.lowercased() == "true") }
            if currentElement == "NextContinuationToken" { nextContinuationToken = (nextContinuationToken ?? "") + trimmed }
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
