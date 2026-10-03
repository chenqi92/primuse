import Foundation

public enum SiriRadioStationPlaybackAvailability: Sendable, Equatable {
    case available
    case notFound
    case sourceDisabled
    case unavailable
}

/// Builds the Siri-visible radio catalog without exposing stream addresses or
/// source credentials. Disabled or missing sources are excluded before any
/// name matching, so voice playback cannot bypass the library's source gate.
public enum SiriRadioStationCatalog {
    public static func playbackAvailability(
        for station: RadioStation?,
        activeSourceIDs: Set<String>,
        enabledSourceIDs: Set<String>
    ) -> SiriRadioStationPlaybackAvailability {
        guard let station else { return .notFound }
        if let sourceID = nonempty(station.sourceID) {
            guard activeSourceIDs.contains(sourceID) else { return .unavailable }
            guard enabledSourceIDs.contains(sourceID) else { return .sourceDisabled }
        }
        return availableStations(
            from: [station],
            enabledSourceIDs: enabledSourceIDs
        ).isEmpty ? .unavailable : .available
    }

    public static func availableStations(
        from stations: [RadioStation],
        enabledSourceIDs: Set<String>
    ) -> [RadioStation] {
        RadioStationOrdering.sorted(stations.filter { station in
            guard !station.isDeleted,
                  isSafeIdentifier(station.id),
                  safeDisplayName(station.name) != nil,
                  RadioStationValidation.hasConsistentServerIdentity(station),
                  RadioStationValidation.hasValidPlaybackReference(station) else {
                return false
            }
            guard let sourceID = nonempty(station.sourceID) else { return true }
            return enabledSourceIDs.contains(sourceID)
        })
    }

    /// How many stations become App Shortcut parameter values, i.e. how many
    /// stations "用 Primuse 播放 <台名>" can reach in one sentence.
    ///
    /// Every value is multiplied by each spoken form of the app name (display
    /// name plus every INAlternativeAppNames entry, four in all — the system
    /// allows three alternatives) and counts against the system's limit of
    /// 1,000 trigger phrases per language, which all App Shortcuts share — with
    /// books, podcast shows, settings pages and sleep-timer lengths, about 150
    /// values in the busiest language, ×4.
    /// Any other station is still reachable through "用 Primuse 播放电台"
    /// followed by its name.
    public static let appShortcutStationLimit = 50

    /// The stations Siri should learn by name first: the ones the listener
    /// actually plays, most recent first, then the rest in the order the
    /// radio page shows them. A subscribed list of hundreds would otherwise
    /// fill the budget with stations nobody asks for.
    public static func appShortcutStations(
        from stations: [RadioStation],
        enabledSourceIDs: Set<String>,
        limit: Int = appShortcutStationLimit
    ) -> [RadioStation] {
        let available = availableStations(from: stations, enabledSourceIDs: enabledSourceIDs)
        let played = available.enumerated()
            .filter { $0.element.lastPlayedAt != nil }
            .sorted { lhs, rhs in
                let left = lhs.element.lastPlayedAt ?? .distantPast
                let right = rhs.element.lastPlayedAt ?? .distantPast
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
        let unplayed = available.filter { $0.lastPlayedAt == nil }
        return Array((played + unplayed).prefix(max(0, limit)))
    }

    /// What "播放电台" plays when it names no station: the one last listened
    /// to, else the first the radio page shows. Siri expects a default for a
    /// request that names nothing ("resume, or something sensible"), not a
    /// follow-up question — answering one with `needsValue` left Siri saying
    /// the app was not responding.
    public static func defaultStation(
        from stations: [RadioStation],
        enabledSourceIDs: Set<String>
    ) -> RadioStation? {
        appShortcutStations(from: stations, enabledSourceIDs: enabledSourceIDs, limit: 1).first
    }

    /// The station a name resolves to, without asking. On the iPhone that
    /// reported it (iOS 27.0.1), Siri neither hands a disambiguation choice
    /// nor a confirmation back to resolution — it re-sends the original
    /// request and then gives up with "something went wrong". So among
    /// equally good matches (the same station from two subscriptions, or two
    /// "交通广播") the one last listened to wins, then the resolver's order;
    /// a lone weak match plays as well.
    public static func preferredStation(
        for resolution: SiriNamedMediaResolution,
        in stations: [RadioStation]
    ) -> RadioStation? {
        let byID = Dictionary(stations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pool = resolution.needsDisambiguation ? resolution.candidates : [resolution.selected]
        return pool.compactMap { byID[$0.id] }.enumerated().max { lhs, rhs in
            let left = lhs.element.lastPlayedAt ?? .distantPast
            let right = rhs.element.lastPlayedAt ?? .distantPast
            return left != right ? left < right : lhs.offset > rhs.offset
        }?.element
    }

    public static func namedItems(
        from stations: [RadioStation],
        enabledSourceIDs: Set<String>
    ) -> [SiriNamedMediaItem] {
        availableStations(
            from: stations,
            enabledSourceIDs: enabledSourceIDs
        ).map { station in
            SiriNamedMediaItem(
                id: station.id,
                name: safeDisplayName(station.name) ?? station.name,
                aliases: aliases(for: station)
            )
        }
    }

    public static func aliases(for station: RadioStation) -> [String] {
        guard let name = safeDisplayName(station.name) else { return [] }
        var candidates: [String] = []

        if let shortened = removingBracketedSuffix(from: name), shortened != name {
            candidates.append(shortened)
        }
        if let shortened = removingRadioAffix(from: name), shortened != name {
            candidates.append(shortened)
        }
        if let sourceName = safeSourceName(station.sourceName) {
            candidates.append("\(sourceName) \(name)")
            candidates.append("\(name) \(sourceName)")
        }

        var seen = Set<String>()
        let canonicalName = normalized(name)
        return candidates.compactMap { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCandidate = normalized(trimmed)
            guard !normalizedCandidate.isEmpty,
                  normalizedCandidate != canonicalName,
                  seen.insert(normalizedCandidate).inserted else {
                return nil
            }
            return trimmed
        }
    }

    /// Returns a label that can safely leave the app through Siri, Spotlight,
    /// or an App Entity. Stream URLs and credential-shaped query parameters
    /// are deliberately rejected even if a malformed imported station placed
    /// them in its display-name field.
    public static func safeDisplayName(_ value: String?) -> String? {
        guard let value = nonempty(value), value.count <= 120 else { return nil }
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        guard !containsSensitivePayload(folded) else { return nil }
        return value
    }

    public static func isSafeIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return false }
        let folded = trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return !containsSensitivePayload(folded)
    }

    private static func removingBracketedSuffix(from value: String) -> String? {
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("（", "）"), ("【", "】")]
        for (opening, closing) in pairs {
            guard value.last == closing,
                  let index = value.lastIndex(of: opening),
                  index > value.startIndex else {
                continue
            }
            let prefix = value[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.count >= 2 { return prefix }
        }
        return nil
    }

    private static func removingRadioAffix(from value: String) -> String? {
        let affixes = [
            "radio station", "radio", "station", "fm", "am",
            "网络电台", "網路電台", "电台", "電台", "广播", "廣播",
            "ラジオ", "라디오",
        ]
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        for affix in affixes.sorted(by: { $0.count > $1.count }) {
            let foldedAffix = affix.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if folded.hasSuffix(foldedAffix) {
                let end = value.index(value.endIndex, offsetBy: -affix.count)
                let prefix = value[..<end]
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if prefix.count >= 2 { return prefix }
            }
            if folded.hasPrefix(foldedAffix) {
                let start = value.index(value.startIndex, offsetBy: affix.count)
                let suffix = value[start...]
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if suffix.count >= 2 { return suffix }
            }
        }
        return nil
    }

    private static func safeSourceName(_ value: String?) -> String? {
        guard let value = safeDisplayName(value), value.count <= 80 else { return nil }
        let forbidden = ["?", "=", "@", "/", "\\"]
        guard !forbidden.contains(where: value.contains) else { return nil }
        return value
    }

    private static func containsSensitivePayload(_ folded: String) -> Bool {
        folded.contains("://")
            || folded.hasPrefix("file:")
            || folded.range(
                of: #"(?:^|[?&\s])(access[_-]?token|token|api[_-]?key|signature|sig|auth|authorization|password|secret)\s*[:=]"#,
                options: .regularExpression
            ) != nil
            || folded.range(
                of: #"(?:^|\s)bearer\s+[a-z0-9._~+/-]{8,}"#,
                options: .regularExpression
            ) != nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
