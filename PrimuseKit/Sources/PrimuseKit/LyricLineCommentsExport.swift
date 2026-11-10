import Foundation

public enum LyricLineCommentsExport {
    public static func markdown(
        title: String,
        artist: String? = nil,
        comments: [LyricLineComment],
        voiceNames: [LyricVoice: String] = [:]
    ) -> String {
        var sections = ["# " + escaped(title)]
        if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(escaped(artist))
        }
        for comment in comments.sorted(by: {
            if $0.anchor.timestamp != $1.anchor.timestamp { return $0.anchor.timestamp < $1.anchor.timestamp }
            return $0.id < $1.id
        }) {
            var heading = "## " + timestamp(comment.anchor.timestamp)
            if let voice = voiceNames[comment.anchor.voice] { heading += " · " + escaped(voice) }
            let lyric = escaped(comment.anchor.text).replacingOccurrences(of: "\n", with: "\n> ")
            sections.append(heading + "\n\n> " + lyric + "\n\n" + escaped(comment.text))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    public static func fileName(title: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        let cleaned = title.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let stem = cleaned.isEmpty ? "Lyrics" : String(cleaned.prefix(80))
        return stem + ".md"
    }

    private static func timestamp(_ value: TimeInterval) -> String {
        let seconds = value.isFinite ? max(0, value) : 0
        let rounded = (seconds * 1_000).rounded() / 1_000
        let minutes = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), floor(rounded / 60))
        let remainder = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), rounded.truncatingRemainder(dividingBy: 60))
        return String(repeating: "0", count: max(0, 2 - minutes.count)) + minutes + ":"
            + String(repeating: "0", count: max(0, 6 - remainder.count)) + remainder
    }

    private static func escaped(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let special: Set<Character> = Set("\\`*_{}[]<>()#+-.!|")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
        }.joined(separator: "  \n")
    }
}
