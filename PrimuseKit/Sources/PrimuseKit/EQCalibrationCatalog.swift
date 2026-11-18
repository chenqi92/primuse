import Foundation
import GRDB

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
        private let filters: [[Double]]?

        fileprivate init(row: Row) {
            id = row["id"]
            name = row["name"]
            measurementSource = row["measurementSource"]
            measurement = row["measurement"]
            path = row["path"]
            revision = row["revision"]
            recommended = row["recommended"]
            preamp = row["preamp"]
            filters = nil
        }

        public var url: String {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return "https://github.com/jaakkopasanen/AutoEq/blob/\(snapshotRevision)/\(encoded)"
        }

        public var preset: EQPreset {
            guard let filters = filters ?? EQCalibrationCatalog.filters(for: id),
                  isValid(filters: filters) else {
                assertionFailure("Invalid AutoEq parameters")
                return .flat
            }
            let kinds: [PEQFilter.Kind] = [.peak, .lowShelf, .highShelf]
            let peq = ParametricEQ(preamp: preamp, filters: filters.map {
                PEQFilter(kind: kinds[Int($0[0])], frequency: $0[1], gain: $0[2], q: $0[3])
            }, source: measurement)
            return EQPreset(id: id, name: name, bands: [], isBuiltIn: true, parametric: peq)
        }

        private func isValid(filters: [[Double]]) -> Bool {
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

    private static let columns = "id, name, measurementSource, measurement, path, revision, recommended, preamp"

    private static func openDatabase() -> DatabaseQueue? {
        guard let url = Bundle.primuseKit.url(forResource: "AutoEqCatalog", withExtension: "sqlite") else { return nil }
        var configuration = Configuration()
        configuration.readonly = true
        return try? DatabaseQueue(path: url.path, configuration: configuration)
    }

    private static let lookup = openDatabase()
    private static let browser = openDatabase()
    private static let snapshot = try? lookup?.read { db in
        try Row.fetchOne(db, sql: "SELECT revision, recommendedCount FROM snapshot").map {
            (revision: $0["revision"] as String, count: $0["recommendedCount"] as Int)
        }
    }
    public static var snapshotRevision: String { snapshot?.revision ?? "" }
    public static var recommendedCount: Int { snapshot?.count ?? 0 }

    // Browsing uses a separate reader so loading the directory cannot queue a route lookup behind it.
    public static let entries: [Entry] = (try? browser?.read { db in
        let rows = try Row.fetchCursor(db, sql: "SELECT \(columns) FROM profiles ORDER BY rowid")
        var entries: [Entry] = []
        while let row = try rows.next() { entries.append(Entry(row: row)) }
        return entries
    }) ?? []
    public static var presets: [EQPreset] { entries.map(\.preset) }

    private static func filters(for id: String) -> [[Double]]? {
        guard let text = try? lookup?.read({ db in
            try String.fetchOne(db, sql: "SELECT filters FROM profiles WHERE id = ?", arguments: [id])
        }) else { return nil }
        return try? JSONDecoder().decode([[Double]].self, from: Data(text.utf8))
    }

    public static func entry(withID id: String) -> Entry? {
        guard id.hasPrefix("autoeq.") else { return nil }
        return try? lookup?.read { db in
            try Row.fetchOne(db, sql: "SELECT \(columns) FROM profiles WHERE id = ?", arguments: [id]).map(Entry.init(row:))
        }
    }

    public struct ModelResult: Identifiable, Sendable {
        public let primary: Entry
        public let alternatives: [Entry]
        public var id: String { primary.name }
    }

    private struct IndexedModel: Sendable {
        let name: String
        let normalizedName: String
        let shortName: String
        let sources: [Substring]
    }

    private static let modelIndex: [IndexedModel] = (try? browser?.read { db in
        let rows = try Row.fetchCursor(db, sql: "SELECT * FROM models ORDER BY rowid")
        var models: [IndexedModel] = []
        while let row = try rows.next() {
            let sources: String = row["sources"]
            models.append(IndexedModel(name: row["name"], normalizedName: row["normalized"],
                                       shortName: row["shortName"], sources: sources.split(separator: "|")))
        }
        return models
    }) ?? []

    private static let allNames: [String] = (try? browser?.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM models ORDER BY rowid")
    }) ?? []

    public struct SearchResults: Sendable {
        fileprivate let names: [String]
        fileprivate let tokens: [String]
        public var count: Int { names.count }

        public func models(in range: Range<Int>) -> [ModelResult] {
            let page = names[range.clamped(to: names.indices)]
            guard !page.isEmpty,
                  let data = try? JSONEncoder().encode(Array(page)),
                  let grouped = try? browser?.read({ db in
                      let sql = """
                          SELECT \(columns) FROM profiles
                          WHERE name IN (SELECT value FROM json_each(?))
                          ORDER BY recommended DESC, rowid
                          """
                      let rows = try Row.fetchCursor(db, sql: sql, arguments: [String(decoding: data, as: UTF8.self)])
                      var groups: [String: [Entry]] = [:]
                      while let row = try rows.next() {
                          let entry = Entry(row: row)
                          groups[entry.name, default: []].append(entry)
                      }
                      return groups
                  }) else { return [] }
            return page.compactMap { name in
                guard var entries = grouped[name] else { return nil }
                if !tokens.isEmpty {
                    let modelName = normalized(name)
                    let sourceTokens = tokens.filter { !modelName.contains($0) }
                    if !sourceTokens.isEmpty {
                        entries = entries.filter { entry in
                            let source = normalized(entry.measurement)
                            return sourceTokens.allSatisfy { source.contains($0) }
                        }
                    }
                }
                guard let first = entries.first else { return nil }
                return ModelResult(primary: first, alternatives: Array(entries.dropFirst()))
            }
        }
    }

    public static func matchingModels(_ query: String) -> SearchResults {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return SearchResults(names: allNames, tokens: []) }
        var exact: [String] = []
        var partial: [String] = []
        for model in modelIndex {
            let sourceTokens = tokens.filter { !model.normalizedName.contains($0) }
            guard sourceTokens.isEmpty || model.sources.contains(where: { source in
                sourceTokens.allSatisfy { source.contains($0) }
            }) else { continue }
            let modelQuery = tokens.filter { model.normalizedName.contains($0) }.joined()
            if model.normalizedName == modelQuery || model.shortName == modelQuery {
                exact.append(model.name)
            } else {
                partial.append(model.name)
            }
        }
        return SearchResults(names: exact + partial, tokens: tokens)
    }

    public static func searchModels(_ query: String) -> [ModelResult] {
        let results = matchingModels(query)
        return results.models(in: 0..<results.count)
    }

    public static func search(_ query: String) -> [Entry] {
        searchModels(query).flatMap { [$0.primary] + $0.alternatives }
    }

    public static func automaticPreset(for device: EQOutputDevice) -> EQPreset? {
        guard device.kind != .builtInSpeaker, device.kind != .other,
              let id = try? lookup?.read({ db in
                  try String.fetchOne(db, sql: "SELECT profileID FROM aliases WHERE name = ?", arguments: [normalized(device.name)])
              }) else { return nil }
        return entry(withID: id)?.preset
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
