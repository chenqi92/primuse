import Foundation

public struct ArtistNameConfiguration: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let storageKey = "primuse_artist_name_configuration_v1"

    public static let defaultValue = ArtistNameConfiguration(
        separators: [";", "；"],
        protectedNames: [],
        displaySeparator: " / "
    )

    public var schemaVersion: Int
    public var separators: [String]
    public var protectedNames: [String]
    public var displaySeparator: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        separators: [String],
        protectedNames: [String],
        displaySeparator: String
    ) {
        self.schemaVersion = schemaVersion
        self.separators = separators
        self.protectedNames = protectedNames
        self.displaySeparator = displaySeparator
    }

    public var isSupported: Bool {
        schemaVersion > 0 && schemaVersion <= Self.currentSchemaVersion
    }

    public static func load(from defaults: UserDefaults) -> ArtistNameConfiguration {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.isSupported else {
            return defaultValue
        }
        return decoded.normalized()
    }

    public func encodedData() throws -> Data {
        try JSONEncoder().encode(normalized())
    }

    public func normalized() -> ArtistNameConfiguration {
        ArtistNameConfiguration(
            schemaVersion: min(max(schemaVersion, 1), Self.currentSchemaVersion),
            separators: Self.normalizedList(
                separators,
                maximumCount: 32,
                maximumLength: 32,
                widthInsensitive: false
            ),
            protectedNames: Self.normalizedList(
                protectedNames,
                maximumCount: 256,
                maximumLength: 256,
                widthInsensitive: true
            ),
            displaySeparator: Self.normalizedDisplaySeparator(displaySeparator)
        )
    }

    /// Stable input for cache invalidation. This is intentionally readable and
    /// independent of JSON key ordering so old derived indexes are never reused
    /// after an artist parsing rule changes.
    public var cacheSignature: String {
        let value = normalized()
        return ([String(value.schemaVersion), value.displaySeparator]
            + value.separators
            + ["\u{1F}"]
            + value.protectedNames)
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    private static func normalizedList(
        _ values: [String],
        maximumCount: Int,
        maximumLength: Int,
        widthInsensitive: Bool
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(values.count, maximumCount))

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let bounded = String(trimmed.prefix(maximumLength))
            let key = comparisonKey(bounded, widthInsensitive: widthInsensitive)
            guard seen.insert(key).inserted else { continue }
            result.append(bounded)
            if result.count == maximumCount { break }
        }
        return result
    }

    private static func normalizedDisplaySeparator(_ value: String) -> String {
        guard !value.isEmpty,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultValue.displaySeparator
        }
        return String(value.prefix(16))
    }

    fileprivate static func comparisonKey(
        _ value: String,
        widthInsensitive: Bool = true
    ) -> String {
        var options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if widthInsensitive { options.insert(.widthInsensitive) }
        return value.precomposedStringWithCanonicalMapping.folding(
            options: options,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

public enum ArtistNameParser {
    /// Returns the distinct contributors represented by a track artist field.
    /// A native array with multiple entries is authoritative: symbols inside
    /// those names are never reinterpreted as text separators. A single native
    /// value may still contain a legacy joined tag, so it follows the same text
    /// parsing path as `rawName`.
    public static func names(
        rawName: String?,
        sourceNames: [String]? = nil,
        configuration: ArtistNameConfiguration = .defaultValue
    ) -> [String] {
        let nativeNames = distinctNormalizedNames(sourceNames ?? [])
        if nativeNames.count > 1 {
            return nativeNames
        }

        let candidate = normalizedName(rawName) ?? nativeNames.first
        guard let candidate else { return [] }

        let configuration = configuration.normalized()
        guard !configuration.separators.isEmpty else { return [candidate] }

        let separators = configuration.separators.sorted(by: longestFirst)
        let protectedNames = configuration.protectedNames.sorted(by: longestFirst)
        var result: [String] = []
        var current = ""
        var index = candidate.startIndex

        while index < candidate.endIndex {
            if let range = firstMatch(
                in: candidate,
                at: index,
                candidates: protectedNames,
                widthInsensitive: true
            ) {
                current += candidate[range]
                index = range.upperBound
                continue
            }

            if let range = firstMatch(
                in: candidate,
                at: index,
                candidates: separators,
                widthInsensitive: false
            ) {
                appendDistinct(current, to: &result)
                current.removeAll(keepingCapacity: true)
                index = range.upperBound
                continue
            }

            let next = candidate.index(after: index)
            current += candidate[index..<next]
            index = next
        }

        appendDistinct(current, to: &result)
        return result.isEmpty ? [candidate] : result
    }

    public static func displayName(
        rawName: String?,
        sourceNames: [String]? = nil,
        configuration: ArtistNameConfiguration = .defaultValue
    ) -> String? {
        let names = names(
            rawName: rawName,
            sourceNames: sourceNames,
            configuration: configuration
        )
        guard !names.isEmpty else { return normalizedName(rawName) }
        return names.joined(separator: configuration.normalized().displaySeparator)
    }

    public static func contains(
        artistName: String,
        rawName: String?,
        sourceNames: [String]? = nil,
        configuration: ArtistNameConfiguration = .defaultValue
    ) -> Bool {
        let target = ArtistNameConfiguration.comparisonKey(artistName)
        return names(
            rawName: rawName,
            sourceNames: sourceNames,
            configuration: configuration
        ).contains { ArtistNameConfiguration.comparisonKey($0) == target }
    }

    private static func distinctNormalizedNames(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            appendDistinct(value, to: &result)
        }
        return result
    }

    private static func appendDistinct(_ value: String, to result: inout [String]) {
        guard let normalized = normalizedName(value) else { return }
        let key = ArtistNameConfiguration.comparisonKey(normalized)
        guard !result.contains(where: {
            ArtistNameConfiguration.comparisonKey($0) == key
        }) else { return }
        result.append(normalized)
    }

    private static func normalizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.precomposedStringWithCanonicalMapping
    }

    private static func longestFirst(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs < rhs
    }

    private static func firstMatch(
        in value: String,
        at index: String.Index,
        candidates: [String],
        widthInsensitive: Bool
    ) -> Range<String.Index>? {
        let searchRange = index..<value.endIndex
        var options: String.CompareOptions = [.anchored, .caseInsensitive, .diacriticInsensitive]
        if widthInsensitive { options.insert(.widthInsensitive) }
        for candidate in candidates {
            guard let range = value.range(
                of: candidate,
                options: options,
                range: searchRange,
                locale: Locale(identifier: "en_US_POSIX")
            ), range.lowerBound == index else { continue }
            return range
        }
        return nil
    }
}

public extension Song {
    func effectiveArtistNames(
        configuration: ArtistNameConfiguration = .defaultValue
    ) -> [String] {
        ArtistNameParser.names(
            rawName: artistName,
            sourceNames: sourceArtistNames,
            configuration: configuration
        )
    }

    func displayArtistName(
        configuration: ArtistNameConfiguration = .defaultValue
    ) -> String? {
        ArtistNameParser.displayName(
            rawName: artistName,
            sourceNames: sourceArtistNames,
            configuration: configuration
        )
    }
}

public extension Notification.Name {
    static let primuseArtistNameConfigurationDidChange = Notification.Name(
        "primuse.artistNameConfigurationDidChange"
    )
}
