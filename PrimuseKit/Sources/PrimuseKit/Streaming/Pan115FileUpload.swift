import CryptoKit
import Foundation

/// Upload negotiation with 115, followed by a signed transfer to the bucket
/// and object assigned to this upload. Only the 115 API receives the OAuth token.
public enum Pan115FileUpload {
    public struct Fingerprint: Sendable {
        public let size: Int64
        public let sha1: String
        let prefixSHA1: String

        public init(file: URL) throws {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            let prefix = try input.read(upToCount: 128 * 1024) ?? Data()
            prefixSHA1 = hex(Insecure.SHA1.hash(data: prefix)).uppercased()
            var digest = Insecure.SHA1()
            digest.update(data: prefix)
            var count = Int64(prefix.count)
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                count += Int64(chunk.count)
                digest.update(data: chunk)
            }
            size = count
            sha1 = hex(digest.finalize()).uppercased()
        }
    }

    public enum Body: Sendable {
        case empty
        case file(URL)
        case bytes(Data)
    }

    public static let redirectDelegate: any URLSessionTaskDelegate = NoRedirectDelegate()

    public typealias Transfer = @Sendable (URLRequest, Body) async throws -> (Data, HTTPURLResponse)

    public static func upload(
        file: URL, fingerprint: Fingerprint, parent: String, name: String,
        initialize: @Sendable ([URLQueryItem]) async throws -> Data,
        credentials: @Sendable () async throws -> Data,
        transfer: Transfer
    ) async throws {
        var fields: [URLQueryItem] = [
            .init(name: "file_name", value: name), .init(name: "file_size", value: String(fingerprint.size)),
            .init(name: "target", value: "U_1_" + parent), .init(name: "fileid", value: fingerprint.sha1),
            .init(name: "preid", value: fingerprint.prefixSHA1)
        ]
        var reply = try object(await initialize(fields))
        if [6, 7, 8].contains(Pan115APIProtocol.intValue(reply["status"]) ?? -1) {
            let key = try string("sign_key", in: reply)
            let check = try string("sign_check", in: reply)
            fields.append(.init(name: "sign_key", value: key))
            fields.append(.init(name: "sign_val", value: try challengeHash(check, file: file, size: fingerprint.size)))
            reply = try object(await initialize(fields))
        }
        if Pan115APIProtocol.intValue(reply["status"]) == 2 { return }
        guard Pan115APIProtocol.intValue(reply["status"]) == 1,
              let callback = reply["callback"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let callbackHeaders = [
            "x-oss-callback": Data(try string("callback", in: callback).utf8).base64EncodedString(),
            "x-oss-callback-var": Data(try string("callback_var", in: callback).utf8).base64EncodedString()
        ]
        let signer = try OSS(bucket: string("bucket", in: reply), key: string("object", in: reply),
                             credentials: object(await credentials()))
        let answer: Data
        if fingerprint.size <= 64 * 1024 * 1024 {
            let request = signer.request("PUT", headers: callbackHeaders)
            answer = try await send(request, .file(file), transfer).0
        } else {
            answer = try await multipart(file: file, size: fingerprint.size, signer: signer,
                                         callback: callbackHeaders, transfer: transfer)
        }
        guard Pan115APIProtocol.envelope(of: answer) == .success else { throw URLError(.badServerResponse) }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return value
    }

    private static func string(_ key: String, in value: [String: Any]) throws -> String {
        guard let text = value[key] as? String, !text.isEmpty else { throw URLError(.cannotParseResponse) }
        return text
    }

    static func challengeHash(_ check: String, file: URL, size: Int64) throws -> String {
        let ends = check.split(separator: "-", omittingEmptySubsequences: false)
        guard ends.count == 2, let start = Int64(ends[0]), let end = Int64(ends[1]),
              start >= 0, start <= end, end < size else { throw URLError(.cannotParseResponse) }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(start))
        var remaining = end - start + 1
        var digest = Insecure.SHA1()
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !chunk.isEmpty else {
                throw URLError(.cannotOpenFile)
            }
            digest.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        return hex(digest.finalize()).uppercased()
    }

    private static func send(_ request: URLRequest, _ body: Body, _ transfer: Transfer) async throws -> (Data, HTTPURLResponse) {
        let result = try await transfer(request, body)
        guard (200..<300).contains(result.1.statusCode) else {
            throw HTTPResponseFailure(statusCode: result.1.statusCode)
        }
        return result
    }

    private static func multipart(file: URL, size: Int64, signer: OSS, callback: [String: String],
                                  transfer: Transfer) async throws -> Data {
        let (start, _) = try await send(signer.request("POST", query: [("uploads", "")]), .empty, transfer)
        let xml = UploadIDParser()
        let parser = XMLParser(data: start)
        parser.delegate = xml
        guard parser.parse(), !xml.value.isEmpty else { throw URLError(.cannotParseResponse) }
        let upload = ("uploadId", xml.value)
        do {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            let partSize = max(8 * 1024 * 1024, Int((size - 1) / 10_000 + 1))
            var parts: [String] = []
            var remaining = size
            while remaining > 0 {
                try Task.checkCancellation()
                let length = min(partSize, Int(remaining))
                guard let chunk = try input.read(upToCount: length), chunk.count == length else { throw URLError(.cannotOpenFile) }
                let number = String(parts.count + 1)
                let request = signer.request("PUT", query: [("partNumber", number), upload])
                let (_, response) = try await send(request, .bytes(chunk), transfer)
                let tag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard let tag, !tag.isEmpty, tag.allSatisfy(\.isHexDigit) else { throw URLError(.cannotParseResponse) }
                parts.append("<Part><PartNumber>\(number)</PartNumber><ETag>\"\(tag)\"</ETag></Part>")
                remaining -= Int64(length)
            }
            let body = Data(("<CompleteMultipartUpload>" + parts.joined() + "</CompleteMultipartUpload>").utf8)
            return try await send(signer.request("POST", query: [upload], headers: callback, contentType: "application/xml"),
                                  .bytes(body), transfer).0
        } catch {
            _ = try? await send(signer.request("DELETE", query: [upload]), .empty, transfer)
            throw error
        }
    }

    private final class UploadIDParser: NSObject, XMLParserDelegate {
        var value = ""
        var reading = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            reading = elementName == "UploadId"
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if reading { value += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            reading = false
        }
    }

    struct OSS {
        let url: URL
        let resource: String
        let region: String
        let id: String
        let secret: String
        let token: String

        init(bucket: String, key: String, credentials: [String: Any]) throws {
            let endpoint = try string("endpoint", in: credentials)
            let host = URL(string: endpoint.contains("://") ? endpoint : "https://" + endpoint)?.host ?? ""
            let labels = host.split(separator: ".")
            guard labels.count == 3, labels[0].hasPrefix("oss-"), labels[1] == "aliyuncs", labels[2] == "com",
                  !bucket.isEmpty, bucket.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !key.isEmpty, !key.hasPrefix("/"), !key.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            else { throw URLError(.badURL) }
            let path = key.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0)) }.joined(separator: "/")
            guard let url = URL(string: "https://" + bucket + "." + host + "/" + path) else { throw URLError(.badURL) }
            self.url = url
            resource = "/" + bucket + "/" + path
            region = String(labels[0].dropFirst(4)).replacingOccurrences(of: "-internal", with: "")
            id = try string("AccessKeyId", in: credentials)
            secret = try string("AccessKeySecret", in: credentials)
            token = try string("SecurityToken", in: credentials)
        }

        private static func encode(_ value: String) -> String {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            return value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }

        func request(_ method: String, query: [(String, String)] = [], headers: [String: String] = [:],
                     contentType: String = "application/octet-stream", date: Date = Date()) -> URLRequest {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            let timestamp = formatter.string(from: date)
            let day = String(timestamp.prefix(8))
            let queryString = query.map { key, value in
                value.isEmpty ? Self.encode(key) : Self.encode(key) + "=" + Self.encode(value)
            }.sorted().joined(separator: "&")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            if !queryString.isEmpty { components.percentEncodedQuery = queryString }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.timeoutInterval = 3600
            var signed = headers
            signed["content-type"] = contentType
            signed["x-oss-date"] = timestamp
            signed["x-oss-content-sha256"] = "UNSIGNED-PAYLOAD"
            signed["x-oss-security-token"] = token
            let canonicalHeaders = signed.keys.sorted().map { "\($0):\(signed[$0]!)\n" }.joined()
            let canonical = [method, resource, queryString, canonicalHeaders, "", "UNSIGNED-PAYLOAD"].joined(separator: "\n")
            let scope = [day, region, "oss", "aliyun_v4_request"]
            let text = ["OSS4-HMAC-SHA256", timestamp, scope.joined(separator: "/"), hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
            func hmac(_ key: Data, _ value: String) -> Data {
                Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
            }
            let signingKey = scope.reduce(Data(("aliyun_v4" + secret).utf8), hmac)
            for (header, value) in signed { request.setValue(value, forHTTPHeaderField: header) }
            request.setValue("OSS4-HMAC-SHA256 Credential=\(id)/\(scope.joined(separator: "/")),Signature=\(hex(hmac(signingKey, text)))",
                             forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
