import Foundation

/// Resolves vocal parts from structured lyric agent metadata, separating lead,
/// duet partner, and chorus/group lines (`type="group"` / `v1000`).
public enum LyricVoiceResolutionPolicy {
    /// Maps a TTML `ttm:agent` attribute to a `LyricVoice` using declared
    /// `<ttm:agent xml:id="..." type="..."/>` metadata when available.
    ///
    /// - Group agents (`type="group"`), Apple Music's conventional `v1000`
    ///   (unless explicitly declared `type="person"`), and multi-agent
    ///   references (`ttm:agent="v1 v2"`) map to `.group`.
    /// - `v1` maps to `.primary`, `v2` maps to `.secondary`, and other person
    ///   IDs assign the first seen non-group ID to `primaryAgent`.
    public static func resolveTTMLVoice(
        agent: String,
        agentTypesByID: [String: String],
        primaryAgent: inout String?
    ) -> LyricVoice {
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .primary }

        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count > 1 {
            return .group
        }

        let single = tokens[0]
        let lowered = single.lowercased()
        if let declaredType = agentTypesByID[lowered] {
            if declaredType == "group" { return .group }
            if lowered == "v1000", declaredType != "person" { return .group }
        } else if lowered == "v1000" {
            return .group
        }

        switch lowered {
        case "v1":
            return .primary
        case "v2":
            return .secondary
        default:
            if primaryAgent == nil { primaryAgent = single }
            return single == primaryAgent ? .primary : .secondary
        }
    }

    /// Maps an OpenSubsonic cue-line agent (`role` and `id`) to a `LyricVoice`.
    public static func resolveOpenSubsonicVoice(agentID: String?, role: String?) -> LyricVoice {
        let normalizedRole = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedID = agentID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedRole == "group" || normalizedRole == "chorus" || normalizedID == "v1000" {
            return .group
        }
        if normalizedRole == "voice" || normalizedRole == "bg" {
            return .secondary
        }
        return .primary
    }
}
