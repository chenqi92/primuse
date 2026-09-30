import Foundation

/// Reassembles a Server-Sent Events body into events. Bytes are fed as they
/// arrive; an event is complete at the blank line that ends it.
public struct AIServerSentEventParser: Sendable {
    public struct Event: Equatable, Sendable {
        public var name: String?
        public var data: String

        public init(name: String? = nil, data: String) {
            self.name = name
            self.data = data
        }
    }

    private var line: [UInt8] = []
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func consume(_ byte: UInt8) -> Event? {
        guard byte == UInt8(ascii: "\n") else {
            line.append(byte)
            return nil
        }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        return consume(line: text)
    }

    public mutating func consume(_ bytes: some Sequence<UInt8>) -> [Event] {
        bytes.compactMap { consume($0) }
    }

    /// Delivers an event the body ended without a trailing blank line for.
    public mutating func finish() -> Event? {
        if !line.isEmpty {
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll()
            if let event = consume(line: text) { return event }
        }
        return dispatch()
    }

    private mutating func consume(line: String) -> Event? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> Event? {
        defer {
            eventName = nil
            dataLines.removeAll()
        }
        guard !dataLines.isEmpty else { return nil }
        return Event(name: eventName, data: dataLines.joined(separator: "\n"))
    }
}

/// What one streamed event contributes to the generated text, per API style.
public enum AIStreamingTextDelta: Equatable, Sendable {
    case text(String)
    case done
    case failed
    case ignored

    public static func from(
        _ event: AIServerSentEventParser.Event,
        style: AICompatibleAPIStyle
    ) -> AIStreamingTextDelta {
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data == "[DONE]" { return .done }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)),
              let root = object as? [String: Any] else { return .ignored }
        if root["error"] != nil { return .failed }
        let type = (root["type"] as? String) ?? event.name

        switch style {
        case .chatCompletions:
            guard let choice = (root["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { return .ignored }
            if let content = delta["content"] as? String {
                return content.isEmpty ? .ignored : .text(content)
            }
            if let parts = delta["content"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                return text.isEmpty ? .ignored : .text(text)
            }
            return .ignored
        case .responses:
            switch type {
            case "response.output_text.delta":
                guard let delta = root["delta"] as? String, !delta.isEmpty else { return .ignored }
                return .text(delta)
            case "response.completed":
                return .done
            case "response.failed", "response.incomplete", "error":
                return .failed
            default:
                return .ignored
            }
        case .anthropicMessages:
            switch type {
            case "content_block_delta":
                guard let delta = root["delta"] as? [String: Any],
                      (delta["type"] as? String) == nil || (delta["type"] as? String) == "text_delta",
                      let text = delta["text"] as? String,
                      !text.isEmpty else { return .ignored }
                return .text(text)
            case "message_stop":
                return .done
            case "error":
                return .failed
            default:
                return .ignored
            }
        case .geminiGenerateContent:
            guard let candidates = root["candidates"] as? [[String: Any]] else { return .ignored }
            let text = candidates.flatMap { candidate -> [String] in
                guard let content = candidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else { return [] }
                return parts.compactMap { part in
                    // Thought summaries are not part of the answer.
                    (part["thought"] as? Bool) == true ? nil : part["text"] as? String
                }
            }.joined()
            return text.isEmpty ? .ignored : .text(text)
        }
    }
}

/// Picks complete objects out of the array under one of `keys` while the
/// JSON document around them is still being generated, so each item can be
/// shown as soon as its closing brace arrives. The finished document is
/// still decoded separately; this only reports progress.
public struct AIStreamingJSONArrayExtractor: Sendable {
    private let keys: [[UInt8]]
    private var buffer: [UInt8] = []
    private var arrayStart: Int?
    private var cursor = 0
    private var elementStart: Int?
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var finished = false

    public init(keys: [String]) {
        self.keys = keys.map { Array("\"\($0)\"".utf8) }
    }

    /// Appends generated text and returns the objects completed by it.
    public mutating func append(_ text: String) -> [[String: Any]] {
        guard !finished else { return [] }
        buffer.append(contentsOf: text.utf8)
        if arrayStart == nil {
            guard let start = locateArray() else { return [] }
            arrayStart = start
            cursor = start
        }
        var objects: [[String: Any]] = []
        while cursor < buffer.count {
            let byte = buffer[cursor]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                cursor += 1
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
                if depth == 0 { elementStart = cursor }
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                if depth == 0 { elementStart = cursor }
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if depth == 0 {
                    // The array itself closed.
                    finished = true
                    return objects
                }
                depth -= 1
                if depth == 0, let start = elementStart {
                    elementStart = nil
                    let element = Data(buffer[start...cursor])
                    if let object = try? JSONSerialization.jsonObject(with: element) as? [String: Any] {
                        objects.append(object)
                    }
                }
            case UInt8(ascii: ","):
                if depth == 0 { elementStart = nil }
            default:
                break
            }
            cursor += 1
        }
        return objects
    }

    /// Index just past the `[` that opens the array under one of the keys.
    private func locateArray() -> Int? {
        for key in keys {
            var searchFrom = 0
            while let match = firstIndex(of: key, from: searchFrom) {
                var index = match + key.count
                while index < buffer.count, isWhitespace(buffer[index]) { index += 1 }
                guard index < buffer.count else { return nil }
                if buffer[index] == UInt8(ascii: ":") {
                    index += 1
                    while index < buffer.count, isWhitespace(buffer[index]) { index += 1 }
                    guard index < buffer.count else { return nil }
                    if buffer[index] == UInt8(ascii: "[") { return index + 1 }
                }
                searchFrom = match + 1
            }
        }
        return nil
    }

    private func firstIndex(of pattern: [UInt8], from start: Int) -> Int? {
        guard !pattern.isEmpty, buffer.count >= pattern.count, start <= buffer.count - pattern.count else {
            return nil
        }
        var index = start
        while index <= buffer.count - pattern.count {
            if buffer[index] == pattern[0], Array(buffer[index..<(index + pattern.count)]) == pattern {
                return index
            }
            index += 1
        }
        return nil
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
    }
}

extension AIRemoteEndpointPolicy {
    /// The endpoint that answers with Server-Sent Events. Only Gemini uses a
    /// separate method; the other styles stream from the same path when the
    /// request body asks for it.
    public static func streamingGenerationEndpoint(
        configuration: AIRemoteProviderConfiguration
    ) throws -> URL {
        let endpoint = try generationEndpoint(configuration: configuration)
        guard configuration.apiStyle == .geminiGenerateContent else { return endpoint }
        let model = normalizedGeminiModelID(configuration.generationModel)
        let streaming = endpoint
            .deletingLastPathComponent()
            .appendingPathComponent("\(model):streamGenerateContent")
        guard var components = URLComponents(url: streaming, resolvingAgainstBaseURL: false) else {
            throw AIRemoteEndpointValidationError.invalidURL
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "alt", value: "sse")]
        guard let url = components.url else { throw AIRemoteEndpointValidationError.invalidURL }
        return url
    }
}
