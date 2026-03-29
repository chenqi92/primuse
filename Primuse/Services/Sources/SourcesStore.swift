import Foundation
import PrimuseKit

@MainActor
@Observable
final class SourcesStore {
    private(set) var sources: [MusicSource]

    private let storeURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        self.storeURL = directory.appendingPathComponent("sources.json")
        self.sources = []

        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    func source(id: String) -> MusicSource? {
        sources.first(where: { $0.id == id })
    }

    func add(_ source: MusicSource) {
        upsert(source)
    }

    func upsert(_ source: MusicSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
            sources.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        persist()
    }

    func update(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        mutate(&sources[index])
        persist()
    }

    func remove(id: String) {
        sources.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? decoder.decode([MusicSource].self, from: data) else {
            sources = []
            return
        }

        sources = decoded.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func persist() {
        guard let data = try? encoder.encode(sources) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
