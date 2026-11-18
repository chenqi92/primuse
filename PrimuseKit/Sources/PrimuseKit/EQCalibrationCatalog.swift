import Foundation

public enum EQCalibrationCatalog {
    public struct Entry: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let measurementSource: String
        public let measurement: String
        public let path: String
        public let revision: String
        public let recommended: Bool
        private let preamp: Double
        private let filters: [[Double]]

        public var url: String {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return "https://github.com/jaakkopasanen/AutoEq/blob/\(snapshotRevision)/\(encoded)"
        }

        public var preset: EQPreset {
            let kinds: [PEQFilter.Kind] = [.peak, .lowShelf, .highShelf]
            let peq = ParametricEQ(preamp: preamp, filters: filters.map {
                PEQFilter(kind: kinds[Int($0[0])], frequency: $0[1], gain: $0[2], q: $0[3])
            }, source: measurement)
            return EQPreset(id: id, name: name, bands: [], isBuiltIn: true, parametric: peq)
        }

        fileprivate var isValid: Bool {
            !id.isEmpty && !name.isEmpty && revision.count == 40
                && preamp.isFinite && (-60...30).contains(preamp)
                && !filters.isEmpty && filters.count <= ParametricEQ.maximumFilters
                && filters.allSatisfy {
                    $0.count == 4 && [0.0, 1.0, 2.0].contains($0[0])
                        && $0[1].isFinite && (10...96_000).contains($0[1])
                        && $0[2].isFinite && (-30...30).contains($0[2])
                        && $0[3].isFinite && (0.05...40).contains($0[3])
                }
        }
    }

    private struct Catalog: Decodable, Sendable {
        let schema: Int
        let revision: String
        let recommendedCount: Int
        let entries: [Entry]
    }

    private static let catalog: Catalog = {
        guard let url = Bundle.primuseKit.url(forResource: "AutoEqCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let result = try? JSONDecoder().decode(Catalog.self, from: data),
              result.schema == 1, result.revision.count == 40,
              result.entries.allSatisfy(\.isValid),
              Set(result.entries.map(\.id)).count == result.entries.count,
              result.entries.filter(\.recommended).count == result.recommendedCount else {
            assertionFailure("Invalid or missing bundled AutoEq catalog")
            return Catalog(schema: 1, revision: "", recommendedCount: 0, entries: [])
        }
        return result
    }()

    public static var snapshotRevision: String { catalog.revision }
    public static var recommendedCount: Int { catalog.recommendedCount }
    public static var entries: [Entry] { catalog.entries }
    public static var presets: [EQPreset] { entries.map(\.preset) }

    private static let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    public static func entry(withID id: String) -> Entry? {
        guard id.hasPrefix("autoeq.") else { return nil }
        return entriesByID[id]
    }

    public struct ModelResult: Identifiable, Sendable {
        public let primary: Entry
        public let alternatives: [Entry]
        public var id: String { primary.name }
    }

    private struct IndexedModel: Sendable {
        let result: ModelResult
        let name: String
        let shortName: String
        let sources: [String]
    }

    private static let modelIndex: [IndexedModel] = {
        let groups = Dictionary(grouping: entries, by: \.name)
        return entries.filter(\.recommended).map { primary in
            let alternatives = (groups[primary.name] ?? []).filter { $0.id != primary.id }
            return IndexedModel(
                result: ModelResult(primary: primary, alternatives: alternatives),
                name: normalized(primary.name),
                shortName: normalized(primary.name.split(separator: " ").dropFirst().joined(separator: " ")),
                sources: ([primary] + alternatives).map { normalized($0.measurement) }
            )
        }
    }()

    private static let allModels = modelIndex.map(\.result)

    public static func searchModels(_ query: String) -> [ModelResult] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return allModels }
        var exact: [ModelResult] = []
        var partial: [ModelResult] = []
        for model in modelIndex {
            let sourceTokens = tokens.filter { !model.name.contains($0) }
            let result: ModelResult
            if sourceTokens.isEmpty {
                result = model.result
            } else {
                let matches = model.sources.indices.filter { index in
                    sourceTokens.allSatisfy { model.sources[index].contains($0) }
                }
                guard let first = matches.first else { continue }
                func entry(_ index: Int) -> Entry {
                    index == 0 ? model.result.primary : model.result.alternatives[index - 1]
                }
                result = ModelResult(primary: entry(first), alternatives: matches.dropFirst().map(entry))
            }
            let modelQuery = tokens.filter { model.name.contains($0) }.joined()
            if model.name == modelQuery || model.shortName == modelQuery {
                exact.append(result)
            } else {
                partial.append(result)
            }
        }
        return exact + partial
    }

    public static func search(_ query: String) -> [Entry] {
        searchModels(query).flatMap { [$0.primary] + $0.alternatives }
    }

    private static let automaticIndex: [String: [String]] = {
        var result: [String: [String]] = [:]
        let variantBases = Set(entries.compactMap { entry -> String? in
            guard let suffix = entry.name.range(of: " (") else { return nil }
            return normalized(String(entry.name[..<suffix.lowerBound]))
        })
        for entry in entries where entry.recommended {
            let full = normalized(entry.name)
            // A route name cannot identify a nozzle, ear-pad or listening-mode variant.
            guard !variantBases.contains(full) else { continue }
            let withoutBrand = normalized(entry.name.split(separator: " ").dropFirst().joined(separator: " "))
            for alias in Set([full, withoutBrand]) where !alias.isEmpty {
                result[alias, default: []].append(entry.id)
            }
        }
        return result
    }()

    public static func automaticPreset(for device: EQOutputDevice) -> EQPreset? {
        guard device.kind != .builtInSpeaker, device.kind != .other,
              let ids = automaticIndex[normalized(device.name)], ids.count == 1 else { return nil }
        return entry(withID: ids[0])?.preset
    }

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

extension EQPreset {
    public static var allBuiltInPresets: [EQPreset] { builtInPresets + EQCalibrationCatalog.presets }

    public static func builtInPreset(withID id: String) -> EQPreset? {
        builtInPresets.first { $0.id == id } ?? EQCalibrationCatalog.entry(withID: id)?.preset
    }
}
