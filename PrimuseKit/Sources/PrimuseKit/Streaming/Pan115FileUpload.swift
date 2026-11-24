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

    public enum CallbackError: Error, Equatable, Sendable {
        case tokenExpired
        case rateLimited
        case notFound
        case providerFailure(code: Int, message: String)
        case unexpectedResponse(statusCode: Int, ossCode: String?, bodyPreview: String)

        public var isRetryable: Bool {
            switch self {
            case .rateLimited, .unexpectedResponse:
                return true
            case .tokenExpired, .notFound:
                return false
            case .providerFailure(let code, let message):
                if code == 408 || code == 425 || code == 429 || (500...599).contains(code) { return true }
                let lowered = message.lowercased()
                return ["繁忙", "超时", "重试", "稍后", "busy", "timeout", "try again", "temporarily"]
                    .contains { lowered.contains($0) }
            }
        }
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
        for _ in 0..<2 where [6, 7, 8].contains(Pan115APIProtocol.intValue(reply["status"]) ?? -1) {
            let key = try string("sign_key", in: reply)
            let check = try string("sign_check", in: reply)
            fields.removeAll { $0.name == "sign_key" || $0.name == "sign_val" }
            fields.append(.init(name: "sign_key", value: key))
            fields.append(.init(name: "sign_val", value: try challengeHash(check, file: file, size: fingerprint.size)))
            reply = try object(await initialize(fields))
        }
        if Pan115APIProtocol.intValue(reply["status"]) == 2 { return }
        let callback = reply["callback"] as? [String: Any] ?? (reply["callback"] as? [[String: Any]])?.first
        guard Pan115APIProtocol.intValue(reply["status"]) == 1, let callback else { throw URLError(.cannotParseResponse) }
        var callbackHeaders = [
            "x-oss-callback": Data(try string("callback", in: callback).utf8).base64EncodedString()
        ]
        if let callbackVar = callback["callback_var"] as? String, !callbackVar.isEmpty {
            callbackHeaders["x-oss-callback-var"] = Data(callbackVar.utf8).base64EncodedString()
        }
        let bucket = try string("bucket", in: reply)
        let key = try string("object", in: reply)
        let signer = try OSS(bucket: bucket, key: key, credentials: object(await credentials()))
        let answer: (Data, HTTPURLResponse)
        if fingerprint.size <= 64 * 1024 * 1024 {
            let request = signer.request("PUT", headers: callbackHeaders)
            answer = try await send(request, .file(file), transfer)
        } else {
            answer = try await multipart(file: file, size: fingerprint.size, bucket: bucket, key: key,
                                         initialSigner: signer, callback: callbackHeaders,
                                         credentials: credentials, transfer: transfer)
        }
        try validateCallbackResponse(answer.0, statusCode: answer.1.statusCode)
    }

    static func validateCallbackResponse(_ data: Data, statusCode: Int) throws {
        // OSS returns HTTP 203 (CallbackFailed XML) when the object landed on OSS
        // but 115's callback URL failed or exceeded OSS's 5s callback timeout.
        guard statusCode != 203 else {
            throw CallbackError.unexpectedResponse(
                statusCode: statusCode,
                ossCode: xmlValue("Code", in: data),
                bodyPreview: bodyPreview(data)
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CallbackError.unexpectedResponse(
                statusCode: statusCode,
                ossCode: xmlValue("Code", in: data),
                bodyPreview: bodyPreview(data)
            )
        }
        switch Pan115APIProtocol.envelope(of: json) {
        case .success:
            return
        case .failure(let code, _) where code == 200 && json["state"] == nil && hasUploadPayload(json["data"]):
            return
        case .tokenExpired:
            throw CallbackError.tokenExpired
        case .rateLimited:
            throw CallbackError.rateLimited
        case .notFound:
            throw CallbackError.notFound
        case .failure(let code, let message):
            throw CallbackError.providerFailure(code: code, message: message)
        }
    }

    private static func hasUploadPayload(_ value: Any?) -> Bool {
        guard let payload = value as? [String: Any] else { return false }
        return payload["pick_code"] != nil || payload["file_id"] != nil || payload["sha1"] != nil
    }

    private static func bodyPreview(_ data: Data) -> String {
        let text = String(decoding: data.prefix(240), as: UTF8.self)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private static func xmlValue(_ element: String, in data: Data) -> String? {
        let parser = XMLParser(data: data)
        let reader = XMLElementParser(element: element)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let trimmed = reader.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isSecurityTokenExpired(_ error: Error) -> Bool {
        guard let failure = error as? HTTPResponseFailure, failure.statusCode == 403 else { return false }
        return xmlValue("Code", in: failure.body) == "SecurityTokenExpired"
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data)
        if let value = parsed as? [String: Any] { return value }
        if let first = (parsed as? [[String: Any]])?.first { return first }
        throw URLError(.cannotParseResponse)
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
            throw HTTPResponseFailure(
                statusCode: result.1.statusCode,
                body: result.0,
                retryAfter: HTTPResponseFailure.retryDelay(from: result.1)
            )
        }
        return result
    }

    private static func multipart(
        file: URL, size: Int64, bucket: String, key: String,
        initialSigner: OSS, callback: [String: String],
        credentials: @Sendable () async throws -> Data,
        transfer: Transfer
    ) async throws -> (Data, HTTPURLResponse) {
        var signer = initialSigner
        // 115's OSS bucket verifies the whole-object SHA-1 in CompleteMultipartUpload's callback,
        // which Aliyun OSS only computes for multipart uploads initialized in sequential mode.
        let (start, _) = try await send(
            signer.request("POST", query: [("sequential", ""), ("uploads", "")]),
            .empty,
            transfer
        )
        guard let uploadID = xmlValue("UploadId", in: start) else { throw URLError(.cannotParseResponse) }
        let upload = ("uploadId", uploadID)
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
                var partResponse: HTTPURLResponse?
                for attempt in 0..<2 {
                    do {
                        let request = signer.request("PUT", query: [("partNumber", number), upload])
                        partResponse = try await send(request, .bytes(chunk), transfer).1
                        break
                    } catch where attempt == 0 && isSecurityTokenExpired(error) {
                        signer = try OSS(bucket: bucket, key: key, credentials: object(await credentials()))
                    } catch let failure as HTTPResponseFailure where attempt == 0 && CloudHTTPRetryPolicy.shouldRetry(statusCode: failure.statusCode) {
                        continue
                    } catch let urlError as URLError where attempt == 0 && CloudHTTPRetryPolicy.shouldRetry(urlErrorCode: urlError.errorCode) {
                        continue
                    }
                }
                guard let response = partResponse else { throw URLError(.cannotParseResponse) }
                let tag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard let tag, !tag.isEmpty, tag.allSatisfy(\.isHexDigit) else { throw URLError(.cannotParseResponse) }
                parts.append("<Part><PartNumber>\(number)</PartNumber><ETag>\"\(tag)\"</ETag></Part>")
                remaining -= Int64(length)
            }
            let body = Data(("<CompleteMultipartUpload>" + parts.joined() + "</CompleteMultipartUpload>").utf8)
            do {
                return try await send(signer.request("POST", query: [upload], headers: callback, contentType: "application/xml"),
                                      .bytes(body), transfer)
            } catch where isSecurityTokenExpired(error) {
                signer = try OSS(bucket: bucket, key: key, credentials: object(await credentials()))
                return try await send(signer.request("POST", query: [upload], headers: callback, contentType: "application/xml"),
                                      .bytes(body), transfer)
            }
        } catch {
            _ = try? await send(signer.request("DELETE", query: [upload]), .empty, transfer)
            throw error
        }
    }

    private final class XMLElementParser: NSObject, XMLParserDelegate {
        let element: String
        var value = ""
        var reading = false
        init(element: String) { self.element = element }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            if elementName == element, value.isEmpty { reading = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if reading { value += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == element { reading = false }
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
            let host = (URL(string: endpoint.contains("://") ? endpoint : "https://" + endpoint)?.host ?? "").lowercased()
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
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            let timestamp = formatter.string(from: date)
            let day = String(timestamp.prefix(8))
            let encodedQuery: [(String, String)] = query
                .map { (Self.encode($0.0), Self.encode($0.1)) }
                .sorted { lhs, rhs in lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1 < rhs.1 }
            let queryParts: [String] = encodedQuery.map { key, value in
                value.isEmpty ? key : "\(key)=\(value)"
            }
            let queryString = queryParts.joined(separator: "&")
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
