import Foundation

public enum ServerLyricsReadResult: Equatable, Sendable {
    case content(String)
    case document([LyricLine])
    case absent
    case unavailable

    public var lines: [LyricLine] {
        switch self {
        case .document(let lines): return lines
        case .content(let text): return LyricsContentParser.parseText(TextEncodingRepair.repairedLyricsDocument(text) ?? text)
        case .absent, .unavailable: return []
        }
    }

    /// A text snapshot for raw editors, exports and compare-before-write.
    public var sourceText: String? {
        switch self {
        case .content(let text): return text
        case .document(let lines): return LyricsContentParser.serializeTTML(lines)
        case .absent, .unavailable: return nil
        }
    }
}

/// Carries explicit provider translations through the text-based source API without
/// forcing the LRC parser to guess whether simultaneous lines are translations or voices.
public enum SourceLyricsDocument {
    private struct Payload: Codable {
        let primuseLyricsDocumentVersion: Int
        let lines: [LyricLine]
    }

    public static func encode(_ lines: [LyricLine]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(primuseLyricsDocumentVersion: 1, lines: lines))
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) -> [LyricLine]? {
        guard text.first == "{", text.contains("\"primuseLyricsDocumentVersion\""),
              let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.primuseLyricsDocumentVersion == 1 else { return nil }
        return payload.lines
    }
}
