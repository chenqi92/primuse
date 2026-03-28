import Foundation
import PrimuseKit

@MainActor
@Observable
final class SourceManager {
    private var connectors: [String: any MusicSourceConnector] = [:]
    private let sourcesProvider: @Sendable () async throws -> [MusicSource]

    init(database: LibraryDatabase) {
        self.sourcesProvider = {
            try await database.allSources()
        }
    }

    init(sourcesProvider: @escaping @Sendable () async throws -> [MusicSource]) {
        self.sourcesProvider = sourcesProvider
    }

    func connector(for source: MusicSource) -> any MusicSourceConnector {
        if let existing = connectors[source.id] {
            return existing
        }

        let connector: any MusicSourceConnector
        switch source.type {
        case .local:
            connector = LocalFileSource(
                sourceID: source.id,
                basePath: URL(fileURLWithPath: source.basePath ?? "/")
            )
        case .smb:
            connector = SMBSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 445,
                sharePath: source.shareName ?? "",
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .webdav:
            connector = WebDAVSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                basePath: source.basePath,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        default:
            // For unsupported types, fall back to a local source placeholder
            connector = LocalFileSource(
                sourceID: source.id,
                basePath: URL(fileURLWithPath: "/")
            )
        }

        connectors[source.id] = connector
        return connector
    }

    func resolveURL(for song: Song) async throws -> URL {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }

        let conn = connector(for: source)
        try await conn.connect()
        return try await conn.localURL(for: song.filePath)
    }

    func refreshConnector(for sourceID: String) async {
        guard let connector = connectors.removeValue(forKey: sourceID) else { return }
        await connector.disconnect()
    }

    func removeConnector(for sourceID: String) async {
        await refreshConnector(for: sourceID)
    }

    func disconnectAll() async {
        for (_, connector) in connectors {
            await connector.disconnect()
        }
        connectors.removeAll()
    }
}
