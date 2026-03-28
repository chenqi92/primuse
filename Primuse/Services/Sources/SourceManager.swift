import Foundation
import PrimuseKit

@Observable
final class SourceManager {
    private var connectors: [String: any MusicSourceConnector] = [:]
    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
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
        let sources = try await database.allSources()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }

        let conn = connector(for: source)
        return try await conn.localURL(for: song.filePath)
    }

    func disconnectAll() async {
        for (_, connector) in connectors {
            await connector.disconnect()
        }
        connectors.removeAll()
    }
}
