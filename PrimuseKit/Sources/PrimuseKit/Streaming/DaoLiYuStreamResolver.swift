import Foundation

/// tvOS 道理鱼播放解析器。返回规范 stream 路由和 Bearer 头，不使用响应中的临时 URL。
public actor DaoLiYuStreamResolver: StreamResolver {
    private struct Configuration: Equatable {
        let host: String?
        let port: Int?
        let useSSL: Bool
        let basePath: String?
        let sourceUsername: String?
        let credential: SourceCredential?
    }

    private struct Entry {
        let configuration: Configuration
        let client: DaoLiYuServiceClient
    }

    private var clients: [String: Entry] = [:]

    public init() {}

    public func streamURL(
        for song: Song,
        source: MusicSource,
        credential: SourceCredential?
    ) async throws -> URL {
        try await resolve(for: song, source: source, credential: credential).url
    }

    public func resolve(
        for song: Song,
        source: MusicSource,
        credential: SourceCredential?
    ) async throws -> ResolvedStream {
        guard source.type == .daoliyu else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        guard DaoLiYuAPIProtocol.trackID(from: song.filePath) != nil else {
            throw StreamResolveError.cannotBuildURL
        }
        do {
            return try await client(source: source, credential: credential)
                .resolvedStream(trackPath: song.filePath)
        } catch {
            throw Self.streamError(from: error)
        }
    }

    public func invalidateSession(sourceID: String) async {
        guard let entry = clients.removeValue(forKey: sourceID) else { return }
        await entry.client.invalidateSession()
    }

    private func client(
        source: MusicSource,
        credential: SourceCredential?
    ) -> DaoLiYuServiceClient {
        let configuration = Configuration(
            host: source.host,
            port: source.port,
            useSSL: source.useSsl,
            basePath: source.basePath,
            sourceUsername: source.username,
            credential: credential
        )
        if let entry = clients[source.id], entry.configuration == configuration {
            return entry.client
        }
        if let stale = clients.removeValue(forKey: source.id) {
            Task { await stale.client.invalidateSession() }
        }
        let client = DaoLiYuServiceClient(source: source, credential: credential)
        clients[source.id] = Entry(configuration: configuration, client: client)
        return client
    }

    private static func streamError(from error: Error) -> Error {
        guard let error = error as? DaoLiYuServiceError else { return error }
        switch error {
        case .missingCredential:
            return StreamResolveError.missingCredential
        case .invalidURL, .invalidResponse:
            return StreamResolveError.cannotBuildURL
        case .authenticationFailed:
            return StreamResolveError.authFailed
        case .badServerResponse(let status):
            return StreamResolveError.badServerResponse(status)
        }
    }
}
