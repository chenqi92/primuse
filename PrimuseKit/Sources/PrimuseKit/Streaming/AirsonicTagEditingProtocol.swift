import Foundation

public struct AirsonicTagValues: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var year: Int?
    public var track: Int?

    public init(title: String, artist: String, album: String, genre: String, year: Int?, track: Int?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.track = track
    }

    public func advancedPayload(mediaFileID: Int) throws -> String {
        let object: [String: Any] = [
            "mediaFileId": mediaFileID, "title": title, "artist": artist,
            "album": album, "genre": genre,
            "year": year.map { $0 as Any } ?? NSNull(),
            "track": track.map { $0 as Any } ?? NSNull(),
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// Wire formats used by Airsonic's own tag editor. Responses are parsed as
/// data; DWR JavaScript is never evaluated.
public enum AirsonicTagEditingProtocol {
    public static func dwrBody(
        batch: Int, page: String, httpSessionID: String, scriptSessionID: String?,
        mediaFileID: Int? = nil, values: AirsonicTagValues? = nil
    ) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let editing = mediaFileID != nil && values != nil
        var lines = ["callCount=1", "page=\(encoded(page))", "httpSessionId=\(httpSessionID)",
                     "scriptSessionId=\(scriptSessionID ?? "null")", "windowName=",
                     "c0-scriptName=\(editing ? "tagService" : "__System")",
                     "c0-methodName=\(editing ? "setTags" : "pageLoaded")", "c0-id=0"]
        if let mediaFileID, let values {
            lines.append("c0-param0=number:\(mediaFileID)")
            let arguments = [values.track.map(String.init) ?? "", values.artist, values.album, values.title,
                             values.year.map(String.init) ?? "", values.genre]
            lines += arguments.enumerated().map { "c0-param\($0.offset + 1)=string:\(encoded($0.element))" }
        }
        lines.append("batchId=\(batch)")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func dwrScriptSession(_ response: String) throws -> String {
        let value = try dwrString(response, pattern: #"dwr\.engine\.remote\.handleNewScriptSession\(\s*("(?:[^"\\]|\\.)*")\s*\)"#)
        guard !value.isEmpty, value.utf8.count <= 256,
              value.rangeOfCharacter(from: .newlines) == nil else { throw URLError(.cannotParseResponse) }
        return value
    }

    public static func dwrResult(_ response: String, batch: Int) throws -> String {
        try dwrString(response, pattern: #"dwr\.engine\.remote\.handleCallback\(\s*""# + String(batch)
            + #""\s*,\s*"0"\s*,\s*("(?:[^"\\]|\\.)*")\s*\)"#)
    }

    private static func dwrString(_ response: String, pattern: String) throws -> String {
        guard !response.contains("handleException("), !response.contains("handleBatchException("),
              let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let range = Range(match.range(at: 1), in: response),
              let value = try JSONSerialization.jsonObject(with: Data(response[range].utf8), options: .fragmentsAllowed) as? String else {
            throw URLError(.cannotParseResponse)
        }
        return value
    }

    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let text = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    public static func csrf(in html: String) -> (parameter: String, header: String, token: String)? {
        let inputs = tags("input", in: html)
        if let input = inputs.first(where: { $0["name"] == "_csrf" }), let token = input["value"],
           !token.isEmpty, token.rangeOfCharacter(from: .newlines) == nil {
            return ("_csrf", "X-CSRF-TOKEN", token)
        }
        let metas = tags("meta", in: html)
        let scriptToken = try? dwrString(html, pattern: #"\bvar\s+csrftoken\s*=\s*("(?:[^"\\]|\\.)*")\s*;"#)
        let scriptHeader = try? dwrString(html, pattern: #"\bvar\s+csrfheaderName\s*=\s*("(?:[^"\\]|\\.)*")\s*;"#)
        guard let token = metas.first(where: { $0["name"] == "_csrf" })?["content"] ?? scriptToken, !token.isEmpty else { return nil }
        let header = metas.first(where: { $0["name"] == "_csrf_header" })?["content"] ?? scriptHeader ?? "X-CSRF-TOKEN"
        guard !header.isEmpty, header.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              token.rangeOfCharacter(from: .newlines) == nil else { return nil }
        return ("_csrf", header, token)
    }

    private static func tags(_ name: String, in html: String) -> [[String: String]] {
        guard let tagPattern = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>", options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: #"([\w-]+)\s*=\s*(["'])(.*?)\2"#, options: .dotMatchesLineSeparators) else { return [] }
        return tagPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range, in: html) else { return nil }
            let tag = String(html[range])
            var result: [String: String] = [:]
            for attribute in attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let key = Range(attribute.range(at: 1), in: tag),
                      let value = Range(attribute.range(at: 3), in: tag) else { continue }
                result[String(tag[key]).lowercased()] = String(tag[value])
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&amp;", with: "&")
            }
            return result
        }
    }

    public static func stomp(_ command: String, headers: [String: String], body: String = "") -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: ":", with: "\\c")
        }
        let fields = headers.sorted { $0.key < $1.key }.map {
            "\(escape($0.key)):\(escape($0.value))"
        }
        return ([command] + fields).joined(separator: "\n") + "\n\n" + body + "\0"
    }

    public static func sockJSBody(_ frames: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: frames)
    }

    public static func sockJSMessages(_ response: String) throws -> [String] {
        var frames: [String] = []
        for line in response.split(separator: "\n") {
            if line == "o" || line == "h" { continue }
            guard line.first == "a",
                  let messages = try JSONSerialization.jsonObject(with: Data(line.dropFirst().utf8)) as? [String] else {
                throw URLError(.cannotParseResponse)
            }
            frames.append(contentsOf: messages)
        }
        return frames
    }

    public static func stompResponse(_ frame: String) throws -> (command: String, headers: [String: String], body: String) {
        let normalized = frame.replacingOccurrences(of: "\r\n", with: "\n").drop(while: { $0 == "\n" })
        guard let divider = normalized.range(of: "\n\n"), let end = normalized[divider.upperBound...].firstIndex(of: "\0") else {
            throw URLError(.cannotParseResponse)
        }
        let lines = normalized[..<divider.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
        guard let command = lines.first, !command.isEmpty else { throw URLError(.cannotParseResponse) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw URLError(.cannotParseResponse) }
            headers[String(line[..<colon])] = String(line[line.index(after: colon)...])
        }
        let body = String(normalized[divider.upperBound..<end])
        if let length = headers["content-length"], Int(length) != body.utf8.count { throw URLError(.cannotParseResponse) }
        return (String(command), headers, body)
    }
}
