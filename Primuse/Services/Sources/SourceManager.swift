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
        case .synology:
            connector = SynologySource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 5001,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? "",
                rememberDevice: source.rememberDevice,
                deviceId: source.deviceId
            )
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
        case .ftp:
            connector = FTPSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                basePath: source.basePath,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? "",
                encryption: source.ftpEncryption ?? .none
            )
        case .sftp:
            connector = SFTPSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                basePath: source.basePath,
                username: source.username ?? "",
                secret: KeychainService.getPassword(for: source.id) ?? "",
                authType: source.authType
            )
        case .nfs:
            connector = NFSSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                exportPath: source.exportPath,
                nfsVersion: source.nfsVersion ?? .auto
            )
        case .upnp:
            connector = UPnPSource(sourceID: source.id)
        case .jellyfin, .emby, .plex:
            connector = MediaServerSource(
                sourceID: source.id,
                kind: MediaServerSource.Kind(sourceType: source.type)!,
                host: source.host ?? "",
                port: source.port,
                useSsl: source.useSsl,
                basePath: source.basePath,
                username: source.username ?? "",
                secret: KeychainService.getPassword(for: source.id) ?? "",
                authType: source.authType
            )
        case .qnap:
            connector = QnapSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 8080,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .ugreen:
            connector = UgreenSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 9999,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .fnos:
            connector = FnOSSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 5666,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .baiduPan:
            connector = BaiduPanSource(sourceID: source.id)
        case .aliyunDrive:
            connector = AliyunDriveSource(sourceID: source.id)
        case .googleDrive:
            connector = GoogleDriveSource(sourceID: source.id)
        case .oneDrive:
            connector = OneDriveSource(sourceID: source.id)
        case .dropbox:
            connector = DropboxSource(sourceID: source.id)
        case .s3:
            // S3 uses host=endpoint, basePath=bucket, extraConfig=JSON{region}
            let extraJson = (try? JSONSerialization.jsonObject(with: Data((source.extraConfig ?? "{}").utf8))) as? [String: String] ?? [:]
            connector = S3Source(
                sourceID: source.id,
                endpoint: source.host ?? "s3.amazonaws.com",
                region: extraJson["region"] ?? "us-east-1",
                bucket: source.basePath ?? "",
                accessKey: source.username ?? "",
                secretKey: KeychainService.getPassword(for: source.id) ?? "",
                useSsl: source.useSsl
            )
        default:
            connector = UnsupportedSourceConnector(
                sourceID: source.id,
                sourceType: source.type
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

    /// Get the connector for a song's source (for file writing)
    func connectorForSong(_ song: Song) async throws -> any MusicSourceConnector {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let conn = connector(for: source)
        try await conn.connect()
        return conn
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
