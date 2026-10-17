import CoreFoundation
import Foundation
import Observation
import PrimuseKit
import Security

// MARK: - 本机引擎

/// 本机生成罗马音：离线、即时。日文、中文用系统分词器按词取读音（日文不能整句 `.toLatin`，
/// 汉字会被当成中文转成拼音）；韩文、印地文、俄文、乌克兰文用 Kit 里按各自通行写法写的转写器；
/// 其他文字用系统的拉丁转写。
enum LocalLyricsRomanizer {
    static let engineID = "local"
    /// 本机算法改了就加一，旧缓存自然失效。
    static let engineVersion = "1"

    /// 返回原文 → 罗马音；转不出来或和原文一样的行不在里面。
    nonisolated static func romanize(_ texts: [String], languageCode: String) -> [String: String] {
        var result: [String: String] = [:]
        for text in texts where result[text] == nil {
            guard let romanized = romanize(text, languageCode: languageCode) else { continue }
            result[text] = romanized
        }
        return result
    }

    nonisolated static func romanize(_ text: String, languageCode: String) -> String? {
        let base = languageCode.split(separator: "-").first.map { $0.lowercased() } ?? languageCode
        let output: String
        switch base {
        case "ja":
            output = JapaneseRomajiAssembler.assemble(japanesePieces(text))
        case "zh":
            output = PinyinWordAssembler.assemble(chinesePieces(text, localeIdentifier: chineseLocale(languageCode)))
        case "ko":
            output = KoreanRevisedRomanization.romanize(text)
        case "hi", "mr", "ne":
            output = HindiLyricTransliteration.romanize(text)
        case "ru":
            output = CyrillicLyricTransliteration.romanizeRussian(text)
        case "uk":
            output = CyrillicLyricTransliteration.romanizeUkrainian(text)
        default:
            output = text.applyingTransform(.toLatin, reverse: false) ?? text
        }
        // 个别词读不出来时照原文留在那一处，整行仍然给出（总比整行没有罗马音好）。
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return trimmed
    }

    /// 字形里有繁体字（繁转简会改动它）就按繁体分词，否则按简体。
    nonisolated static func chineseScriptCode(for texts: [String]) -> String {
        let sample = texts.prefix(80).joined(separator: "\n")
        let simplified = sample.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? sample
        return simplified == sample ? "zh-Hans" : "zh-Hant"
    }

    private nonisolated static func chineseLocale(_ languageCode: String) -> String {
        languageCode.lowercased().contains("hant") ? "zh-Hant" : "zh-Hans"
    }

    private nonisolated static func japanesePieces(_ text: String) -> [JapaneseRomajiAssembler.Piece] {
        tokens(text, localeIdentifier: "ja").map { token in
            switch token {
            case .gap(let gap):
                return .gap(gap)
            case .word(let surface, let reading):
                // 分词器没给读音的纯假名词，假名本身可以直接转写。
                let fallback = reading == nil && isKanaOnly(surface)
                    ? surface.applyingTransform(.toLatin, reverse: false)
                    : nil
                return .word(surface: surface, reading: reading ?? fallback)
            }
        }
    }

    private nonisolated static func chinesePieces(_ text: String, localeIdentifier: String) -> [PinyinWordAssembler.Piece] {
        tokens(text, localeIdentifier: localeIdentifier).map { token in
            switch token {
            case .gap(let gap):
                return .gap(gap)
            case .word(let surface, let reading):
                let fallback = reading == nil && LyricRomanizationScriptPolicy.needsRomanization(surface)
                    ? surface.applyingTransform(.mandarinToLatin, reverse: false)
                    : nil
                return .word(surface: surface, reading: reading ?? fallback)
            }
        }
    }

    private enum Token {
        case word(surface: String, reading: String?)
        case gap(String)
    }

    /// 系统分词器按词切开，每个词取拉丁转写；已经是拉丁字母、数字的词保持原样（不取读音，免得改了大小写）。
    private nonisolated static func tokens(_ text: String, localeIdentifier: String) -> [Token] {
        let string = text as NSString
        let length = string.length
        guard length > 0,
              let tokenizer = CFStringTokenizerCreate(
                kCFAllocatorDefault,
                text as CFString,
                CFRange(location: 0, length: length),
                kCFStringTokenizerUnitWord,
                Locale(identifier: localeIdentifier) as CFLocale
              ) else { return [.gap(text)] }
        var tokens: [Token] = []
        var cursor = 0
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.location != kCFNotFound, range.length > 0, range.location >= cursor else { continue }
            if range.location > cursor {
                tokens.append(.gap(string.substring(with: NSRange(location: cursor, length: range.location - cursor))))
            }
            let surface = string.substring(with: NSRange(location: range.location, length: range.length))
            var reading: String?
            if LyricRomanizationScriptPolicy.needsRomanization(surface) {
                reading = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer,
                    kCFStringTokenizerAttributeLatinTranscription
                ) as? String
            }
            tokens.append(.word(surface: surface, reading: reading))
            cursor = range.location + range.length
        }
        if cursor < length {
            tokens.append(.gap(string.substring(from: cursor)))
        }
        return tokens
    }

    private nonisolated static func isKanaOnly(_ text: String) -> Bool {
        let counts = LyricRomanizationScriptPolicy.counts(in: text)
        return counts.kana > 0 && counts.han == 0 && counts.hangul == 0 && counts.others.isEmpty
    }
}

// MARK: - 结果缓存

/// 生成结果的缓存：内存里留最近几十首，磁盘放在 Caches/Primuse/lyrics-romanization/ 下，
/// 总量超过上限时删最久没用的。键里有歌词指纹，歌词变了自然失效；从不写回任何歌词数据。
actor LyricsRomanizationCache {
    static let shared = LyricsRomanizationCache()

    private static let memoryLimit = 48
    private static let diskLimitBytes = 8 * 1024 * 1024
    private static let trimEveryWrites = 12

    private var memory: [String: [String: String]] = [:]
    private var recency: [String] = []
    private var writesSinceTrim = 0

    private struct Entry: Codable {
        let version: Int
        let lines: [String: String]
    }

    private static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("lyrics-romanization", isDirectory: true)
    }

    func value(for key: LyricRomanizationCacheKey) -> [String: String]? {
        let name = key.storageName
        if let hit = memory[name] {
            touch(name)
            return hit
        }
        guard let url = Self.directory?.appendingPathComponent(name + ".json"),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 1 else { return nil }
        remember(entry.lines, as: name)
        // 读到就刷新修改时间，裁剪时按它判断谁最久没用。
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return entry.lines
    }

    func store(_ lines: [String: String], for key: LyricRomanizationCacheKey) {
        guard !lines.isEmpty else { return }
        let name = key.storageName
        remember(lines, as: name)
        guard let directory = Self.directory,
              let data = try? JSONEncoder().encode(Entry(version: 1, lines: lines)) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        } catch {
            return
        }
        writesSinceTrim += 1
        if writesSinceTrim >= Self.trimEveryWrites {
            writesSinceTrim = 0
            trimDisk(directory)
        }
    }

    func removeAll() {
        memory.removeAll()
        recency.removeAll()
        if let directory = Self.directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func remember(_ lines: [String: String], as name: String) {
        memory[name] = lines
        touch(name)
        while recency.count > Self.memoryLimit, let oldest = recency.first {
            recency.removeFirst()
            memory[oldest] = nil
        }
    }

    private func touch(_ name: String) {
        recency.removeAll { $0 == name }
        recency.append(name)
    }

    private func trimDisk(_ directory: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > Self.diskLimitBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > Self.diskLimitBytes * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

// MARK: - Google Cloud

enum GoogleCloudRomanizationError: Error, Equatable, Sendable {
    case notConfigured
    case invalidKey
    case signingFailed
    case http(GoogleCloudErrorSummary)
    case network
    case invalidResponse
}

/// 服务账号密钥存在钥匙串里（和智能服务的 API 密钥同一套存法：开着凭据同步就进 iCloud 钥匙串）。
enum GoogleCloudRomanizationCredentialStore {
    static let account = "primuse.lyrics.romanization.googleServiceAccount"

    nonisolated static func load() -> GoogleServiceAccountKey? {
        guard let stored = KeychainService.getPassword(for: account) else { return nil }
        return try? GoogleServiceAccountKey.parse(Data(stored.utf8))
    }

    @discardableResult
    nonisolated static func save(_ key: GoogleServiceAccountKey) -> Bool {
        KeychainService.setPassword(String(decoding: key.storedJSON(), as: UTF8.self), for: account)
    }

    @discardableResult
    nonisolated static func delete() -> Bool {
        KeychainService.deletePassword(for: account)
    }
}

/// 调用 romanizeText：服务账号签 JWT 换访问令牌（缓存到过期前 5 分钟），再按批请求。
actor GoogleCloudRomanizationClient {
    static let shared = GoogleCloudRomanizationClient()

    static let engineID = "google"
    static let engineVersion = "v3"

    private var cachedToken: (clientEmail: String, token: GoogleAccessToken)?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    func clearToken() {
        cachedToken = nil
    }

    /// 与 `texts` 同序；整批失败时抛错，调用方保留本机结果。
    func romanize(_ texts: [String], languageCode: String) async throws -> [String] {
        guard let key = GoogleCloudRomanizationCredentialStore.load() else {
            throw GoogleCloudRomanizationError.notConfigured
        }
        guard let endpoint = GoogleCloudRomanizeText.endpoint(projectID: key.projectID) else {
            throw GoogleCloudRomanizationError.invalidKey
        }
        var output: [String] = []
        output.reserveCapacity(texts.count)
        for batch in GoogleCloudRomanizeText.batches(texts) {
            try Task.checkCancellation()
            let contents = Array(texts[batch])
            output += try await romanizeBatch(contents, languageCode: languageCode, key: key, endpoint: endpoint)
        }
        return output
    }

    private func romanizeBatch(
        _ contents: [String],
        languageCode: String,
        key: GoogleServiceAccountKey,
        endpoint: URL,
        retryingAuthorization: Bool = true
    ) async throws -> [String] {
        let token = try await accessToken(for: key)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(key.projectID, forHTTPHeaderField: "x-goog-user-project")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleCloudRomanizeText.requestBody(sourceLanguageCode: languageCode, contents: contents)
        let (data, response) = try await send(request)
        if response.statusCode == 401, retryingAuthorization {
            cachedToken = nil
            return try await romanizeBatch(
                contents,
                languageCode: languageCode,
                key: key,
                endpoint: endpoint,
                retryingAuthorization: false
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            let summary = GoogleCloudErrorSummary.parse(statusCode: response.statusCode, body: data)
            plog("🔤 Google romanizeText failed status=\(response.statusCode) kind=\(summary.kind.rawValue)")
            throw GoogleCloudRomanizationError.http(summary)
        }
        do {
            return try GoogleCloudRomanizeText.decodeResponse(data, expectedCount: contents.count)
        } catch {
            throw GoogleCloudRomanizationError.invalidResponse
        }
    }

    private func accessToken(for key: GoogleServiceAccountKey) async throws -> String {
        let now = Date()
        if let cachedToken, cachedToken.clientEmail == key.clientEmail, cachedToken.token.isUsable(at: now) {
            return cachedToken.token.value
        }
        guard let tokenURL = URL(string: key.tokenURI) else { throw GoogleCloudRomanizationError.invalidKey }
        let signingInput = GoogleServiceAccountJWT.signingInput(for: key, issuedAt: now)
        let signature = try Self.sign(signingInput, privateKeyPEM: key.privateKeyPEM)
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleServiceAccountJWT.tokenRequestBody(
            assertion: GoogleServiceAccountJWT.assertion(signingInput: signingInput, signature: signature)
        )
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            let summary = GoogleCloudErrorSummary.parse(statusCode: response.statusCode, body: data)
            plog("🔤 Google token request failed status=\(response.statusCode) kind=\(summary.kind.rawValue)")
            throw GoogleCloudRomanizationError.http(summary)
        }
        let token: GoogleAccessToken
        do {
            token = try GoogleAccessToken.decode(data, receivedAt: Date())
        } catch {
            throw GoogleCloudRomanizationError.invalidResponse
        }
        cachedToken = (key.clientEmail, token)
        return token.value
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GoogleCloudRomanizationError.network
        }
        guard let http = result.1 as? HTTPURLResponse else { throw GoogleCloudRomanizationError.invalidResponse }
        return (result.0, http)
    }

    /// RS256：PKCS#8 解成 PKCS#1 交给 Security 框架签名。
    nonisolated static func sign(_ signingInput: String, privateKeyPEM: String) throws -> Data {
        let der: Data
        do {
            der = try RSAPrivateKeyDERUnwrapper.pkcs1DER(fromPEM: privateKeyPEM)
        } catch {
            throw GoogleCloudRomanizationError.invalidKey
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw GoogleCloudRomanizationError.invalidKey
        }
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error
        ) as Data? else {
            throw GoogleCloudRomanizationError.signingFailed
        }
        return signature
    }
}

/// 设置页看的 Google Cloud 状态：导入的是哪个服务账号、最近一次出错的原因。
@MainActor
@Observable
final class GoogleCloudRomanizationAccount {
    static let shared = GoogleCloudRomanizationAccount()

    struct Summary: Equatable {
        let clientEmail: String
        let projectID: String
    }

    struct TestSample: Identifiable, Equatable {
        let id: Int
        let original: String
        let romanized: String
    }

    enum TestOutcome: Equatable {
        case success([TestSample])
        case failure(String)
    }

    private(set) var summary: Summary?
    /// 导入、移除密钥时加一；生成任务据此重来。
    private(set) var revision: UInt = 0
    private(set) var lastError: String?
    private(set) var lastErrorDate: Date?

    private init() {
        reload()
    }

    func reload() {
        let key = GoogleCloudRomanizationCredentialStore.load()
        let next = key.map { Summary(clientEmail: $0.clientEmail, projectID: $0.projectID) }
        if next != summary {
            summary = next
            revision &+= 1
        }
    }

    enum ImportError: Error {
        case invalid(GoogleServiceAccountKey.ParseError)
        case saveFailed
    }

    func importKey(_ data: Data) throws {
        let key: GoogleServiceAccountKey
        do {
            key = try GoogleServiceAccountKey.parse(data)
        } catch let error as GoogleServiceAccountKey.ParseError {
            throw ImportError.invalid(error)
        }
        guard GoogleCloudRomanizationCredentialStore.save(key) else { throw ImportError.saveFailed }
        lastError = nil
        lastErrorDate = nil
        Task { await GoogleCloudRomanizationClient.shared.clearToken() }
        reload()
        revision &+= 1
    }

    func remove() {
        GoogleCloudRomanizationCredentialStore.delete()
        lastError = nil
        lastErrorDate = nil
        Task { await GoogleCloudRomanizationClient.shared.clearToken() }
        reload()
    }

    func recordFailure(_ error: Error) {
        lastError = Self.message(for: error)
        lastErrorDate = Date()
    }

    func recordSuccess() {
        lastError = nil
        lastErrorDate = nil
    }

    /// 「用当前歌曲测试」：从当前歌曲里挑最多 5 行 Google 支持的歌词发出去；这首歌没有
    /// 合适的行时用一句日文示例。
    func test(lines: [LyricLine]) async -> TestOutcome {
        let plan = LyricRomanizationPlanner.plan(
            lines: lines,
            generates: true,
            enabledLanguages: Set(LyricRomanizationLanguage.allCases)
        )
        let group = plan.groups.first { GoogleCloudRomanizeText.supports(languageCode: $0.languageCode) }
        let languageCode = group?.languageCode ?? "ja"
        let texts = group.map { Array($0.uniqueTexts.prefix(5)) } ?? [Self.testSample]
        do {
            let romanized = try await GoogleCloudRomanizationClient.shared.romanize(texts, languageCode: languageCode)
            recordSuccess()
            return .success(zip(texts, romanized).enumerated().map {
                TestSample(id: $0.offset, original: $0.element.0, romanized: $0.element.1)
            })
        } catch is CancellationError {
            return .failure(String(localized: "lyrics_romanization_google_error_network"))
        } catch {
            recordFailure(error)
            return .failure(Self.message(for: error))
        }
    }

    /// 当前歌曲没有能测的行时发这句日文（只用平假名写，免得混进汉字的读音问题）。
    private static let testSample = "きょうも いっしょに うたおう"

    static func message(for error: Error) -> String {
        guard let error = error as? GoogleCloudRomanizationError else {
            return String(localized: "lyrics_romanization_google_error_network")
        }
        switch error {
        case .notConfigured:
            return String(localized: "lyrics_romanization_google_error_not_configured")
        case .invalidKey, .signingFailed:
            return String(localized: "lyrics_romanization_google_error_key")
        case .network:
            return String(localized: "lyrics_romanization_google_error_network")
        case .invalidResponse:
            return String(localized: "lyrics_romanization_google_error_response")
        case .http(let summary):
            let reason: String = switch summary.kind {
            case .unauthorized:
                String(localized: "lyrics_romanization_google_error_unauthorized")
            case .permissionDenied:
                String(localized: "lyrics_romanization_google_error_permission")
            case .quotaExceeded:
                String(localized: "lyrics_romanization_google_error_quota")
            case .serverError:
                String(localized: "lyrics_romanization_google_error_server")
            case .invalidRequest, .other:
                String(format: String(localized: "lyrics_romanization_google_error_status_format"), summary.statusCode)
            }
            guard let message = summary.message else { return reason }
            return reason + "\n" + message
        }
    }

    static func message(for error: ImportError) -> String {
        switch error {
        case .saveFailed:
            return String(localized: "lyrics_romanization_google_import_save_failed")
        case .invalid(.notJSON), .invalid(.notServiceAccount):
            return String(localized: "lyrics_romanization_google_import_not_service_account")
        case .invalid(.invalidPrivateKey):
            return String(localized: "lyrics_romanization_google_error_key")
        case .invalid(.invalidTokenURI), .invalid(.invalidProjectID), .invalid(.missingField):
            return String(localized: "lyrics_romanization_google_import_incomplete")
        }
    }
}

// MARK: - 生成

/// 把一首歌词变成罗马音覆盖层：先按语言分组，每组先用缓存或本机结果立刻显示，选了远程方式
/// 再去请求，回来后整组替换。远程失败、没就绪、不支持这种语言时留着本机结果，不留空。
@MainActor
final class LyricsRomanizationService {
    static let shared = LyricsRomanizationService()

    struct Request: Hashable, Sendable {
        var lines: [LyricLine]
        var generates: Bool
        var enabledLanguages: Set<LyricRomanizationLanguage>
        /// 已经按地区换算过的方式（`LyricRomanizationMethodPolicy.effectiveMethod`）。
        var method: LyricRomanizationMethod
        var songContext: LyricTranslationSongContext
    }

    private enum RemoteEngine {
        case google
        case intelligent(engineID: String)

        var cacheIdentity: (id: String, version: String) {
            switch self {
            case .google: (GoogleCloudRomanizationClient.engineID, GoogleCloudRomanizationClient.engineVersion)
            case .intelligent(let engineID): (engineID, "1")
            }
        }
    }

    private init() {}

    /// 返回最终结果；中途每有一组结果就交给 `onUpdate`。被取消时返回 nil。
    func overlay(
        for request: Request,
        intelligence: MusicIntelligenceService?,
        onUpdate: (LyricRomanizationOverlay) -> Void
    ) async -> LyricRomanizationOverlay? {
        let lines = request.lines
        let generates = request.generates
        let languages = request.enabledLanguages
        let songContext = request.songContext
        let plan = await Task.detached(priority: .utility) {
            LyricRomanizationPlanner.plan(
                lines: lines,
                generates: generates,
                enabledLanguages: languages,
                songContext: songContext
            )
        }.value
        guard !Task.isCancelled else { return nil }

        var overlay = LyricRomanizationOverlay(readingTranslationIDs: plan.readingTranslationIDs)
        let cache = LyricsRomanizationCache.shared
        for group in plan.groups {
            let texts = group.uniqueTexts
            var languageCode = group.languageCode
            if group.language == .chinese, languageCode == "zh" {
                languageCode = await Task.detached(priority: .utility) {
                    LocalLyricsRomanizer.chineseScriptCode(for: texts)
                }.value
            }
            let remote = remoteEngine(for: request.method, languageCode: languageCode, intelligence: intelligence)
            if let remote {
                let identity = remote.cacheIdentity
                let key = LyricRomanizationCacheKey(
                    engineID: identity.id,
                    engineVersion: identity.version,
                    languageCode: languageCode,
                    texts: texts
                )
                if let cached = await cache.value(for: key) {
                    guard !Task.isCancelled else { return nil }
                    Self.apply(cached, of: group, to: &overlay)
                    onUpdate(overlay)
                    continue
                }
            }

            let localKey = LyricRomanizationCacheKey(
                engineID: LocalLyricsRomanizer.engineID,
                engineVersion: LocalLyricsRomanizer.engineVersion,
                languageCode: languageCode,
                texts: texts
            )
            var local = await cache.value(for: localKey)
            if local == nil {
                let code = languageCode
                let computed = await Task.detached(priority: .userInitiated) {
                    LocalLyricsRomanizer.romanize(texts, languageCode: code)
                }.value
                await cache.store(computed, for: localKey)
                local = computed
            }
            guard !Task.isCancelled else { return nil }
            Self.apply(local ?? [:], of: group, to: &overlay)
            onUpdate(overlay)

            guard let remote else { continue }
            let remoteResult = await requestRemote(
                remote,
                texts: texts,
                languageCode: languageCode,
                intelligence: intelligence
            )
            guard !Task.isCancelled else { return nil }
            guard let remoteResult, !remoteResult.isEmpty else { continue }
            if remoteResult.count == texts.count {
                let identity = remote.cacheIdentity
                await cache.store(remoteResult, for: LyricRomanizationCacheKey(
                    engineID: identity.id,
                    engineVersion: identity.version,
                    languageCode: languageCode,
                    texts: texts
                ))
            }
            Self.apply(remoteResult, of: group, to: &overlay)
            onUpdate(overlay)
        }
        return overlay
    }

    private func remoteEngine(
        for method: LyricRomanizationMethod,
        languageCode: String,
        intelligence: MusicIntelligenceService?
    ) -> RemoteEngine? {
        switch method {
        case .local:
            return nil
        case .googleCloud:
            guard GoogleCloudRomanizeText.supports(languageCode: languageCode),
                  GoogleCloudRomanizationAccount.shared.summary != nil else { return nil }
            return .google
        case .intelligent:
            guard let intelligence,
                  intelligence.lyricsAIRomanizationReadiness == .ready,
                  let engineID = intelligence.lyricsRomanizationEngineID else { return nil }
            return .intelligent(engineID: engineID)
        }
    }

    /// 原文 → 罗马音；失败返回 nil（调用方保留本机结果）。
    private func requestRemote(
        _ engine: RemoteEngine,
        texts: [String],
        languageCode: String,
        intelligence: MusicIntelligenceService?
    ) async -> [String: String]? {
        switch engine {
        case .google:
            do {
                let romanized = try await GoogleCloudRomanizationClient.shared.romanize(texts, languageCode: languageCode)
                GoogleCloudRomanizationAccount.shared.recordSuccess()
                var result: [String: String] = [:]
                for (text, value) in zip(texts, romanized) where !value.isEmpty && value != text {
                    result[text] = value
                }
                return result
            } catch is CancellationError {
                return nil
            } catch {
                GoogleCloudRomanizationAccount.shared.recordFailure(error)
                return nil
            }
        case .intelligent:
            return await intelligence?.romanizeLyrics(texts, languageCode: languageCode)?.romanizedByText
        }
    }

    private static func apply(
        _ romanized: [String: String],
        of group: LyricRomanizationGroup,
        to overlay: inout LyricRomanizationOverlay
    ) {
        for candidate in group.candidates {
            guard let value = romanized[candidate.text]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value != candidate.text else { continue }
            overlay.generatedTextByLineID[candidate.lineID] = value
        }
    }
}
