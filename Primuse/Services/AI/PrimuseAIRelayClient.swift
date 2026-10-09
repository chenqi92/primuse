import CryptoKit
import DeviceCheck
import Foundation
import PrimuseKit
import StoreKit

enum PrimuseAIRelayError: Error, Equatable, Sendable {
    case unsupportedDevice
    case credentialUnavailable
    case credentialCorrupted
    case credentialPersistenceFailed
    case storeKitTransactionUnavailable
    case storeKitTransactionUnverified
    case storeKitAuthenticationCancelled
    case invalidResponse
    case responseTooLarge
    case requestFailed(statusCode: Int, code: String, retryAt: Date? = nil)

    var retryAt: Date? {
        if case .requestFailed(_, _, let date) = self { return date }
        return nil
    }
}

enum PrimuseAIRelayAuthenticationMethod: Equatable, Sendable {
    case appAttest
    case storeKitFallback
}

enum PrimuseAIRelayDiagnosticCategory: Equatable, Sendable {
    case regionRestriction
    case deviceRegistration
    case serviceAuthentication
    case upstream
}

struct PrimuseAIRelayDiagnostic: Equatable, Sendable {
    var category: PrimuseAIRelayDiagnosticCategory
    var code: String
    /// 设备注册时 App Attest 被拒、StoreKit 兜底也没成:兜底那次的诊断码。
    var fallbackCode: String? = nil

    static func classify(_ error: Error) -> PrimuseAIRelayDiagnostic {
        let nsError = error as NSError
        if nsError.domain == DCError.errorDomain {
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "app_attest_\(nsError.code)"
            )
        }
        if let urlError = error as? URLError {
            let code: String
            switch urlError.code {
            case .timedOut:
                code = "network_timeout"
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                code = "network_unavailable"
            default:
                code = "network_error"
            }
            return PrimuseAIRelayDiagnostic(category: .upstream, code: code)
        }
        guard let relayError = error as? PrimuseAIRelayError else {
            return PrimuseAIRelayDiagnostic(category: .upstream, code: "unknown_error")
        }
        switch relayError {
        case .unsupportedDevice:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "unsupported_device"
            )
        case .credentialUnavailable:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "credential_unavailable"
            )
        case .credentialCorrupted:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "credential_corrupted"
            )
        case .credentialPersistenceFailed:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "credential_persistence_failed"
            )
        case .storeKitTransactionUnavailable:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "storekit_transaction_unavailable"
            )
        case .storeKitTransactionUnverified:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "storekit_transaction_unverified"
            )
        case .storeKitAuthenticationCancelled:
            return PrimuseAIRelayDiagnostic(
                category: .deviceRegistration,
                code: "storekit_authentication_cancelled"
            )
        case .invalidResponse:
            return PrimuseAIRelayDiagnostic(category: .upstream, code: "invalid_response")
        case .responseTooLarge:
            return PrimuseAIRelayDiagnostic(category: .upstream, code: "response_too_large")
        case .requestFailed(let statusCode, let code, _):
            let deviceRegistrationCodes: Set<String> = [
                "invalid_attestation",
                "invalid_app_attest_policy",
                "invalid_app_transaction",
                "storekit_enrollment_unavailable",
            ]
            let authenticationCodes: Set<String> = [
                "assertion_replayed",
                "expired_challenge",
                "feature_disabled",
                "feature_not_in_plan",
                "installation_blocked",
                "installation_mismatch",
                "installation_unavailable",
                "invalid_apple_app_id",
                "invalid_assertion",
                "invalid_challenge",
                "invalid_installation_token",
                "request_replayed",
            ]
            if deviceRegistrationCodes.contains(code) {
                return PrimuseAIRelayDiagnostic(category: .deviceRegistration, code: code)
            }
            if statusCode == 401 || statusCode == 403 || authenticationCodes.contains(code) {
                return PrimuseAIRelayDiagnostic(category: .serviceAuthentication, code: code)
            }
            return PrimuseAIRelayDiagnostic(category: .upstream, code: code)
        }
    }
}

struct PrimuseAIRelayCredential: Codable, Equatable, Sendable {
    var keyID: String
    var installationID: String?
    var accessToken: String? = nil
    /// 中转最近一次收到哪个构建的 App Store 签名交易;它据此识别构建号和 App Store/TestFlight。
    var storeProofBuild: String? = nil
    /// 上次补发签名交易失败的时间,一天内不再重试。
    var storeProofAttemptedAt: Date? = nil
}

struct PrimuseStoreKitEnrollmentMaterial: Equatable, Sendable {
    var appTransactionJWS: String
    var deviceVerificationID: String
}

protocol PrimuseAppAttesting: Actor {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

actor SystemPrimuseAppAttestor: PrimuseAppAttesting {
    private let service = DCAppAttestService.shared

    var isSupported: Bool { service.isSupported }

    func generateKey() async throws -> String {
        try await service.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

protocol PrimuseStoreKitEnrollmentProviding: Actor {
    var isSupported: Bool { get }
    func enrollmentMaterial(
        allowsRefresh: Bool
    ) async throws -> PrimuseStoreKitEnrollmentMaterial
}

actor SystemPrimuseStoreKitEnrollmentProvider: PrimuseStoreKitEnrollmentProviding {
    var isSupported: Bool { AppStore.deviceVerificationID != nil }

    func enrollmentMaterial(
        allowsRefresh: Bool
    ) async throws -> PrimuseStoreKitEnrollmentMaterial {
        guard let deviceVerificationID = AppStore.deviceVerificationID else {
            throw PrimuseAIRelayError.unsupportedDevice
        }

        do {
            let result = try await AppTransaction.shared
            if case .verified = result {
                return Self.material(
                    from: result,
                    deviceVerificationID: deviceVerificationID
                )
            }
            guard allowsRefresh else {
                throw PrimuseAIRelayError.storeKitTransactionUnverified
            }
        } catch {
            guard allowsRefresh else { throw Self.normalized(error) }
        }

        do {
            let result = try await AppTransaction.refresh()
            guard case .verified = result else {
                throw PrimuseAIRelayError.storeKitTransactionUnverified
            }
            return Self.material(
                from: result,
                deviceVerificationID: deviceVerificationID
            )
        } catch {
            throw Self.normalized(error)
        }
    }

    private static func material(
        from result: VerificationResult<AppTransaction>,
        deviceVerificationID: UUID
    ) -> PrimuseStoreKitEnrollmentMaterial {
        return PrimuseStoreKitEnrollmentMaterial(
            appTransactionJWS: result.jwsRepresentation,
            deviceVerificationID: deviceVerificationID.uuidString.lowercased()
        )
    }

    private static func normalized(_ error: Error) -> Error {
        if let relayError = error as? PrimuseAIRelayError {
            return relayError
        }
        if let urlError = error as? URLError {
            return urlError
        }
        guard let storeKitError = error as? StoreKitError else {
            return PrimuseAIRelayError.storeKitTransactionUnavailable
        }
        switch storeKitError {
        case .userCancelled:
            return PrimuseAIRelayError.storeKitAuthenticationCancelled
        case .networkError(let urlError):
            return urlError
        case .systemError(let underlyingError):
            return normalized(underlyingError)
        default:
            return PrimuseAIRelayError.storeKitTransactionUnavailable
        }
    }
}

protocol PrimuseAIRelayCredentialStoring: Actor {
    func load() throws -> PrimuseAIRelayCredential?
    func save(_ credential: PrimuseAIRelayCredential) throws
    func clear() throws
}

actor KeychainPrimuseAIRelayCredentialStore: PrimuseAIRelayCredentialStoring {
    private static let account = "primuse.ai.relay.installation.v1"

    func load() throws -> PrimuseAIRelayCredential? {
        switch KeychainService.localOnlyPasswordLookup(for: Self.account) {
        case .found(let value):
            guard let data = value.data(using: .utf8),
                  let credential = try? JSONDecoder().decode(
                    PrimuseAIRelayCredential.self,
                    from: data
                  ),
                  !credential.keyID.isEmpty else {
                throw PrimuseAIRelayError.credentialCorrupted
            }
            return credential
        case .notFound:
            return nil
        case .temporarilyUnavailable, .failed:
            throw PrimuseAIRelayError.credentialUnavailable
        }
    }

    func save(_ credential: PrimuseAIRelayCredential) throws {
        guard let data = try? JSONEncoder().encode(credential),
              let value = String(data: data, encoding: .utf8),
              KeychainService.setLocalOnlyPassword(value, for: Self.account) else {
            throw PrimuseAIRelayError.credentialPersistenceFailed
        }
    }

    func clear() throws {
        guard KeychainService.deletePassword(for: Self.account) else {
            throw PrimuseAIRelayError.credentialPersistenceFailed
        }
    }
}

actor PrimuseAIRelayClient {
    static let productionBaseURL = URL(string: "https://primuse.yzs.ai")!
    static let providerID = UUID(uuidString: "C8465401-5F73-4FC4-9A58-019220216BC9")!

    nonisolated static var isSupportedOnCurrentDevice: Bool {
        DCAppAttestService.shared.isSupported || AppStore.deviceVerificationID != nil
    }

    private static let appID = "primuse"
    /// 当前运行的构建号(CFBundleVersion)。
    nonisolated static var currentBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// iPhone 和 Mac 的 App 同名,系统默认的 User-Agent 分不出平台。Mac 上照系统的格式
    /// 把名字换成 PrimuseMac,中转据此把它算作 Mac;其他平台用系统默认值(返回 nil)。
    nonisolated static var platformUserAgent: String? {
        #if os(macOS)
        guard let build = currentBuild,
              let cfNetwork = Bundle(identifier: "com.apple.CFNetwork")?
                .object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        var system = utsname()
        guard uname(&system) == 0 else { return nil }
        let darwin = withUnsafeBytes(of: system.release) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard !darwin.isEmpty else { return nil }
        return "PrimuseMac/\(build) CFNetwork/\(cfNetwork) Darwin/\(darwin)"
        #else
        return nil
        #endif
    }
    private static let maximumResponseBytes = 1_048_576
    private static let requestIdleTimeout: TimeInterval = 60

    private let baseURL: URL
    private let session: URLSession
    private let attestor: any PrimuseAppAttesting
    private let storeKitEnrollmentProvider: any PrimuseStoreKitEnrollmentProviding
    private let credentialStore: any PrimuseAIRelayCredentialStoring
    private let transientRetryDelay: Duration
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// App Attest 注册被拒、StoreKit 兜底也没成时,兜底那次的诊断码。对外仍报 App Attest 的错误,
    /// 连接测试把这一段一起显示,兜底为什么没成就不会被盖住。
    private(set) var lastEnrollmentFallbackCode: String?

    init(
        baseURL: URL = PrimuseAIRelayClient.productionBaseURL,
        session: URLSession = PrimuseAIRelayClient.makeSession(),
        attestor: any PrimuseAppAttesting = SystemPrimuseAppAttestor(),
        storeKitEnrollmentProvider: any PrimuseStoreKitEnrollmentProviding = SystemPrimuseStoreKitEnrollmentProvider(),
        credentialStore: any PrimuseAIRelayCredentialStoring = KeychainPrimuseAIRelayCredentialStore(),
        transientRetryDelay: Duration = .seconds(1)
    ) {
        precondition(baseURL.scheme?.lowercased() == "https")
        self.baseURL = baseURL
        self.session = session
        self.attestor = attestor
        self.storeKitEnrollmentProvider = storeKitEnrollmentProvider
        self.credentialStore = credentialStore
        self.transientRetryDelay = transientRetryDelay
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func prepareInstallation() async throws -> String {
        let credential = try await ensureEnrollment(
            canReplaceInvalidKey: true,
            allowsStoreKitRefresh: false,
            prefersAppAttestUpgrade: false
        )
        guard let installationID = credential.installationID else {
            throw PrimuseAIRelayError.invalidResponse
        }
        return installationID
    }

    func testConnection() async throws -> PrimuseAIRelayAuthenticationMethod {
        lastEnrollmentFallbackCode = nil
        let request = AISemanticSearchRequest(
            query: "quiet evening music",
            languageCode: "en",
            maximumExpansionTerms: 2
        )
        let _: SemanticSearchOutput = try await performFeature(
            path: "/v1/semantic-search",
            purpose: "semantic_search",
            input: SemanticSearchInput(
                query: request.query,
                languageCode: request.languageCode,
                maximumExpansionTerms: request.maximumExpansionTerms
            ),
            allowsStoreKitRefresh: true,
            prefersAppAttestUpgrade: true
        )
        guard let credential = try await credentialStore.load(),
              credential.installationID != nil else {
            throw PrimuseAIRelayError.credentialUnavailable
        }
        return credential.accessToken == nil ? .appAttest : .storeKitFallback
    }

    func interpretSearch(
        _ request: AISemanticSearchRequest
    ) async throws -> AISemanticSearchPlan {
        let output: SemanticSearchOutput = try await performFeature(
            path: "/v1/semantic-search",
            purpose: "semantic_search",
            input: SemanticSearchInput(
                query: request.query,
                languageCode: request.languageCode,
                maximumExpansionTerms: request.maximumExpansionTerms
            )
        )
        return AISemanticSearchPlan(
            expandedTerms: output.expansionTerms,
            themes: [],
            moods: []
        ).normalized(for: request)
    }

    func semanticSearchEvents(
        _ request: AISemanticSearchRequest
    ) -> AsyncThrowingStream<AISemanticSearchStreamEvent, Error> {
        featureEventStream(
            path: "/v1/semantic-search",
            purpose: "semantic_search",
            input: SemanticSearchInput(
                query: request.query,
                languageCode: request.languageCode,
                maximumExpansionTerms: request.maximumExpansionTerms
            ),
            output: SemanticSearchOutput.self,
            progress: SemanticSearchProgress.self,
            progressIdentity: { $0.term.lowercased() }
        ) { rawEvent in
            switch rawEvent {
            case .reset:
                return .reset
            case .progress(let progress):
                let normalized = AISemanticSearchPlan(
                    expandedTerms: [progress.term]
                ).normalized(for: request)
                guard let term = normalized.expandedTerms.first else { return nil }
                return .term(term)
            case .completed(let output):
                return .completed(AISemanticSearchPlan(
                    expandedTerms: output.expansionTerms
                ).normalized(for: request))
            }
        }
    }

    func recommendations(
        _ request: AIRecommendationRequest
    ) async throws -> AIRecommendationPlan {
        let output: RecommendationsOutput = try await performFeature(
            path: "/v1/recommendations",
            purpose: "recommendations",
            input: RecommendationsInput(request: request)
        )
        return output.plan(for: request)
    }

    func recommendationEvents(
        _ request: AIRecommendationRequest
    ) -> AsyncThrowingStream<AIRecommendationStreamEvent, Error> {
        featureEventStream(
            path: "/v1/recommendations",
            purpose: "recommendations",
            input: RecommendationsInput(request: request),
            output: RecommendationsOutput.self,
            progress: RecommendationProgress.self,
            progressIdentity: { $0.identity }
        ) { rawEvent in
            switch rawEvent {
            case .reset:
                return .reset
            case .progress(let progress):
                let selection: AIRecommendationSelection
                if let item = progress.item {
                    guard request.candidates.contains(where: { $0.songID == item.songID }) else {
                        return nil
                    }
                    selection = AIRecommendationSelection(songID: item.songID, reason: item.reason)
                } else if let album = progress.album {
                    // A service only sends albums when this request asked for them.
                    guard request.albumCandidates.contains(where: { $0.albumKey == album.albumID }) else {
                        return nil
                    }
                    selection = AIRecommendationSelection(albumKey: album.albumID, reason: album.reason)
                } else {
                    return nil
                }
                let reason = selection.reason
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                guard !reason.isEmpty else { return nil }
                var bounded = selection
                bounded.reason = String(reason.prefix(120))
                return .selection(bounded)
            case .completed(let output):
                return .completed(output.plan(for: request))
            }
        }
    }

    func translateLyrics(
        _ candidates: [LyricTranslationCandidate],
        targetLanguageCode: String
    ) async throws -> [String: String] {
        let limitedCandidates = Array(candidates.prefix(80))
        let candidateIDs = Set(limitedCandidates.map(\.id))
        guard candidateIDs.count == limitedCandidates.count else {
            throw PrimuseAIRelayError.invalidResponse
        }
        let output: LyricsTranslationOutput = try await performFeature(
            path: "/v1/lyrics/translate",
            purpose: "lyrics_translation",
            input: LyricsTranslationInput(
                targetLanguageCode: targetLanguageCode,
                lines: limitedCandidates.map {
                    LyricsLine(
                        id: $0.id,
                        text: String($0.text.prefix(800)),
                        sourceLanguageCode: $0.sourceLanguageCode
                    )
                }
            )
        )
        var translations: [String: String] = [:]
        for line in output.lines {
            guard candidateIDs.contains(line.id), translations[line.id] == nil else {
                throw PrimuseAIRelayError.invalidResponse
            }
            translations[line.id] = line.translatedText
        }
        guard translations.count == candidateIDs.count else {
            throw PrimuseAIRelayError.invalidResponse
        }
        return translations
    }

    func lyricsTranslationEvents(
        _ candidates: [LyricTranslationCandidate],
        targetLanguageCode: String
    ) -> AsyncThrowingStream<AILyricsTranslationStreamEvent, Error> {
        let limitedCandidates = Array(candidates.prefix(80))
        let candidateIDs = Set(limitedCandidates.map(\.id))
        guard candidateIDs.count == limitedCandidates.count else {
            return AsyncThrowingStream { $0.finish(throwing: PrimuseAIRelayError.invalidResponse) }
        }
        return featureEventStream(
            path: "/v1/lyrics/translate",
            purpose: "lyrics_translation",
            input: LyricsTranslationInput(
                targetLanguageCode: targetLanguageCode,
                lines: limitedCandidates.map {
                    LyricsLine(
                        id: $0.id,
                        text: String($0.text.prefix(800)),
                        sourceLanguageCode: $0.sourceLanguageCode
                    )
                }
            ),
            output: LyricsTranslationOutput.self,
            progress: LyricsTranslationProgress.self,
            progressIdentity: { $0.line.id }
        ) { rawEvent in
            switch rawEvent {
            case .reset:
                return .reset
            case .progress(let progress):
                guard candidateIDs.contains(progress.line.id) else { return nil }
                return .translation(
                    id: progress.line.id,
                    text: progress.line.translatedText
                )
            case .completed(let output):
                var translations: [String: String] = [:]
                for line in output.lines where candidateIDs.contains(line.id) {
                    translations[line.id] = line.translatedText
                }
                guard translations.count == candidateIDs.count else { return nil }
                return .completed(translations)
            }
        }
    }

    /// Asks for tag corrections for one batch (at most
    /// `TagCleanupAIExchange.batchSize` songs). Song ids never leave the
    /// device: the rows carry short tokens. The answer only becomes
    /// proposals for the review screen. Streams so the request survives a
    /// busy relay and long answers; only the final answer is used.
    func tagCleanup(
        _ songs: [TagCleanupSong],
        languageCode: String,
        currentYear: Int
    ) async throws -> [TagCleanupProposal] {
        let batch = TagCleanupAIExchange.rows(for: songs)
        guard !batch.rows.isEmpty else { return [] }
        var completed: TagCleanupOutput?
        try await performStreamingFeature(
            path: "/v1/library/tag-cleanup",
            purpose: "tag_cleanup",
            input: TagCleanupInput(languageCode: languageCode, songs: batch.rows),
            output: TagCleanupOutput.self,
            progress: TagCleanupProgress.self
        ) { event in
            if case .completed(let output) = event { completed = output }
        }
        guard let completed else { throw PrimuseAIRelayError.invalidResponse }
        return TagCleanupAIExchange.proposals(
            from: completed.changes.map {
                TagCleanupAIExchange.Change(id: $0.id, field: $0.field, value: $0.value, reason: $0.reason)
            },
            songsByToken: batch.songsByToken,
            currentYear: currentYear
        )
    }

    /// Asks for real songs outside the library that fit its taste profile.
    /// Only aggregated genre/artist/decade weights and a short "avoid" list
    /// are sent. Streams like tag cleanup so a busy relay is waited out; only
    /// the final answer is used, and it is validated again on the device.
    func songDiscovery(
        _ request: SongDiscoveryAIExchange.Request,
        currentYear: Int
    ) async throws -> [SongDiscoverySuggestion] {
        var completed: SongDiscoveryOutput?
        try await performStreamingFeature(
            path: "/v1/discovery/songs",
            purpose: "song_discovery",
            input: request,
            output: SongDiscoveryOutput.self,
            progress: SongDiscoveryProgress.self
        ) { event in
            if case .completed(let output) = event { completed = output }
        }
        guard let completed else { throw PrimuseAIRelayError.invalidResponse }
        return SongDiscoveryAIExchange.validated(
            completed.songs.map {
                SongDiscoveryAIExchange.RawItem(
                    title: $0.title,
                    artist: $0.artist,
                    album: $0.album,
                    year: $0.year,
                    reason: $0.reason
                )
            },
            request: request,
            currentYear: currentYear
        )
    }

    /// Asks the built-in AI to choose and name "for you" intents from a
    /// summary of the listening profile (folder, artist and album names,
    /// genre/decade/quality shares; play figures only with listening
    /// consent). The answer is checked again against the profile on the device.
    func listeningIntents(
        _ request: ListeningIntentAIExchange.Request
    ) async throws -> [ListeningIntentAIExchange.Draft] {
        var completed: ListeningIntentsOutput?
        try await performStreamingFeature(
            path: "/v1/listening/intents",
            purpose: "listening_intents",
            input: request,
            output: ListeningIntentsOutput.self,
            progress: ListeningIntentsProgress.self
        ) { event in
            if case .completed(let output) = event { completed = output }
        }
        guard let completed else { throw PrimuseAIRelayError.invalidResponse }
        return ListeningIntentAIExchange.validated(
            completed.intents.map {
                ListeningIntentAIExchange.RawItem(
                    kind: $0.kind,
                    title: $0.title,
                    refs: $0.refs,
                    genres: $0.genres,
                    decade: $0.decade,
                    quality: $0.quality
                )
            },
            request: request
        )
    }

    /// A short intro for one album or artist. Only names (album, artist,
    /// tracks, genres) are sent; the answer is validated again on the device.
    func libraryInsight(
        _ request: LibraryInsightAIExchange.Request
    ) async throws -> LibraryInsightAIExchange.Answer {
        var completed: LibraryInsightOutput?
        try await performStreamingFeature(
            path: "/v1/library/insights",
            purpose: "library_insight",
            input: request,
            output: LibraryInsightOutput.self,
            progress: LibraryInsightProgress.self
        ) { event in
            if case .completed(let output) = event { completed = output }
        }
        guard let completed else { throw PrimuseAIRelayError.invalidResponse }
        do {
            return try LibraryInsightAIExchange.validated(
                known: completed.known,
                summary: completed.summary,
                tags: completed.tags ?? []
            )
        } catch {
            throw PrimuseAIRelayError.invalidResponse
        }
    }

    /// 最近 30 天听歌状态的一段解读。只发习惯层面的数字和常听的名字；回答在设备上
    /// 再校验一遍。
    func listeningMood(
        _ request: ListeningMoodAIExchange.Request
    ) async throws -> ListeningMoodAIExchange.Answer {
        var completed: ListeningMoodOutput?
        try await performStreamingFeature(
            path: "/v1/listening/mood",
            purpose: "listening_mood",
            input: request,
            output: ListeningMoodOutput.self,
            progress: ListeningMoodProgress.self
        ) { event in
            if case .completed(let output) = event { completed = output }
        }
        guard let completed else { throw PrimuseAIRelayError.invalidResponse }
        do {
            return try ListeningMoodAIExchange.validated(
                title: completed.title,
                summary: completed.summary,
                keywords: completed.keywords ?? []
            )
        } catch {
            throw PrimuseAIRelayError.invalidResponse
        }
    }

    /// 听歌识词:把本机转好的 M4A 整份交给内置 AI,等它把每个词的起止时间带回来。
    /// 一首歌要转写几十秒,中转在 NDJSON 流里每 10 秒发一个空行保活;时长以中转
    /// 从文件里读出来的为准(上限 10 分钟)。
    func transcribeAudio(
        fileURL: URL,
        languageCodes: [String] = []
    ) async throws -> AIAudioTranscriptionResult {
        let audio = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard !audio.isEmpty,
              audio.count <= AIAudioTranscriptionPolicy.builtInMaximumUploadBytes else {
            throw PrimuseAIRelayError.requestFailed(statusCode: 413, code: "request_too_large")
        }
        var completed: AudioTranscriptionOutput?
        try await performStreamingFeature(
            path: "/v1/audio/transcriptions",
            purpose: "audio_transcription",
            input: AudioTranscriptionInput(
                audioBase64: audio.base64EncodedString(),
                mimeType: "audio/m4a",
                languageCodes: languageCodes.isEmpty ? nil : Array(languageCodes.prefix(3))
            ),
            output: AudioTranscriptionOutput.self,
            progress: AudioTranscriptionProgress.self
        ) { event in
            if case .completed(let output) = event { completed = output }
        }
        guard let completed else { throw PrimuseAIRelayError.invalidResponse }
        return AIAudioTranscriptionResult(
            transcript: completed.transcript ?? "",
            words: (completed.words ?? []).map {
                AIAudioTranscriptionWord(text: $0.text, startTime: $0.start, endTime: $0.end)
            }
        )
    }

    /// 内置 AI 现在有没有转写模型可用(后台没配好时听歌识词入口不该出现)。
    /// 读不到就是不知道,返回 nil。
    func isAudioTranscriptionOffered() async -> Bool? {
        guard let url = URL(string: "/v1/service-info", relativeTo: baseURL)?.absoluteURL else { return nil }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        if let userAgent = Self.platformUserAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= Self.maximumResponseBytes,
              let envelope = try? decoder.decode(SuccessEnvelope<ServiceInfoOutput>.self, from: data) else {
            return nil
        }
        switch envelope.data.audioTranscription {
        case "available": return true
        case nil: return nil
        default: return false
        }
    }

    /// 当前套餐有没有听歌识词:套餐没开放,或转写线路都只留给更高的套餐时,中转在
    /// 用量接口的套餐里不列出它,这时去识别只会被拒。读不到就是不知道,返回 nil。
    func isAudioTranscriptionInPlan() async -> Bool? {
        guard let usage: UsagePlanOutput = try? await performFeature(
            path: "/v1/account/usage",
            purpose: "usage",
            input: UsageQueryInput(limit: 1)
        ) else { return nil }
        return (usage.plan?.features?["audio_transcription"] ?? 0) > 0
    }

    /// 今天(和这个周期)简介用了几次、各项上限多少:批量补简介前估一下还能补几个。
    /// 用量接口不占次数;读不到返回 nil。
    func libraryInsightAllowance() async -> LibraryInsightBuiltInAllowance? {
        guard let usage: UsageAllowanceOutput = try? await performFeature(
            path: "/v1/account/usage",
            purpose: "usage",
            input: UsageQueryInput(limit: 1)
        ), let today = usage.today else { return nil }
        let feature = today.features?["library_insight"]
        let periodFeature = usage.period?.features?["library_insight"]
        return LibraryInsightBuiltInAllowance(
            featureRequests: feature?.requests ?? 0,
            featureLimit: feature?.limit,
            requests: today.requests ?? 0,
            requestLimit: today.requestLimit,
            credits: Int(today.credits ?? 0),
            creditLimit: today.creditLimit.map { Int($0) },
            periodFeatureRequests: periodFeature?.requests ?? 0,
            periodFeatureLimit: periodFeature?.limit,
            periodRequests: usage.period?.requests ?? 0,
            periodRequestLimit: usage.period?.requestLimit
        )
    }

    nonisolated static func assertionClientDataHash(
        challenge: String,
        method: String,
        path: String,
        body: Data
    ) -> Data {
        let bodyHash = Data(SHA256.hash(data: body)).base64URLEncodedString()
        let clientData = [
            "primuse-ai/v1",
            challenge,
            method.uppercased(),
            path,
            bodyHash,
        ].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(clientData.utf8)))
    }

    private enum FeatureWireEvent<Progress: Sendable, Output: Sendable>: Sendable {
        case reset
        case progress(Progress)
        case completed(Output)
    }

    private func featureEventStream<
        Input: Encodable & Sendable,
        Output: Decodable & Sendable,
        Progress: Decodable & Sendable,
        Event: Sendable
    >(
        path: String,
        purpose: String,
        input: Input,
        output: Output.Type,
        progress: Progress.Type,
        progressIdentity: @escaping @Sendable (Progress) -> String? = { _ in nil },
        transform: @escaping @Sendable (FeatureWireEvent<Progress, Output>) -> Event?
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let operation = Task {
                var hasEmittedProgress = false
                var emittedProgressIdentities = Set<String>()
                do {
                    try await self.performStreamingFeature(
                        path: path,
                        purpose: purpose,
                        input: input,
                        output: output,
                        progress: progress
                    ) { wireEvent in
                        switch wireEvent {
                        case .reset where hasEmittedProgress:
                            return
                        case .progress(let progress):
                            hasEmittedProgress = true
                            if let identity = progressIdentity(progress),
                               !emittedProgressIdentities.insert(identity).inserted {
                                return
                            }
                        case .reset, .completed:
                            break
                        }
                        if let event = transform(wireEvent) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in operation.cancel() }
        }
    }

    private func performStreamingFeature<
        Input: Encodable & Sendable,
        Output: Decodable & Sendable,
        Progress: Decodable & Sendable
    >(
        path: String,
        purpose: String,
        input: Input,
        output: Output.Type,
        progress: Progress.Type,
        canRecoverLocalAppAttestCredential: Bool = true,
        canRecoverServerCredential: Bool = true,
        canRetryFreshProof: Bool = true,
        canRetryTransientFailure: Bool = true,
        emit: (FeatureWireEvent<Progress, Output>) -> Void
    ) async throws {
        var receivedProgress = false
        do {
            let request = try await streamingFeatureRequest(
                path: path,
                purpose: purpose,
                input: input
            )
            try await consumeFeatureResponse(
                request: request,
                output: output,
                progress: progress,
                emit: { event in
                    if case .progress = event { receivedProgress = true }
                    emit(event)
                }
            )
        } catch {
            if receivedProgress { throw error }
            if canRecoverLocalAppAttestCredential,
               Self.isLocalAppAttestFailure(error) {
                try await credentialStore.clear()
                return try await performStreamingFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    output: output,
                    progress: progress,
                    canRecoverLocalAppAttestCredential: false,
                    canRecoverServerCredential: canRecoverServerCredential,
                    canRetryFreshProof: canRetryFreshProof,
                    canRetryTransientFailure: canRetryTransientFailure,
                    emit: emit
                )
            }
            if canRecoverServerCredential,
               Self.shouldReplaceCredential(after: error) {
                try await credentialStore.clear()
                return try await performStreamingFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    output: output,
                    progress: progress,
                    canRecoverLocalAppAttestCredential: canRecoverLocalAppAttestCredential,
                    canRecoverServerCredential: false,
                    canRetryFreshProof: canRetryFreshProof,
                    canRetryTransientFailure: canRetryTransientFailure,
                    emit: emit
                )
            }
            if canRetryFreshProof,
               Self.shouldRetryWithFreshProof(after: error) {
                return try await performStreamingFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    output: output,
                    progress: progress,
                    canRecoverLocalAppAttestCredential: canRecoverLocalAppAttestCredential,
                    canRecoverServerCredential: canRecoverServerCredential,
                    canRetryFreshProof: false,
                    canRetryTransientFailure: canRetryTransientFailure,
                    emit: emit
                )
            }
            if canRetryTransientFailure,
               Self.shouldRetryTransientStream(after: error) {
                if let retryAt = (error as? PrimuseAIRelayError)?.retryAt {
                    try await Task.sleep(for: .seconds(max(0, retryAt.timeIntervalSinceNow)))
                } else {
                    try await Task.sleep(for: transientRetryDelay)
                }
                return try await performStreamingFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    output: output,
                    progress: progress,
                    canRecoverLocalAppAttestCredential: canRecoverLocalAppAttestCredential,
                    canRecoverServerCredential: canRecoverServerCredential,
                    canRetryFreshProof: canRetryFreshProof,
                    canRetryTransientFailure: false,
                    emit: emit
                )
            }
            throw error
        }
    }

    private func streamingFeatureRequest<Input: Encodable & Sendable>(
        path: String,
        purpose: String,
        input: Input
    ) async throws -> URLRequest {
        let body = try encoder.encode(input)
        let credential = try await ensureEnrollment(
            canReplaceInvalidKey: true,
            allowsStoreKitRefresh: false,
            prefersAppAttestUpgrade: false
        )
        var request = try makeRequest(path: path, body: body)
        if let accessToken = credential.accessToken, !accessToken.isEmpty {
            request.setValue(accessToken, forHTTPHeaderField: "X-Primuse-Installation-Token")
            request.setValue(
                UUID().uuidString.lowercased(),
                forHTTPHeaderField: "X-Primuse-Request-Nonce"
            )
        } else {
            let challenge = try await issueChallenge(purpose: purpose)
            let clientDataHash = Self.assertionClientDataHash(
                challenge: challenge,
                method: "POST",
                path: path,
                body: body
            )
            let assertionResult = try await assertion(
                credential: credential,
                clientDataHash: clientDataHash
            )
            request.setValue(challenge, forHTTPHeaderField: "X-Primuse-Challenge")
            request.setValue(
                assertionResult.1.base64URLEncodedString(),
                forHTTPHeaderField: "X-Primuse-Assertion"
            )
        }
        guard let installationID = credential.installationID else {
            throw PrimuseAIRelayError.invalidResponse
        }
        request.setValue(Self.appID, forHTTPHeaderField: "X-Primuse-App-Id")
        request.setValue(installationID, forHTTPHeaderField: "X-Primuse-Installation-Id")
        request.setValue(
            "application/x-ndjson, application/json",
            forHTTPHeaderField: "Accept"
        )
        return request
    }

    private func consumeFeatureResponse<
        Output: Decodable & Sendable,
        Progress: Decodable & Sendable
    >(
        request: URLRequest,
        output: Output.Type,
        progress: Progress.Type,
        emit: (FeatureWireEvent<Progress, Output>) -> Void
    ) async throws {
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw PrimuseAIRelayError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(min(response.expectedContentLength > 0
            ? Int(response.expectedContentLength) : 8_192, Self.maximumResponseBytes))

        if !(200..<300).contains(response.statusCode) {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else {
                    throw PrimuseAIRelayError.responseTooLarge
                }
                data.append(byte)
            }
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw PrimuseAIRelayError.requestFailed(
                statusCode: response.statusCode,
                code: Self.safeDiagnosticCode(
                    envelope?.error.code,
                    statusCode: response.statusCode
                ),
                retryAt: Self.retryDate(header: response.value(forHTTPHeaderField: "Retry-After"))
            )
        }

        let isNDJSON = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("application/x-ndjson") == true
        guard isNDJSON else {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else {
                    throw PrimuseAIRelayError.responseTooLarge
                }
                data.append(byte)
            }
            guard let envelope = try? decoder.decode(SuccessEnvelope<Output>.self, from: data) else {
                throw PrimuseAIRelayError.invalidResponse
            }
            emit(.completed(envelope.data))
            return
        }

        var line = Data()
        var didComplete = false
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumResponseBytes else {
                throw PrimuseAIRelayError.responseTooLarge
            }
            data.append(byte)
            if byte == 0x0A {
                if let event = try decodeFeatureStreamLine(
                    line,
                    output: output,
                    progress: progress
                ) {
                    emit(event)
                    if case .completed = event { return }
                }
                line.removeAll(keepingCapacity: true)
            } else if byte != 0x0D {
                line.append(byte)
            }
        }
        if !line.isEmpty,
           let event = try decodeFeatureStreamLine(line, output: output, progress: progress) {
            if case .completed = event { didComplete = true }
            emit(event)
        }
        guard didComplete else { throw PrimuseAIRelayError.invalidResponse }
    }

    private func decodeFeatureStreamLine<
        Output: Decodable & Sendable,
        Progress: Decodable & Sendable
    >(
        _ line: Data,
        output: Output.Type,
        progress: Progress.Type
    ) throws -> FeatureWireEvent<Progress, Output>? {
        guard !line.isEmpty else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else {
            throw PrimuseAIRelayError.invalidResponse
        }
        switch type {
        case "started":
            return nil
        case "reset":
            return .reset
        case "progress":
            guard let value = object["data"],
                  JSONSerialization.isValidJSONObject(value),
                  let decoded = try? decoder.decode(
                    progress,
                    from: JSONSerialization.data(withJSONObject: value)
                  ) else { throw PrimuseAIRelayError.invalidResponse }
            return .progress(decoded)
        case "complete":
            guard let value = object["data"],
                  JSONSerialization.isValidJSONObject(value),
                  let decoded = try? decoder.decode(
                    output,
                    from: JSONSerialization.data(withJSONObject: value)
                  ) else { throw PrimuseAIRelayError.invalidResponse }
            return .completed(decoded)
        case "error":
            let error = object["error"] as? [String: Any]
            let status = error?["status"] as? Int ?? 502
            throw PrimuseAIRelayError.requestFailed(
                statusCode: status,
                code: Self.safeDiagnosticCode(error?["code"] as? String, statusCode: status),
                retryAt: Self.retryDate(seconds: error?["retry_after"] as? Double)
            )
        default:
            throw PrimuseAIRelayError.invalidResponse
        }
    }

    private func performFeature<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        path: String,
        purpose: String,
        input: Input,
        allowsStoreKitRefresh: Bool = false,
        prefersAppAttestUpgrade: Bool = false,
        canRecoverLocalAppAttestCredential: Bool = true,
        canRecoverServerCredential: Bool = true,
        canRetryFreshProof: Bool = true
    ) async throws -> Output {
        let body = try encoder.encode(input)
        let initialCredential = try await ensureEnrollment(
            canReplaceInvalidKey: true,
            allowsStoreKitRefresh: allowsStoreKitRefresh,
            prefersAppAttestUpgrade: prefersAppAttestUpgrade
        )
        let credential: PrimuseAIRelayCredential
        var request = try makeRequest(path: path, body: body)
        if let accessToken = initialCredential.accessToken, !accessToken.isEmpty {
            credential = initialCredential
            request.setValue(
                accessToken,
                forHTTPHeaderField: "X-Primuse-Installation-Token"
            )
            request.setValue(
                UUID().uuidString.lowercased(),
                forHTTPHeaderField: "X-Primuse-Request-Nonce"
            )
        } else {
            let challenge = try await issueChallenge(purpose: purpose)
            let clientDataHash = Self.assertionClientDataHash(
                challenge: challenge,
                method: "POST",
                path: path,
                body: body
            )
            let assertionResult: (PrimuseAIRelayCredential, Data)
            do {
                assertionResult = try await assertion(
                    credential: initialCredential,
                    clientDataHash: clientDataHash
                )
            } catch {
                guard canRecoverLocalAppAttestCredential,
                      Self.isLocalAppAttestFailure(error) else { throw error }
                try await credentialStore.clear()
                return try await performFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    allowsStoreKitRefresh: allowsStoreKitRefresh,
                    prefersAppAttestUpgrade: prefersAppAttestUpgrade,
                    canRecoverLocalAppAttestCredential: false,
                    canRecoverServerCredential: canRecoverServerCredential,
                    canRetryFreshProof: canRetryFreshProof
                )
            }
            credential = assertionResult.0
            request.setValue(challenge, forHTTPHeaderField: "X-Primuse-Challenge")
            request.setValue(
                assertionResult.1.base64URLEncodedString(),
                forHTTPHeaderField: "X-Primuse-Assertion"
            )
        }
        guard let installationID = credential.installationID else {
            throw PrimuseAIRelayError.invalidResponse
        }

        request.setValue(Self.appID, forHTTPHeaderField: "X-Primuse-App-Id")
        request.setValue(installationID, forHTTPHeaderField: "X-Primuse-Installation-Id")
        do {
            let envelope = try await send(SuccessEnvelope<Output>.self, request: request)
            return envelope.data
        } catch {
            if canRecoverServerCredential,
               Self.shouldReplaceCredential(after: error) {
                try await credentialStore.clear()
                return try await performFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    allowsStoreKitRefresh: allowsStoreKitRefresh,
                    prefersAppAttestUpgrade: prefersAppAttestUpgrade,
                    canRecoverLocalAppAttestCredential: canRecoverLocalAppAttestCredential,
                    canRecoverServerCredential: false,
                    canRetryFreshProof: canRetryFreshProof
                )
            }
            if canRetryFreshProof,
               Self.shouldRetryWithFreshProof(after: error) {
                return try await performFeature(
                    path: path,
                    purpose: purpose,
                    input: input,
                    allowsStoreKitRefresh: allowsStoreKitRefresh,
                    prefersAppAttestUpgrade: prefersAppAttestUpgrade,
                    canRecoverLocalAppAttestCredential: canRecoverLocalAppAttestCredential,
                    canRecoverServerCredential: canRecoverServerCredential,
                    canRetryFreshProof: false
                )
            }
            throw error
        }
    }

    private func ensureEnrollment(
        canReplaceInvalidKey: Bool,
        allowsStoreKitRefresh: Bool,
        prefersAppAttestUpgrade: Bool
    ) async throws -> PrimuseAIRelayCredential {
        let supportsAppAttest = await attestor.isSupported
        do {
            if let credential = try await credentialStore.load(),
               let installationID = credential.installationID,
               !installationID.isEmpty {
                let hasStoreKitToken = credential.accessToken?.isEmpty == false
                if credential.accessToken != nil, !hasStoreKitToken {
                    try await credentialStore.clear()
                } else if hasStoreKitToken {
                    if !prefersAppAttestUpgrade || !supportsAppAttest {
                        return credential
                    }
                    try await credentialStore.clear()
                } else if supportsAppAttest {
                    return credential
                } else {
                    try await credentialStore.clear()
                }
            }
        } catch PrimuseAIRelayError.credentialCorrupted {
            try await credentialStore.clear()
        }

        var appAttestFailure: Error?
        if supportsAppAttest {
            do {
                return try await ensureAppAttestEnrollment(
                    canReplaceInvalidKey: canReplaceInvalidKey
                )
            } catch {
                guard Self.isRecoverableAppAttestEnrollmentFailure(error) else {
                    throw error
                }
                try await credentialStore.clear()
                appAttestFailure = error
            }
        }
        do {
            return try await ensureStoreKitEnrollment(allowsRefresh: allowsStoreKitRefresh)
        } catch {
            if let appAttestFailure {
                lastEnrollmentFallbackCode = PrimuseAIRelayDiagnostic.classify(error).code
                throw appAttestFailure
            }
            throw error
        }
    }

    private func ensureAppAttestEnrollment(
        canReplaceInvalidKey: Bool,
        canRetryFreshChallenge: Bool = true
    ) async throws -> PrimuseAIRelayCredential {
        let existing = try await credentialStore.load()
        let keyID: String
        if let existing, existing.accessToken == nil {
            keyID = existing.keyID
        } else {
            keyID = try await attestor.generateKey()
            try await credentialStore.save(PrimuseAIRelayCredential(
                keyID: keyID,
                installationID: nil
            ))
        }

        // 先取签名交易再领挑战,App Store 查得慢也不会让挑战过期。
        let storeProof = await optionalStoreProof()
        let challenge = try await issueChallenge(purpose: "enroll")
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestationObject: Data
        do {
            attestationObject = try await attestor.attestKey(
                keyID,
                clientDataHash: clientDataHash
            )
        } catch {
            guard canReplaceInvalidKey, Self.isInvalidAppAttestKey(error) else { throw error }
            try await credentialStore.clear()
            return try await ensureAppAttestEnrollment(
                canReplaceInvalidKey: false,
                canRetryFreshChallenge: canRetryFreshChallenge
            )
        }

        let body = try encoder.encode(EnrollmentInput(
            appID: Self.appID,
            keyID: keyID,
            challenge: challenge,
            attestationObject: attestationObject.base64URLEncodedString(),
            appTransactionJWS: storeProof?.appTransactionJWS,
            deviceVerificationID: storeProof?.deviceVerificationID
        ))
        let response: EnrollmentOutput
        do {
            response = try await send(
                EnrollmentOutput.self,
                request: try makeRequest(path: "/v1/auth/installations", body: body)
            )
        } catch {
            // 网络慢、证明拖得久时挑战会过期:换新挑战再证明一次(同一把钥匙被拒就换钥匙)。
            guard canRetryFreshChallenge, Self.shouldRetryWithFreshProof(after: error) else { throw error }
            return try await ensureAppAttestEnrollment(
                canReplaceInvalidKey: canReplaceInvalidKey,
                canRetryFreshChallenge: false
            )
        }
        // 签名交易被拒(比如 Xcode 装的包)也记下这一版,不在每次启动时重发。
        let credential = PrimuseAIRelayCredential(
            keyID: keyID,
            installationID: response.installationID,
            storeProofBuild: storeProof == nil ? nil : Self.currentBuild
        )
        try await credentialStore.save(credential)
        return credential
    }

    private func ensureStoreKitEnrollment(
        allowsRefresh: Bool,
        canRetryFreshChallenge: Bool = true
    ) async throws -> PrimuseAIRelayCredential {
        guard await storeKitEnrollmentProvider.isSupported else {
            throw PrimuseAIRelayError.unsupportedDevice
        }
        let material = try await storeKitEnrollmentProvider.enrollmentMaterial(
            allowsRefresh: allowsRefresh
        )
        let challenge = try await issueChallenge(purpose: "enroll")
        let body = try encoder.encode(StoreKitEnrollmentInput(
            appID: Self.appID,
            challenge: challenge,
            appTransactionJWS: material.appTransactionJWS,
            deviceVerificationID: material.deviceVerificationID
        ))
        let response: EnrollmentOutput
        do {
            response = try await send(
                EnrollmentOutput.self,
                request: try makeRequest(path: "/v1/auth/installations", body: body)
            )
        } catch {
            // 挑战过期就换新挑战重来一次;签名交易不用重新取,也不弹登录。
            guard canRetryFreshChallenge, Self.shouldRetryWithFreshProof(after: error) else { throw error }
            return try await ensureStoreKitEnrollment(allowsRefresh: false, canRetryFreshChallenge: false)
        }
        guard let accessToken = response.accessToken, !accessToken.isEmpty else {
            throw PrimuseAIRelayError.invalidResponse
        }
        let credential = PrimuseAIRelayCredential(
            keyID: "storekit",
            installationID: response.installationID,
            accessToken: accessToken,
            storeProofBuild: Self.currentBuild
        )
        try await credentialStore.save(credential)
        return credential
    }

    /// 这台设备现成的 App Store 签名交易:中转据此在任何系统上都能识别构建号和
    /// App Store/TestFlight(App Attest 要 iOS 27 起才带),并关联 Apple 账号。
    /// 不弹登录,取不到就照旧注册。
    private func optionalStoreProof() async -> PrimuseStoreKitEnrollmentMaterial? {
        guard await storeKitEnrollmentProvider.isSupported else { return nil }
        return try? await storeKitEnrollmentProvider.enrollmentMaterial(allowsRefresh: false)
    }

    /// 更新后给已有的安装补发一次这一版的 App Store 签名交易,让中转看到当前构建号和
    /// App Store/TestFlight。还没注册的不发(注册时会带上);不弹登录;失败一天后再试。
    func sendStoreProofIfNeeded(now: Date = Date()) async {
        guard let build = Self.currentBuild,
              await storeKitEnrollmentProvider.isSupported,
              let credential = try? await credentialStore.load(),
              let installationID = credential.installationID,
              credential.storeProofBuild != build else { return }
        if let attemptedAt = credential.storeProofAttemptedAt,
           now.timeIntervalSince(attemptedAt) < 24 * 60 * 60 {
            return
        }
        do {
            let material = try await storeKitEnrollmentProvider.enrollmentMaterial(allowsRefresh: false)
            let _: AccountLinkOutput = try await performFeature(
                path: "/v1/account/link",
                purpose: "account",
                input: AccountLinkInput(
                    appTransactionJWS: material.appTransactionJWS,
                    deviceVerificationID: material.deviceVerificationID
                )
            )
            await recordStoreProof(installationID: installationID, build: build, attemptedAt: nil)
        } catch {
            await recordStoreProof(installationID: installationID, build: nil, attemptedAt: now)
        }
    }

    /// 只改还是同一个安装的凭据;期间重新注册过就不动(新注册已带上签名交易)。
    private func recordStoreProof(installationID: String, build: String?, attemptedAt: Date?) async {
        guard var credential = try? await credentialStore.load(),
              credential.installationID == installationID else { return }
        if let build { credential.storeProofBuild = build }
        credential.storeProofAttemptedAt = attemptedAt
        try? await credentialStore.save(credential)
    }

    private func assertion(
        credential: PrimuseAIRelayCredential,
        clientDataHash: Data
    ) async throws -> (PrimuseAIRelayCredential, Data) {
        return (
            credential,
            try await attestor.generateAssertion(
                credential.keyID,
                clientDataHash: clientDataHash
            )
        )
    }

    private func issueChallenge(purpose: String) async throws -> String {
        let body = try encoder.encode(ChallengeInput(appID: Self.appID, purpose: purpose))
        let response = try await send(
            ChallengeOutput.self,
            request: try makeRequest(path: "/v1/auth/challenge", body: body)
        )
        guard !response.challenge.isEmpty else {
            throw PrimuseAIRelayError.invalidResponse
        }
        return response.challenge
    }

    private func makeRequest(path: String, body: Data) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == baseURL.host?.lowercased() else {
            throw PrimuseAIRelayError.invalidResponse
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestIdleTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let userAgent = Self.platformUserAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let preferredLanguages = Locale.preferredLanguages.prefix(10).joined(separator: ", ")
        if !preferredLanguages.isEmpty {
            request.setValue(preferredLanguages, forHTTPHeaderField: "Accept-Language")
        }
        return request
    }

    private func send<Response: Decodable & Sendable>(
        _ type: Response.Type,
        request: URLRequest
    ) async throws -> Response {
        let (data, rawResponse) = try await session.data(for: request)
        guard data.count <= Self.maximumResponseBytes else {
            throw PrimuseAIRelayError.responseTooLarge
        }
        guard let response = rawResponse as? HTTPURLResponse else {
            throw PrimuseAIRelayError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw PrimuseAIRelayError.requestFailed(
                statusCode: response.statusCode,
                code: Self.safeDiagnosticCode(
                    envelope?.error.code,
                    statusCode: response.statusCode
                ),
                retryAt: Self.retryDate(header: response.value(forHTTPHeaderField: "Retry-After"))
            )
        }
        guard let decoded = try? decoder.decode(type, from: data) else {
            throw PrimuseAIRelayError.invalidResponse
        }
        return decoded
    }

    private nonisolated static func isInvalidAppAttestKey(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == DCError.errorDomain
            && value.code == DCError.invalidKey.rawValue
    }

    private nonisolated static func isLocalAppAttestFailure(_ error: Error) -> Bool {
        (error as NSError).domain == DCError.errorDomain
    }

    private nonisolated static func isRecoverableAppAttestEnrollmentFailure(
        _ error: Error
    ) -> Bool {
        if isLocalAppAttestFailure(error) { return true }
        guard let relayError = error as? PrimuseAIRelayError,
              case .requestFailed(_, let code, _) = relayError else {
            return false
        }
        return code == "invalid_attestation" || code == "invalid_app_attest_policy"
    }

    private nonisolated static func shouldReplaceCredential(after error: Error) -> Bool {
        guard let relayError = error as? PrimuseAIRelayError,
              case .requestFailed(_, let code, _) = relayError else {
            return false
        }
        return [
            "installation_mismatch",
            "installation_unavailable",
            "invalid_assertion",
            "invalid_installation_token",
        ].contains(code)
    }

    private nonisolated static func shouldRetryWithFreshProof(after error: Error) -> Bool {
        guard let relayError = error as? PrimuseAIRelayError,
              case .requestFailed(_, let code, _) = relayError else {
            return false
        }
        return [
            "assertion_replayed",
            "expired_challenge",
            "invalid_challenge",
            "request_replayed",
        ].contains(code)
    }

    private nonisolated static func shouldRetryTransientStream(after error: Error) -> Bool {
        guard let relayError = error as? PrimuseAIRelayError,
              case .requestFailed(_, let code, let retryAt) = relayError else {
            return false
        }
        if let retryAt, retryAt.timeIntervalSinceNow > 2 { return false }
        return code == "concurrency_limited" || code == "upstreams_busy"
    }

    nonisolated static func retryDate(
        header: String? = nil,
        seconds: Double? = nil,
        now: Date = Date()
    ) -> Date? {
        let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let interval = seconds ?? raw.flatMap(Double.init), interval.isFinite, interval >= 0 {
            return now.addingTimeInterval(min(interval, 86_400))
        }
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return min(max(date, now), now.addingTimeInterval(86_400))
    }

    private nonisolated static func safeDiagnosticCode(
        _ rawCode: String?,
        statusCode: Int
    ) -> String {
        let fallback = "http_\(statusCode)"
        guard let rawCode else { return fallback }
        let normalized = rawCode.lowercased()
        guard !normalized.isEmpty,
              normalized.count <= 64,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 97 && scalar.value <= 122)
                      || (scalar.value >= 48 && scalar.value <= 57)
                      || scalar.value == 95
                      || scalar.value == 45
              }) else {
            return fallback
        }
        return normalized
    }

    private nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestIdleTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private struct ChallengeInput: Encodable, Sendable {
        var appID: String
        var purpose: String

        private enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case purpose
        }
    }

    private struct ChallengeOutput: Decodable, Sendable {
        var challenge: String
    }

    private struct EnrollmentInput: Encodable, Sendable {
        var appID: String
        var keyID: String
        var challenge: String
        var attestationObject: String
        /// 有现成的签名交易时才带;为 nil 时不编码。
        var appTransactionJWS: String?
        var deviceVerificationID: String?

        private enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case keyID = "key_id"
            case challenge
            case attestationObject = "attestation_object"
            case appTransactionJWS = "app_transaction_jws"
            case deviceVerificationID = "device_verification_id"
        }
    }

    private struct AccountLinkInput: Encodable, Sendable {
        var appTransactionJWS: String
        var deviceVerificationID: String

        private enum CodingKeys: String, CodingKey {
            case appTransactionJWS = "app_transaction_jws"
            case deviceVerificationID = "device_verification_id"
        }
    }

    /// 关联结果里的账号摘要用不到,只确认成功。
    private struct AccountLinkOutput: Decodable, Sendable {}

    private struct EnrollmentOutput: Decodable, Sendable {
        var installationID: String
        var accessToken: String?

        private enum CodingKeys: String, CodingKey {
            case installationID = "installation_id"
            case accessToken = "access_token"
        }
    }

    private struct StoreKitEnrollmentInput: Encodable, Sendable {
        var appID: String
        var challenge: String
        var appTransactionJWS: String
        var deviceVerificationID: String

        private enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case challenge
            case appTransactionJWS = "app_transaction_jws"
            case deviceVerificationID = "device_verification_id"
        }
    }

    private struct SuccessEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
        var data: Value
    }

    private struct ErrorEnvelope: Decodable, Sendable {
        struct Payload: Decodable, Sendable {
            var code: String
        }

        var error: Payload
    }

    private struct SemanticSearchInput: Encodable, Sendable {
        var query: String
        var languageCode: String?
        var maximumExpansionTerms: Int

        private enum CodingKeys: String, CodingKey {
            case query
            case languageCode = "language_code"
            case maximumExpansionTerms = "maximum_expansion_terms"
        }
    }

    private struct SemanticSearchOutput: Decodable, Sendable {
        var expansionTerms: [String]

        private enum CodingKeys: String, CodingKey {
            case expansionTerms = "expansion_terms"
        }
    }

    private struct SemanticSearchProgress: Decodable, Sendable {
        var term: String
    }

    private struct RecommendationsInput: Encodable, Sendable {
        var scene: String
        var intent: String?
        var languageCode: String?
        var preferences: [RecommendationPreference]
        var candidates: [RecommendationCandidate]
        var maximumResults: Int
        var minimumResults: Int
        /// Left out for songs, so a songs request is exactly what it was before
        /// albums existed. A service that predates albums ignores these fields
        /// and answers with songs only; the app then fills the album cards from
        /// its own picks.
        var unit: String?
        var albumCandidates: [RecommendationAlbumCandidate]?
        var maximumAlbumResults: Int?

        private enum CodingKeys: String, CodingKey {
            case scene
            case intent
            case languageCode = "language_code"
            case preferences
            case candidates
            case maximumResults = "maximum_results"
            case minimumResults = "minimum_results"
            case unit
            case albumCandidates = "album_candidates"
            case maximumAlbumResults = "maximum_album_results"
        }

        init(request: AIRecommendationRequest) {
            scene = request.scene.rawValue
            intent = request.intent
            languageCode = request.languageCode
            preferences = request.preferences.map {
                RecommendationPreference(
                    title: $0.title,
                    artist: $0.artist,
                    genre: $0.genre,
                    playCount: $0.playCount
                )
            }
            candidates = request.candidates.map {
                RecommendationCandidate(
                    songID: $0.songID,
                    title: $0.title,
                    artist: $0.artist,
                    genre: $0.genre,
                    year: $0.year,
                    durationSeconds: $0.durationSeconds
                )
            }
            maximumResults = request.maximumResults
            minimumResults = request.minimumResults
            if request.unit != .songs, !request.albumCandidates.isEmpty {
                unit = request.unit.rawValue
                albumCandidates = request.albumCandidates.map {
                    RecommendationAlbumCandidate(
                        albumID: $0.albumKey,
                        title: $0.title,
                        artist: $0.artist,
                        genre: $0.genre,
                        year: $0.year,
                        trackCount: $0.trackCount,
                        durationSeconds: $0.durationSeconds
                    )
                }
                maximumAlbumResults = request.maximumAlbumResults
            }
        }
    }

    private struct RecommendationAlbumCandidate: Encodable, Sendable {
        var albumID: String
        var title: String
        var artist: String
        var genre: String?
        var year: Int?
        var trackCount: Int
        var durationSeconds: Int

        private enum CodingKeys: String, CodingKey {
            case albumID = "album_id"
            case title
            case artist
            case genre
            case year
            case trackCount = "track_count"
            case durationSeconds = "duration_seconds"
        }
    }

    private struct RecommendationPreference: Encodable, Sendable {
        var title: String
        var artist: String
        var genre: String?
        var playCount: Int

        private enum CodingKeys: String, CodingKey {
            case title
            case artist
            case genre
            case playCount = "play_count"
        }
    }

    private struct RecommendationCandidate: Encodable, Sendable {
        var songID: String
        var title: String
        var artist: String
        var genre: String?
        var year: Int?
        var durationSeconds: Int

        private enum CodingKeys: String, CodingKey {
            case songID = "song_id"
            case title
            case artist
            case genre
            case year
            case durationSeconds = "duration_seconds"
        }
    }

    private struct RecommendationsOutput: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            var songID: String
            var reason: String

            private enum CodingKeys: String, CodingKey {
                case songID = "song_id"
                case reason
            }
        }

        struct AlbumItem: Decodable, Sendable {
            var albumID: String
            var reason: String

            private enum CodingKeys: String, CodingKey {
                case albumID = "album_id"
                case reason
            }
        }

        var items: [Item]
        /// Only from a service that knows albums, and only when asked for them.
        var albums: [AlbumItem]?
        var partial: Bool?

        func plan(for request: AIRecommendationRequest) -> AIRecommendationPlan {
            AIRecommendationPlan(
                selections: items.map {
                    AIRecommendationSelection(songID: $0.songID, reason: $0.reason)
                } + (albums ?? []).map {
                    AIRecommendationSelection(albumKey: $0.albumID, reason: $0.reason)
                },
                isPartial: partial == true
            ).normalized(for: request)
        }
    }

    private struct RecommendationProgress: Decodable, Sendable {
        var item: RecommendationsOutput.Item?
        var album: RecommendationsOutput.AlbumItem?

        var identity: String? {
            if let item { return item.songID }
            if let album { return "album:" + album.albumID }
            return nil
        }
    }

    private struct LyricsTranslationInput: Encodable, Sendable {
        var targetLanguageCode: String
        var lines: [LyricsLine]

        private enum CodingKeys: String, CodingKey {
            case targetLanguageCode = "target_language_code"
            case lines
        }
    }

    private struct LyricsLine: Encodable, Sendable {
        var id: String
        var text: String
        var sourceLanguageCode: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case text
            case sourceLanguageCode = "source_language_code"
        }
    }

    private struct LyricsTranslationOutput: Decodable, Sendable {
        struct Line: Decodable, Sendable {
            var id: String
            var translatedText: String

            private enum CodingKeys: String, CodingKey {
                case id
                case translatedText = "translated_text"
            }
        }

        var lines: [Line]
    }

    private struct LyricsTranslationProgress: Decodable, Sendable {
        var line: LyricsTranslationOutput.Line
    }

    private struct TagCleanupInput: Encodable, Sendable {
        var languageCode: String
        var songs: [TagCleanupAIExchange.Row]

        private enum CodingKeys: String, CodingKey {
            case languageCode = "language_code"
            case songs
        }
    }

    private struct TagCleanupOutput: Decodable, Sendable {
        struct Change: Decodable, Sendable {
            var id: String
            var field: String
            var value: String?
            var reason: String?
        }

        var changes: [Change]
    }

    private struct TagCleanupProgress: Decodable, Sendable {
        var change: TagCleanupOutput.Change
    }

    private struct SongDiscoveryOutput: Decodable, Sendable {
        struct Song: Decodable, Sendable {
            var title: String?
            var artist: String?
            var album: String?
            var year: Int?
            var reason: String?
        }

        var songs: [Song]
    }

    /// Progress lines are optional for this feature and never used; every
    /// field is optional so an extra or reshaped line cannot fail the stream.
    private struct ListeningIntentsOutput: Decodable, Sendable {
        struct Intent: Decodable, Sendable {
            var kind: String?
            var title: String?
            var refs: [String]?
            var genres: [String]?
            var decade: Int?
            var quality: String?
        }

        var intents: [Intent]
    }

    /// Progress lines are never used; every field is optional so an extra or
    /// reshaped line cannot fail the stream.
    private struct ListeningIntentsProgress: Decodable, Sendable {
        var intent: ListeningIntentsOutput.Intent?
    }

    private struct SongDiscoveryProgress: Decodable, Sendable {
        var song: SongDiscoveryOutput.Song?
    }

    private struct LibraryInsightOutput: Decodable, Sendable {
        var known: Bool
        var summary: String?
        var tags: [String]?
    }

    /// The relay sends no progress lines for intros; any that appear are ignored.
    private struct LibraryInsightProgress: Decodable, Sendable {}

    private struct ListeningMoodOutput: Decodable, Sendable {
        var title: String?
        var summary: String?
        var keywords: [String]?
    }

    /// The relay sends no progress lines for mood readings; any that appear are ignored.
    private struct ListeningMoodProgress: Decodable, Sendable {}

    private struct AudioTranscriptionInput: Encodable, Sendable {
        var audioBase64: String
        var mimeType: String
        var languageCodes: [String]?

        private enum CodingKeys: String, CodingKey {
            case audioBase64 = "audio_base64"
            case mimeType = "mime_type"
            case languageCodes = "language_codes"
        }
    }

    private struct AudioTranscriptionOutput: Decodable, Sendable {
        struct Word: Decodable, Sendable {
            var text: String
            var start: TimeInterval
            var end: TimeInterval
        }

        var transcript: String?
        var words: [Word]?
    }

    /// A transcription arrives whole; the stream only carries keep-alive blank lines.
    private struct AudioTranscriptionProgress: Decodable, Sendable {}

    /// 只借用量接口看套餐,流水取一条就够。
    private struct UsageQueryInput: Encodable, Sendable {
        var limit: Int
    }

    private struct UsagePlanOutput: Decodable, Sendable {
        struct Plan: Decodable, Sendable {
            /// 当前套餐能用的功能和每天的次数。
            var features: [String: Int]?
        }

        var plan: Plan?
    }

    /// 用量接口里今天和这个周期的计数;上限为 null 表示套餐没设。
    private struct UsageAllowanceOutput: Decodable, Sendable {
        struct FeatureCount: Decodable, Sendable {
            var requests: Int?
            var limit: Int?
        }

        struct Counts: Decodable, Sendable {
            var requests: Int?
            var requestLimit: Int?
            /// token 数;按小数解,免得哪天带了小数整份读不出。
            var credits: Double?
            var creditLimit: Double?
            var features: [String: FeatureCount]?

            private enum CodingKeys: String, CodingKey {
                case requests
                case requestLimit = "request_limit"
                case credits
                case creditLimit = "credit_limit"
                case features
            }
        }

        var today: Counts?
        var period: Counts?
    }

    private struct ServiceInfoOutput: Decodable, Sendable {
        var audioTranscription: String?

        private enum CodingKeys: String, CodingKey {
            case audioTranscription = "audio_transcription"
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
