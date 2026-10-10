import Foundation

/// tvOS 的 Ting Reader 播放解析器:返回章节音频地址和 Bearer 头。
public actor TingReaderStreamResolver: StreamResolver {
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
        let client: TingReaderServiceClient
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
        guard source.type == .tingReader else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        guard TingReaderAPIProtocol.trackReference(from: song.filePath) != nil else {
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

    /// 电视端的封面与进度上报共用同一份登录会话。
    public func client(
        source: MusicSource,
        credential: SourceCredential?
    ) -> TingReaderServiceClient {
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
        let client = TingReaderServiceClient(source: source, credential: credential)
        clients[source.id] = Entry(configuration: configuration, client: client)
        return client
    }

    private static func streamError(from error: Error) -> Error {
        guard let error = error as? TingReaderServiceError else { return error }
        switch error {
        case .missingCredential:
            return StreamResolveError.missingCredential
        case .invalidURL, .invalidResponse, .rangeNotSupported:
            return StreamResolveError.cannotBuildURL
        case .authenticationFailed:
            return StreamResolveError.authFailed
        case .badServerResponse(let status):
            return StreamResolveError.badServerResponse(status)
        }
    }
}
