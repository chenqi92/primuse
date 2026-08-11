import Foundation

public enum EmbyLyricsTrackEventParser {
    public enum ParseError: Error, Equatable {
        case tooManyEvents(Int)
    }

    /// Emby 4.8 exposes lyrics as the same TrackEvents document used by its
    /// web client's text-subtitle renderer. Convert that document to the
    /// editable LRC/plain-text representation consumed by Primuse.
    public static func editableText(
        from data: Data,
        maximumEventCount: Int = 100_000
    ) throws -> String? {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.trackEvents.count <= maximumEventCount else {
            throw ParseError.tooManyEvents(document.trackEvents.count)
        }

        let events = document.trackEvents.compactMap { event -> Event? in
            let text = normalized(event.text)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return Event(text: text, startPositionTicks: event.startPositionTicks)
        }
        guard !events.isEmpty else { return nil }

        let hasTimeline = events.contains { $0.startPositionTicks != nil }
        return events.map { event in
            guard hasTimeline, let ticks = event.startPositionTicks else { return event.text }
            return "[\(formatTimestamp(ticks: ticks))]\(event.text)"
        }.joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func formatTimestamp(ticks: Int64) -> String {
        let milliseconds = max(0, ticks / 10_000)
        return String(
            format: "%02lld:%02lld.%03lld",
            milliseconds / 60_000,
            (milliseconds % 60_000) / 1_000,
            milliseconds % 1_000
        )
    }
}

private extension EmbyLyricsTrackEventParser {
    struct Document: Decodable {
        let trackEvents: [Event]

        enum CodingKeys: String, CodingKey {
            case trackEvents = "TrackEvents"
        }
    }

    struct Event: Decodable {
        let text: String
        let startPositionTicks: Int64?

        enum CodingKeys: String, CodingKey {
            case text = "Text"
            case startPositionTicks = "StartPositionTicks"
        }
    }
}
