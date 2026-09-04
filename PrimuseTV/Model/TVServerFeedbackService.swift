#if os(tvOS)
import Foundation
import PrimuseKit

enum TVServerFeedbackPolicy {
    static func supportsFavorite(_ type: MusicSourceType) -> Bool {
        ServerFavoriteWritebackPolicy.supports(type)
    }

    static func supportsNowPlaying(_ type: MusicSourceType) -> Bool {
        type.isSubsonicFamily
    }

    static func supportsScrobble(_ type: MusicSourceType) -> Bool {
        type.isSubsonicFamily || type == .fnMusic
    }
}

struct TVServerPlaybackFeedback: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case nowPlaying
        case scrobble
    }

    let id: UUID
    let song: Song
    let kind: Kind
    let occurredAt: Date
}

protocol TVServerFeedbackClient: Sendable {
    func setFavorite(
        song: Song,
        source: MusicSource,
        credential: SourceCredential,
        desired: Bool
    ) async throws -> Bool

    func report(
        _ feedback: TVServerPlaybackFeedback,
        source: MusicSource,
        credential: SourceCredential
    ) async throws

    func invalidate(source: MusicSource) async
}

enum TVServerFeedbackError: Error, LocalizedError, Sendable {
    case unsupported
    case invalidSongReference
    case invalidURL
    case authenticationFailed
    case httpStatus(Int)
    case invalidResponse
    case server(String)
    case favoriteMismatch

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return PMString("ext.tv.playback.failed")
        case .invalidSongReference:
            return PMString("error.catalog.invalidTrackReference")
        case .invalidURL:
            return PMString("ext.tv.playback.cannotBuildURL")
        case .authenticationFailed:
            return PMString("ext.tv.playback.authFailed")
        case .httpStatus(let status):
            return PMString("ext.tv.playback.httpError", status)
        case .invalidResponse, .favoriteMismatch:
            return PMString("ext.tv.playback.failed")
        case .server(let message):
            return message
        }
    }

    var isRetryable: Bool {
        switch self {
        case .authenticationFailed:
            return true
        case .httpStatus(let status):
            return status == 408 || status == 409 || status == 425 || status == 429 || status >= 500
        case .unsupported, .invalidSongReference, .invalidURL,
             .invalidResponse, .server, .favoriteMismatch:
            return false
        }
    }
}

/// Keeps tvOS' optimistic local liked state and server playback feedback in
/// step with the same provider boundaries used by the iOS/macOS connectors.
/// All public methods enqueue work and return immediately to keep remote I/O
/// off the UI interaction path.
@MainActor
final class TVServerFeedbackService {
    typealias SourceProvider = (String) -> MusicSource?
    typealias CredentialProvider = (MusicSource) -> SourceCredential
    typealias CurrentLikedState = (String) -> Bool
    typealias ApplyLikedState = (_ songID: String, _ isLiked: Bool) -> Void
    typealias ErrorReporter = (String) -> Void
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private struct SongKey: Hashable {
        let sourceID: String
        let songID: String
    }

    private struct ConfirmedLikedState {
        let sourceScopeFingerprint: String
        var value: Bool
    }

    private struct LikedMutation {
        let song: Song
        let sourceScopeFingerprint: String
        let sourceGeneration: UInt64
        let revision: UInt64
        let desired: Bool
    }

    private struct PendingNowPlaying {
        let feedback: TVServerPlaybackFeedback
        let sourceScopeFingerprint: String
        let sourceGeneration: UInt64
    }

    private struct ScrobbleTask {
        let sourceID: String
        let task: Task<Void, Never>
    }

    private let sourceProvider: SourceProvider
    private let credentialProvider: CredentialProvider
    private let currentLikedState: CurrentLikedState
    private let applyLikedState: ApplyLikedState
    private let reportError: ErrorReporter
    private let client: any TVServerFeedbackClient
    private let retryDelays: [Duration]
    private let sleeper: Sleeper

    private var sourceGenerations: [String: UInt64] = [:]
    private var likedMutationRevisions: [SongKey: UInt64] = [:]
    private var pendingLikedMutations: [String: [String: LikedMutation]] = [:]
    private var confirmedLikedStates: [SongKey: ConfirmedLikedState] = [:]
    private var likedMutationTasks: [String: Task<Void, Never>] = [:]

    private var pendingNowPlaying: [String: PendingNowPlaying] = [:]
    private var nowPlayingTasks: [String: Task<Void, Never>] = [:]
    private var scrobbleTasks: [UUID: ScrobbleTask] = [:]

    init(
        sourceProvider: @escaping SourceProvider,
        credentialProvider: @escaping CredentialProvider,
        currentLikedState: @escaping CurrentLikedState,
        applyLikedState: @escaping ApplyLikedState,
        reportError: @escaping ErrorReporter = { _ in }
    ) {
        self.sourceProvider = sourceProvider
        self.credentialProvider = credentialProvider
        self.currentLikedState = currentLikedState
        self.applyLikedState = applyLikedState
        self.reportError = reportError
        self.client = TVServerFeedbackHTTPClient()
        self.retryDelays = [.milliseconds(350), .seconds(1)]
        self.sleeper = { try await Task.sleep(for: $0) }
    }

    init(
        sourceProvider: @escaping SourceProvider,
        credentialProvider: @escaping CredentialProvider,
        currentLikedState: @escaping CurrentLikedState,
        applyLikedState: @escaping ApplyLikedState,
        reportError: @escaping ErrorReporter = { _ in },
        client: any TVServerFeedbackClient,
        retryDelays: [Duration],
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.sourceProvider = sourceProvider
        self.credentialProvider = credentialProvider
        self.currentLikedState = currentLikedState
        self.applyLikedState = applyLikedState
        self.reportError = reportError
        self.client = client
        self.retryDelays = retryDelays
        self.sleeper = sleeper
    }

    func setLiked(song: Song, previous: Bool, desired: Bool) {
        guard previous != desired,
              let source = activeSource(for: song),
              TVServerFeedbackPolicy.supportsFavorite(source.type) else { return }

        guard ServerFavoriteWritebackPolicy.songID(
            fromConnectorPath: song.filePath,
            sourceType: source.type
        ) != nil else {
            failImmediately(song: song, previous: previous, desired: desired,
                            error: TVServerFeedbackError.invalidSongReference)
            return
        }

        let key = SongKey(sourceID: song.sourceID, songID: song.id)
        let fingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)
        let revision = likedMutationRevisions[key, default: 0] &+ 1
        likedMutationRevisions[key] = revision
        if confirmedLikedStates[key]?.sourceScopeFingerprint != fingerprint {
            confirmedLikedStates[key] = ConfirmedLikedState(
                sourceScopeFingerprint: fingerprint,
                value: previous
            )
        }

        var mutations = pendingLikedMutations[song.sourceID] ?? [:]
        mutations[song.id] = LikedMutation(
            song: song,
            sourceScopeFingerprint: fingerprint,
            sourceGeneration: sourceGenerations[song.sourceID, default: 0],
            revision: revision,
            desired: desired
        )
        pendingLikedMutations[song.sourceID] = mutations
        startLikedMutationDrain(sourceID: song.sourceID)
    }

    func reportNowPlaying(song: Song) {
        guard let source = activeSource(for: song),
              TVServerFeedbackPolicy.supportsNowPlaying(source.type) else { return }
        pendingNowPlaying[song.sourceID] = PendingNowPlaying(
            feedback: TVServerPlaybackFeedback(
                id: UUID(),
                song: song,
                kind: .nowPlaying,
                occurredAt: Date()
            ),
            sourceScopeFingerprint: MusicSourceSecurityRevision.scopedFingerprint(for: source),
            sourceGeneration: sourceGenerations[song.sourceID, default: 0]
        )
        startNowPlayingDrain(sourceID: song.sourceID)
    }

    func reportScrobble(song: Song) {
        guard let source = activeSource(for: song),
              TVServerFeedbackPolicy.supportsScrobble(source.type) else { return }
        let feedback = TVServerPlaybackFeedback(
            id: UUID(),
            song: song,
            kind: .scrobble,
            occurredAt: Date()
        )
        let fingerprint = MusicSourceSecurityRevision.scopedFingerprint(for: source)
        let generation = sourceGenerations[song.sourceID, default: 0]
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.scrobbleTasks[feedback.id] = nil }
            _ = try? await self.withRetries(
                sourceID: song.sourceID,
                fingerprint: fingerprint,
                generation: generation,
                shouldContinue: { true }
            ) { source, credential in
                try await self.client.report(feedback, source: source, credential: credential)
            }
        }
        scrobbleTasks[feedback.id] = ScrobbleTask(sourceID: song.sourceID, task: task)
    }

    func cancel(sourceID: String) {
        sourceGenerations[sourceID, default: 0] &+= 1
        pendingLikedMutations[sourceID] = nil
        likedMutationTasks.removeValue(forKey: sourceID)?.cancel()
        pendingNowPlaying[sourceID] = nil
        nowPlayingTasks.removeValue(forKey: sourceID)?.cancel()

        let scrobbleIDs = scrobbleTasks.compactMap { id, entry in
            entry.sourceID == sourceID ? id : nil
        }
        for id in scrobbleIDs {
            scrobbleTasks.removeValue(forKey: id)?.task.cancel()
        }
        likedMutationRevisions = likedMutationRevisions.filter { $0.key.sourceID != sourceID }
        confirmedLikedStates = confirmedLikedStates.filter { $0.key.sourceID != sourceID }
    }

    func cancelAll() {
        let sourceIDs = Set(sourceGenerations.keys)
            .union(likedMutationTasks.keys)
            .union(nowPlayingTasks.keys)
            .union(scrobbleTasks.values.map(\.sourceID))
        for sourceID in sourceIDs {
            sourceGenerations[sourceID, default: 0] &+= 1
        }
        for task in likedMutationTasks.values { task.cancel() }
        for task in nowPlayingTasks.values { task.cancel() }
        for entry in scrobbleTasks.values { entry.task.cancel() }
        likedMutationRevisions.removeAll()
        pendingLikedMutations.removeAll()
        confirmedLikedStates.removeAll()
        likedMutationTasks.removeAll()
        pendingNowPlaying.removeAll()
        nowPlayingTasks.removeAll()
        scrobbleTasks.removeAll()
    }

    func waitForPendingWork(sourceID: String) async {
        while true {
            let tasks = [likedMutationTasks[sourceID], nowPlayingTasks[sourceID]].compactMap { $0 }
                + scrobbleTasks.values.filter { $0.sourceID == sourceID }.map(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
            await Task.yield()
        }
    }

    private func activeSource(for song: Song) -> MusicSource? {
        guard let source = sourceProvider(song.sourceID),
              source.isEnabled, !source.isDeleted,
              !MusicSourceSecurityRevision.hasPendingChange(for: source.id) else { return nil }
        return source
    }

    private func failImmediately(
        song: Song,
        previous: Bool,
        desired: Bool,
        error: Error
    ) {
        if currentLikedState(song.id) == desired {
            applyLikedState(song.id, previous)
        }
        reportFavoriteFailure(error)
    }

    private func startLikedMutationDrain(sourceID: String) {
        guard likedMutationTasks[sourceID] == nil else { return }
        let generation = sourceGenerations[sourceID, default: 0]
        likedMutationTasks[sourceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainLikedMutations(sourceID: sourceID)
            guard self.sourceGenerations[sourceID, default: 0] == generation else { return }
            self.likedMutationTasks[sourceID] = nil
            if self.pendingLikedMutations[sourceID]?.isEmpty == false {
                self.startLikedMutationDrain(sourceID: sourceID)
            }
        }
    }

    private func drainLikedMutations(sourceID: String) async {
        while !Task.isCancelled, let mutation = takeNextLikedMutation(sourceID: sourceID) {
            guard mutationScopeIsCurrent(mutation) else {
                discardConfirmedStateIfStale(mutation)
                continue
            }
            do {
                let serverValue = try await withRetries(
                    sourceID: sourceID,
                    fingerprint: mutation.sourceScopeFingerprint,
                    generation: mutation.sourceGeneration,
                    shouldContinue: { self.mutationRevisionIsCurrent(mutation) }
                ) { source, credential in
                    try await self.client.setFavorite(
                        song: mutation.song,
                        source: source,
                        credential: credential,
                        desired: mutation.desired
                    )
                }
                guard mutationScopeIsCurrent(mutation) else {
                    if sourceScopeIsCurrent(
                        sourceID: sourceID,
                        fingerprint: mutation.sourceScopeFingerprint,
                        generation: mutation.sourceGeneration
                    ) {
                        setConfirmedLikedState(serverValue, for: mutation)
                    } else {
                        discardConfirmedStateIfStale(mutation)
                    }
                    continue
                }
                guard serverValue == mutation.desired else {
                    throw TVServerFeedbackError.favoriteMismatch
                }
                setConfirmedLikedState(serverValue, for: mutation)
                clearConfirmedStateIfSettled(mutation)
            } catch is CancellationError {
                if Task.isCancelled { return }
                if mutationScopeIsCurrent(mutation) {
                    rollback(mutation)
                } else {
                    discardConfirmedStateIfStale(mutation)
                }
            } catch {
                guard mutationScopeIsCurrent(mutation) else { continue }
                rollback(mutation)
                reportFavoriteFailure(error)
            }
        }
    }

    private func takeNextLikedMutation(sourceID: String) -> LikedMutation? {
        guard var mutations = pendingLikedMutations[sourceID],
              let songID = mutations.keys.sorted().first,
              let mutation = mutations.removeValue(forKey: songID) else { return nil }
        pendingLikedMutations[sourceID] = mutations.isEmpty ? nil : mutations
        return mutation
    }

    private func mutationRevisionIsCurrent(_ mutation: LikedMutation) -> Bool {
        let key = SongKey(sourceID: mutation.song.sourceID, songID: mutation.song.id)
        return likedMutationRevisions[key] == mutation.revision
    }

    private func mutationScopeIsCurrent(_ mutation: LikedMutation) -> Bool {
        mutationRevisionIsCurrent(mutation)
            && sourceScopeIsCurrent(
                sourceID: mutation.song.sourceID,
                fingerprint: mutation.sourceScopeFingerprint,
                generation: mutation.sourceGeneration
            )
    }

    private func sourceScopeIsCurrent(
        sourceID: String,
        fingerprint: String,
        generation: UInt64
    ) -> Bool {
        guard sourceGenerations[sourceID, default: 0] == generation,
              let source = sourceProvider(sourceID),
              source.isEnabled, !source.isDeleted,
              !MusicSourceSecurityRevision.hasPendingChange(for: sourceID) else { return false }
        return MusicSourceSecurityRevision.scopedFingerprint(for: source) == fingerprint
    }

    private func setConfirmedLikedState(_ value: Bool, for mutation: LikedMutation) {
        confirmedLikedStates[
            SongKey(sourceID: mutation.song.sourceID, songID: mutation.song.id)
        ] = ConfirmedLikedState(
            sourceScopeFingerprint: mutation.sourceScopeFingerprint,
            value: value
        )
    }

    private func clearConfirmedStateIfSettled(_ mutation: LikedMutation) {
        guard pendingLikedMutations[mutation.song.sourceID]?[mutation.song.id] == nil else { return }
        let key = SongKey(sourceID: mutation.song.sourceID, songID: mutation.song.id)
        confirmedLikedStates[key] = nil
        likedMutationRevisions[key] = nil
    }

    private func discardConfirmedStateIfStale(_ mutation: LikedMutation) {
        let key = SongKey(sourceID: mutation.song.sourceID, songID: mutation.song.id)
        guard confirmedLikedStates[key]?.sourceScopeFingerprint
                == mutation.sourceScopeFingerprint,
              pendingLikedMutations[mutation.song.sourceID]?[mutation.song.id] == nil else { return }
        confirmedLikedStates[key] = nil
        likedMutationRevisions[key] = nil
    }

    private func rollback(_ mutation: LikedMutation) {
        let key = SongKey(sourceID: mutation.song.sourceID, songID: mutation.song.id)
        guard let confirmed = confirmedLikedStates[key],
              confirmed.sourceScopeFingerprint == mutation.sourceScopeFingerprint else {
            clearConfirmedStateIfSettled(mutation)
            return
        }
        if currentLikedState(mutation.song.id) == mutation.desired {
            applyLikedState(mutation.song.id, confirmed.value)
        }
        clearConfirmedStateIfSettled(mutation)
    }

    private func reportFavoriteFailure(_ error: Error) {
        reportError(PMString("ext.tv.test.failedDetail", error.localizedDescription))
    }

    private func startNowPlayingDrain(sourceID: String) {
        guard nowPlayingTasks[sourceID] == nil else { return }
        let generation = sourceGenerations[sourceID, default: 0]
        nowPlayingTasks[sourceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainNowPlaying(sourceID: sourceID)
            guard self.sourceGenerations[sourceID, default: 0] == generation else { return }
            self.nowPlayingTasks[sourceID] = nil
            if self.pendingNowPlaying[sourceID] != nil {
                self.startNowPlayingDrain(sourceID: sourceID)
            }
        }
    }

    private func drainNowPlaying(sourceID: String) async {
        while !Task.isCancelled,
              let pending = pendingNowPlaying.removeValue(forKey: sourceID) {
            _ = try? await withRetries(
                sourceID: sourceID,
                fingerprint: pending.sourceScopeFingerprint,
                generation: pending.sourceGeneration,
                shouldContinue: {
                    self.pendingNowPlaying[sourceID] == nil
                }
            ) { source, credential in
                try await self.client.report(
                    pending.feedback,
                    source: source,
                    credential: credential
                )
            }
        }
    }

    private func withRetries<T>(
        sourceID: String,
        fingerprint: String,
        generation: UInt64,
        shouldContinue: () -> Bool,
        operation: (MusicSource, SourceCredential) async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard shouldContinue(),
                  sourceScopeIsCurrent(
                    sourceID: sourceID,
                    fingerprint: fingerprint,
                    generation: generation
                  ),
                  let source = sourceProvider(sourceID) else {
                throw CancellationError()
            }
            let credential = credentialProvider(source)
            do {
                let value = try await operation(source, credential)
                try Task.checkCancellation()
                guard sourceScopeIsCurrent(
                    sourceID: sourceID,
                    fingerprint: fingerprint,
                    generation: generation
                ) else { throw CancellationError() }
                return value
            } catch {
                try Task.checkCancellation()
                guard shouldContinue(), Self.shouldRetry(error), attempt < retryDelays.count else {
                    throw error
                }
                await client.invalidate(source: source)
                let delay = retryDelays[attempt]
                attempt += 1
                try await sleeper(delay)
            }
        }
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let feedbackError = error as? TVServerFeedbackError {
            return feedbackError.isRetryable
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .badURL, .unsupportedURL, .userAuthenticationRequired,
                 .userCancelledAuthentication, .appTransportSecurityRequiresSecureConnection:
                return false
            default:
                return true
            }
        }
        if let streamError = error as? StreamResolveError {
            switch streamError {
            case .authFailed:
                return true
            case .badServerResponse(let status):
                return status == 408 || status == 409 || status == 425
                    || status == 429 || status >= 500
            case .missingCredential, .needs2FA, .cannotBuildURL,
                 .unsupportedSourceType, .relayUnavailable:
                return false
            }
        }
        return true
    }
}

actor TVServerFeedbackHTTPClient: TVServerFeedbackClient {
    private static let maximumResponseBytes = 4 * 1_024 * 1_024

    private let resolverRegistry: StreamResolverRegistry
    private let session: URLSession

    init(
        resolverRegistry: StreamResolverRegistry = .shared,
        session: URLSession? = nil
    ) {
        self.resolverRegistry = resolverRegistry
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            self.session = URLSession(
                configuration: configuration,
                delegate: TVInsecureTLSDelegate(),
                delegateQueue: nil
            )
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    func setFavorite(
        song: Song,
        source: MusicSource,
        credential: SourceCredential,
        desired: Bool
    ) async throws -> Bool {
        switch source.type {
        case .subsonic, .navidrome:
            return try await setSubsonicFavorite(
                song: song,
                source: source,
                credential: credential,
                desired: desired
            )
        case .emby:
            return try await setEmbyFavorite(
                song: song,
                source: source,
                credential: credential,
                desired: desired
            )
        default:
            throw TVServerFeedbackError.unsupported
        }
    }

    func report(
        _ feedback: TVServerPlaybackFeedback,
        source: MusicSource,
        credential: SourceCredential
    ) async throws {
        if source.type.isSubsonicFamily {
            try await reportSubsonic(feedback, source: source, credential: credential)
            return
        }
        if source.type == .fnMusic, feedback.kind == .scrobble {
            try await reportFnMusic(feedback, source: source, credential: credential)
        }
    }

    func invalidate(source: MusicSource) async {
        await resolverRegistry.invalidateSession(for: source)
    }

    private func setSubsonicFavorite(
        song: Song,
        source: MusicSource,
        credential: SourceCredential,
        desired: Bool
    ) async throws -> Bool {
        guard let itemID = ServerFavoriteWritebackPolicy.songID(
            fromConnectorPath: song.filePath,
            sourceType: source.type
        ) else { throw TVServerFeedbackError.invalidSongReference }
        let resolved = try await resolverRegistry.resolve(
            for: song,
            source: source,
            credential: credential
        )
        let mutationURL = try Self.subsonicURL(
            from: resolved.url,
            method: desired ? "star" : "unstar",
            queryItems: [URLQueryItem(name: "id", value: itemID)]
        )
        let mutationData = try await perform(
            request: Self.request(url: mutationURL, headers: resolved.headers)
        )
        if !mutationData.isEmpty {
            _ = try Self.subsonicRoot(from: mutationData)
        }

        let refreshURL = try Self.subsonicURL(
            from: resolved.url,
            method: "getStarred2",
            queryItems: []
        )
        let data = try await perform(
            request: Self.request(url: refreshURL, headers: resolved.headers)
        )
        let root = try Self.subsonicRoot(from: data)
        let itemIDs = Self.subsonicStarredSongIDs(root)
        return itemIDs.contains(itemID)
    }

    private func reportSubsonic(
        _ feedback: TVServerPlaybackFeedback,
        source: MusicSource,
        credential: SourceCredential
    ) async throws {
        guard let itemID = Self.serverSongID(from: feedback.song.filePath) else {
            throw TVServerFeedbackError.invalidSongReference
        }
        let resolved = try await resolverRegistry.resolve(
            for: feedback.song,
            source: source,
            credential: credential
        )
        var query = [
            URLQueryItem(name: "id", value: itemID),
            URLQueryItem(
                name: "submission",
                value: feedback.kind == .scrobble ? "true" : "false"
            ),
        ]
        if feedback.kind == .scrobble {
            query.append(URLQueryItem(
                name: "time",
                value: String(Int64((feedback.occurredAt.timeIntervalSince1970 * 1_000).rounded(.down)))
            ))
        }
        let url = try Self.subsonicURL(
            from: resolved.url,
            method: "scrobble",
            queryItems: query
        )
        let data = try await perform(request: Self.request(url: url, headers: resolved.headers))
        if !data.isEmpty {
            _ = try Self.subsonicRoot(from: data)
        }
    }

    private func setEmbyFavorite(
        song: Song,
        source: MusicSource,
        credential: SourceCredential,
        desired: Bool
    ) async throws -> Bool {
        guard let itemID = ServerFavoriteWritebackPolicy.songID(
            fromConnectorPath: song.filePath,
            sourceType: source.type
        ) else { throw TVServerFeedbackError.invalidSongReference }
        let resolved = try await resolverRegistry.resolve(
            for: song,
            source: source,
            credential: credential
        )
        guard let token = URLComponents(
            url: resolved.url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "api_key" })?.value,
        !token.isEmpty else {
            throw TVServerFeedbackError.authenticationFailed
        }
        let baseURL = try Self.serviceBaseURL(from: resolved.url, marker: "/Audio/")
        let headers = Self.embyHeaders(sourceID: source.id, token: token)
        let userID = try await embyUserID(baseURL: baseURL, headers: headers)
        let mutationURL = baseURL
            .appendingPathComponent("Users")
            .appendingPathComponent(userID)
            .appendingPathComponent("FavoriteItems")
            .appendingPathComponent(itemID)
        var mutationRequest = Self.request(url: mutationURL, headers: headers)
        mutationRequest.httpMethod = desired ? "POST" : "DELETE"
        _ = try await perform(request: mutationRequest)

        let itemURL = baseURL
            .appendingPathComponent("Users")
            .appendingPathComponent(userID)
            .appendingPathComponent("Items")
            .appendingPathComponent(itemID)
        let data = try await perform(request: Self.request(url: itemURL, headers: headers))
        guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userData = item["UserData"] as? [String: Any],
              let isFavorite = Self.bool(userData["IsFavorite"]) else {
            throw TVServerFeedbackError.invalidResponse
        }
        return isFavorite
    }

    private func embyUserID(baseURL: URL, headers: [String: String]) async throws -> String {
        do {
            let data = try await perform(request: Self.request(
                url: baseURL.appendingPathComponent("Users").appendingPathComponent("Me"),
                headers: headers
            ))
            guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = Self.nonemptyString(user["Id"] ?? user["id"]) else {
                throw TVServerFeedbackError.invalidResponse
            }
            return id
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let data = try await perform(request: Self.request(
                url: baseURL.appendingPathComponent("Users"),
                headers: headers
            ))
            guard let users = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let id = users.lazy.compactMap({
                      Self.nonemptyString($0["Id"] ?? $0["id"])
                  }).first else {
                throw error
            }
            return id
        }
    }

    private func reportFnMusic(
        _ feedback: TVServerPlaybackFeedback,
        source: MusicSource,
        credential: SourceCredential
    ) async throws {
        guard let trackGUID = FnMusicAPIProtocol.trackGUID(from: feedback.song.filePath) else {
            throw TVServerFeedbackError.invalidSongReference
        }
        let resolved = try await resolverRegistry.resolve(
            for: feedback.song,
            source: source,
            credential: credential
        )
        let url = try Self.fnMusicEventURL(from: resolved.url)
        let body = try SafeJSONSerialization.data(
            withJSONObject: [
                "events": [[
                    "eventType": "track_play",
                    "occurredAt": Int64(
                        (feedback.occurredAt.timeIntervalSince1970 * 1_000).rounded(.down)
                    ),
                    "payload": ["trackGUID": trackGUID],
                ]],
            ],
            options: [.sortedKeys]
        )
        var request = Self.request(url: url, headers: resolved.headers)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        FnMusicAPIProtocol.applyAuthx(to: &request, bodyData: body)
        let data = try await perform(request: request, redirectMode: .fnMusic)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = Self.int(envelope["code"]) else {
            throw TVServerFeedbackError.invalidResponse
        }
        guard code == 0 || code == 200 else {
            if code == 120001 || code == 401 || code == 403 {
                throw TVServerFeedbackError.authenticationFailed
            }
            throw TVServerFeedbackError.server(
                Self.nonemptyString(envelope["msg"] ?? envelope["message"])
                    ?? PMString("ext.tv.playback.failed")
            )
        }
    }

    private func perform(
        request: URLRequest,
        redirectMode: StreamResolverHTTPRedirectMode = .safe
    ) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: session,
            maximumBytes: Self.maximumResponseBytes,
            redirectMode: redirectMode
        )
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw TVServerFeedbackError.invalidResponse
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw TVServerFeedbackError.authenticationFailed
        }
        guard (200...299).contains(response.statusCode) else {
            throw TVServerFeedbackError.httpStatus(response.statusCode)
        }
        return data
    }

    nonisolated static func subsonicURL(
        from resolvedURL: URL,
        method: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false),
              let restRange = components.path.range(
                of: "/rest/",
                options: [.caseInsensitive, .backwards]
              ) else { throw TVServerFeedbackError.invalidURL }
        let prefix = components.path[..<restRange.lowerBound]
        components.path = "\(prefix)/rest/\(method).view"
        let authNames: Set<String> = ["u", "p", "t", "s", "v", "c", "f"]
        let authItems = (components.queryItems ?? []).filter { authNames.contains($0.name) }
        components.queryItems = authItems + queryItems
        guard let url = FormSafeQueryURLBuilder.url(from: components) else {
            throw TVServerFeedbackError.invalidURL
        }
        return url
    }

    nonisolated static func fnMusicEventURL(from resolvedURL: URL) throws -> URL {
        guard var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false),
              let apiRange = components.path.range(
                of: FnMusicAPIProtocol.apiPath,
                options: [.caseInsensitive, .backwards]
              ) else { throw TVServerFeedbackError.invalidURL }
        let prefix = components.path[..<apiRange.lowerBound]
        components.path = "\(prefix)\(FnMusicAPIProtocol.apiPath)/event/report"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw TVServerFeedbackError.invalidURL }
        return url
    }

    private nonisolated static func serviceBaseURL(
        from resolvedURL: URL,
        marker: String
    ) throws -> URL {
        guard var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false),
              let markerRange = components.path.range(
                of: marker,
                options: [.caseInsensitive, .backwards]
              ) else { throw TVServerFeedbackError.invalidURL }
        components.path = String(components.path[..<markerRange.lowerBound])
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw TVServerFeedbackError.invalidURL }
        return url
    }

    private nonisolated static func request(
        url: URL,
        headers: [String: String]
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private nonisolated static func embyHeaders(
        sourceID: String,
        token: String
    ) -> [String: String] {
        let deviceID = sourceID.replacingOccurrences(of: "\"", with: "")
        let authorization = "MediaBrowser Client=\"Primuse\", Device=\"Apple TV\", DeviceId=\"primuse-\(deviceID)\", Version=\"1.0.0\", Token=\"\(token)\""
        return [
            "X-Emby-Authorization": authorization,
            "X-Emby-Token": token,
        ]
    }

    private nonisolated static func subsonicRoot(from data: Data) throws -> [String: Any] {
        let normalized = try SubsonicResponseCompatibility.normalizedJSONData(data)
        guard let envelope = try JSONSerialization.jsonObject(with: normalized) as? [String: Any],
              let root = envelope["subsonic-response"] as? [String: Any],
              let status = nonemptyString(root["status"]) else {
            throw TVServerFeedbackError.invalidResponse
        }
        guard status.caseInsensitiveCompare("ok") == .orderedSame else {
            let error = root["error"] as? [String: Any]
            let code = int(error?["code"]) ?? -1
            if code == 40 || code == 41 {
                throw TVServerFeedbackError.authenticationFailed
            }
            throw TVServerFeedbackError.server(
                nonemptyString(error?["message"]) ?? PMString("ext.tv.playback.failed")
            )
        }
        return root
    }

    private nonisolated static func subsonicStarredSongIDs(
        _ root: [String: Any]
    ) -> Set<String> {
        guard let starred = root["starred2"] as? [String: Any] else { return [] }
        if let songs = starred["song"] as? [[String: Any]] {
            return Set(songs.compactMap { nonemptyString($0["id"]) })
        }
        if let song = starred["song"] as? [String: Any],
           let id = nonemptyString(song["id"]) {
            return [id]
        }
        return []
    }

    private nonisolated static func serverSongID(from path: String) -> String? {
        let fileName = (path as NSString).lastPathComponent
        guard !fileName.isEmpty, !fileName.hasPrefix("."),
              !fileName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        let id = (fileName as NSString).deletingPathExtension
        return id.isEmpty ? nil : id
    }

    private nonisolated static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private nonisolated static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
#endif
