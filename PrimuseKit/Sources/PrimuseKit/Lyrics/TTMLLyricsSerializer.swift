import Foundation

/// Serializes Primuse `LyricLine` documents to Apple Music-compatible TTML,
/// preserving group/chorus agents (`v1000`), primary replacement tracks in
/// `<head><metadata><iTunesMetadata>`, subtitle translations, multiple
/// transliteration tracks, backing vocals, and word-level timing cues.
enum TTMLLyricsSerializer {
    private struct ReplacementTrackKey: Hashable {
        let languageCode: String?
    }

    private struct ReplacementRow {
        let key: String
        let text: String
        let syllables: [LyricSyllable]?
        let languageCode: String?
        let backing: [ReplacementBackingRow]
    }

    private struct ReplacementBackingRow {
        let begin: TimeInterval?
        let end: TimeInterval?
        let text: String
        let syllables: [LyricSyllable]?
        let languageCode: String?
    }

    static func serialize(_ lines: [LyricLine]) -> String {
        let usesSecondaryVoice = lines.contains { $0.voice == .secondary }
        let usesGroupVoice = lines.contains { $0.voice == .group }
        let declaredLanguageCode = lines.lazy
            .compactMap(\.metadataLines)
            .compactMap(LyricManualTranslationPolicy.declaredLanguageCode(in:))
            .first
        let hasReplacements = lines.contains(where: lineHasReplacement)

        let languageAttribute = declaredLanguageCode.map { " xml:lang=\"\($0)\"" } ?? ""
        let itunesNamespace = hasReplacements
            ? " xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\""
            : ""

        var agentLines = ["      <ttm:agent xml:id=\"v1\" type=\"person\"/>"]
        if usesSecondaryVoice {
            agentLines.append("      <ttm:agent xml:id=\"v2\" type=\"person\"/>")
        }
        if usesGroupVoice {
            agentLines.append("      <ttm:agent xml:id=\"v1000\" type=\"group\"/>")
        }

        var replacementOrder: [ReplacementTrackKey] = []
        var replacementRowsByTrack: [ReplacementTrackKey: [ReplacementRow]] = [:]
        var nextLineKey = 1

        let paragraphs = lines.compactMap { line -> String? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            var attributes: [String] = []
            if line.isSynchronized {
                attributes.append("begin=\"\(formatTimestamp(line.timestamp))\"")
            }
            if let end = line.endTimestamp, end >= line.timestamp {
                attributes.append("end=\"\(formatTimestamp(end))\"")
            }
            attributes.append("ttm:agent=\"\(agentID(for: line.voice))\"")

            var lineKey: String?
            if hasReplacements, lineHasReplacement(line) {
                let assigned = "L\(nextLineKey)"
                nextLineKey += 1
                lineKey = assigned
                attributes.append("itunes:key=\"\(assigned)\"")
            }

            if let lineLanguageCode = line.languageCode,
               lineLanguageCode != declaredLanguageCode {
                attributes.append("xml:lang=\"\(lineLanguageCode)\"")
            }
            let attributeText = attributes.isEmpty ? "" : " " + attributes.joined(separator: " ")

            if let lineKey {
                collectReplacements(
                    from: line,
                    lineKey: lineKey,
                    order: &replacementOrder,
                    rowsByTrack: &replacementRowsByTrack
                )
            }

            let effectiveLineLanguage = line.languageCode ?? declaredLanguageCode
            if line.isBackingVocal {
                let backing = backgroundSpan(line, parentLanguageCode: effectiveLineLanguage, indent: "        ")
                return "      <p\(attributeText)>\n\(backing)\n      </p>"
            }

            var children = syllableSpans(
                line.syllables,
                lineLanguageCode: effectiveLineLanguage,
                indent: "        "
            )
            children += (line.background ?? []).map { background in
                backgroundSpan(
                    background,
                    parentLanguageCode: effectiveLineLanguage,
                    indent: "        "
                )
            }
            children += subtitleTranslationSpans(
                in: line,
                lineLanguageCode: effectiveLineLanguage,
                indent: "        "
            )
            children += romanizationSpans(in: line, indent: "        ")

            guard !children.isEmpty else {
                return "      <p\(attributeText)>\(escapeTTMLText(text))</p>"
            }
            let inlineText = line.syllables?.isEmpty == false ? "" : escapeTTMLText(text)
            return """
                  <p\(attributeText)>\(inlineText)
            \(children.joined(separator: "\n"))
                  </p>
            """
        }.joined(separator: "\n")

        var metadataChildren = agentLines
        if !replacementOrder.isEmpty {
            metadataChildren.append(
                iTunesReplacementMetadata(order: replacementOrder, rowsByTrack: replacementRowsByTrack)
            )
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"\(itunesNamespace)\(languageAttribute)>
          <head>
            <metadata>
        \(metadataChildren.joined(separator: "\n"))
            </metadata>
          </head>
          <body>
            <div>
        \(paragraphs)
            </div>
          </body>
        </tt>
        """
    }

    private static func agentID(for voice: LyricVoice) -> String {
        switch voice {
        case .primary: "v1"
        case .secondary: "v2"
        case .group: "v1000"
        }
    }

    private static func lineHasReplacement(_ line: LyricLine) -> Bool {
        if line.replacementTracks.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }
        return line.background?.contains(where: lineHasReplacement) ?? false
    }

    private static func collectReplacements(
        from line: LyricLine,
        lineKey: String,
        order: inout [ReplacementTrackKey],
        rowsByTrack: inout [ReplacementTrackKey: [ReplacementRow]]
    ) {
        var tracksOnLine: [ReplacementTrackKey] = []
        var primaryByTrack: [ReplacementTrackKey: LyricManualTranslation] = [:]
        for track in line.replacementTracks {
            let trimmed = track.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = ReplacementTrackKey(languageCode: track.languageCode)
            if primaryByTrack[key] == nil {
                primaryByTrack[key] = track
                tracksOnLine.append(key)
            }
        }
        var backingByTrack: [ReplacementTrackKey: [ReplacementBackingRow]] = [:]
        for background in line.background ?? [] {
            for track in background.replacementTracks {
                let trimmed = track.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = ReplacementTrackKey(languageCode: track.languageCode)
                if !tracksOnLine.contains(key) { tracksOnLine.append(key) }
                backingByTrack[key, default: []].append(ReplacementBackingRow(
                    begin: background.isSynchronized ? background.timestamp : nil,
                    end: background.endTime,
                    text: trimmed,
                    syllables: track.syllables,
                    languageCode: track.languageCode
                ))
            }
        }
        for key in tracksOnLine {
            if rowsByTrack[key] == nil { order.append(key) }
            let primary = primaryByTrack[key]
            rowsByTrack[key, default: []].append(ReplacementRow(
                key: lineKey,
                text: primary?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                syllables: primary?.syllables,
                languageCode: key.languageCode,
                backing: backingByTrack[key] ?? []
            ))
        }
    }

    private static func iTunesReplacementMetadata(
        order: [ReplacementTrackKey],
        rowsByTrack: [ReplacementTrackKey: [ReplacementRow]]
    ) -> String {
        let blocks = order.compactMap { trackKey -> String? in
            guard let rows = rowsByTrack[trackKey], !rows.isEmpty else { return nil }
            let langAttribute = trackKey.languageCode.map { " xml:lang=\"\($0)\"" } ?? ""
            let entries = rows.map { row -> String in
                var parts: [String] = []
                if !row.text.isEmpty {
                    parts.append(annotationContent(row.text, syllables: row.syllables, languageCode: row.languageCode))
                }
                for bg in row.backing {
                    var attrs = "ttm:role=\"x-bg\""
                    if let begin = bg.begin { attrs += " begin=\"\(formatTimestamp(begin))\"" }
                    if let end = bg.end, bg.begin.map({ end >= $0 }) ?? true {
                        attrs += " end=\"\(formatTimestamp(end))\""
                    }
                    let bgContent = annotationContent(bg.text, syllables: bg.syllables, languageCode: bg.languageCode)
                    parts.append("<span \(attrs)>\(bgContent)</span>")
                }
                let endAttr = row.syllables?.last.flatMap { last in
                    last.endTiming == .inferred ? " end=\"\(formatTimestamp(last.end))\"" : nil
                } ?? ""
                return "            <text for=\"\(row.key)\"\(endAttr)>\(parts.joined())</text>"
            }
            return """
                      <translation type="replacement"\(langAttribute)>
            \(entries.joined(separator: "\n"))
                      </translation>
            """
        }
        return """
              <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
                <translations>
        \(blocks.joined(separator: "\n"))
                </translations>
              </iTunesMetadata>
        """
    }

    private static func syllableSpans(
        _ syllables: [LyricSyllable]?,
        lineLanguageCode: String?,
        indent: String
    ) -> [String] {
        guard let syllables else { return [] }
        return syllables.map { syllable in
            var attributes = "begin=\"\(formatTimestamp(syllable.start))\""
            if syllable.endTiming == .explicit, syllable.end >= syllable.start {
                attributes += " end=\"\(formatTimestamp(syllable.end))\""
            }
            if let syllableLanguageCode = syllable.languageCode,
               syllableLanguageCode != lineLanguageCode {
                attributes += " xml:lang=\"\(syllableLanguageCode)\""
            }
            return "\(indent)<span \(attributes)>\(escapeTTMLText(syllable.text))</span>"
        }
    }

    private static func annotationContent(
        _ text: String,
        syllables: [LyricSyllable]?,
        languageCode: String?
    ) -> String {
        guard let syllables, !syllables.isEmpty,
              syllables.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == text
        else { return escapeTTMLText(text) }
        return syllableSpans(syllables, lineLanguageCode: languageCode, indent: "").joined()
    }

    private static func subtitleTranslationSpans(
        in line: LyricLine,
        lineLanguageCode: String?,
        indent: String
    ) -> [String] {
        line.subtitleTranslations.compactMap { translation in
            let text = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var attributes = "ttm:role=\"x-translation\""
            if let languageCode = translation.languageCode,
               languageCode != lineLanguageCode {
                attributes += " xml:lang=\"\(languageCode)\""
            } else if translation.languageCode == nil, lineLanguageCode != nil {
                attributes += " xml:lang=\"\""
            }
            if let last = translation.syllables?.last, last.endTiming == .inferred {
                attributes += " end=\"\(formatTimestamp(last.end))\""
            }
            let content = annotationContent(text, syllables: translation.syllables, languageCode: translation.languageCode)
            return "\(indent)<span \(attributes)>\(content)</span>"
        }
    }

    private static func romanizationSpans(in line: LyricLine, indent: String) -> [String] {
        line.allTransliterations.compactMap { reading in
            let text = reading.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var attributes = "ttm:role=\"x-roman\""
            if let languageCode = reading.languageCode, !languageCode.isEmpty {
                attributes += " xml:lang=\"\(languageCode)\""
            }
            if let last = reading.syllables?.last, last.endTiming == .inferred {
                attributes += " end=\"\(formatTimestamp(last.end))\""
            }
            let content = annotationContent(text, syllables: reading.syllables, languageCode: reading.languageCode)
            return "\(indent)<span \(attributes)>\(content)</span>"
        }
    }

    private static func backgroundSpan(
        _ line: LyricLine,
        parentLanguageCode: String?,
        indent: String
    ) -> String {
        var attributes = "ttm:role=\"x-bg\""
        if line.isSynchronized {
            attributes += " begin=\"\(formatTimestamp(line.timestamp))\""
        }
        if let end = line.endTime, end >= line.timestamp {
            attributes += " end=\"\(formatTimestamp(end))\""
        }
        let languageCode = line.languageCode
        if let languageCode, languageCode != parentLanguageCode {
            attributes += " xml:lang=\"\(languageCode)\""
        }

        let childIndent = indent + "  "
        var children = syllableSpans(
            line.syllables,
            lineLanguageCode: languageCode ?? parentLanguageCode,
            indent: childIndent
        )
        children += subtitleTranslationSpans(
            in: line,
            lineLanguageCode: languageCode ?? parentLanguageCode,
            indent: childIndent
        )
        children += romanizationSpans(in: line, indent: childIndent)

        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !children.isEmpty else {
            return "\(indent)<span \(attributes)>\(escapeTTMLText(text))</span>"
        }
        let inlineText = line.syllables?.isEmpty == false ? "" : escapeTTMLText(text)
        return """
        \(indent)<span \(attributes)>\(inlineText)
        \(children.joined(separator: "\n"))
        \(indent)</span>
        """
    }

    private static func formatTimestamp(_ time: TimeInterval) -> String {
        let milliseconds = max(0, (time * 1_000).rounded()).finiteInt()
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let fraction = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, fraction)
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeTTMLText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { escapeXML(String($0)) }
            .joined(separator: "<br/>")
    }
}
