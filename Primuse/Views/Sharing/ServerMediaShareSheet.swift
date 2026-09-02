import PrimuseKit
import SwiftUI

struct ServerMediaShareSheet: View {
    private enum CapabilityState {
        case checking
        case available(ServerMediaSharingFeatures)
        case unsupported
        case permissionDenied
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore

    let target: ServerMediaShareTarget
    let relaySong: Song?
    private let minimumExpirationDate: Date

    @State private var capabilityState: CapabilityState = .checking
    @State private var descriptionText = ""
    @State private var includesExpiration = true
    @State private var expirationDate: Date
    @State private var createdShare: ServerMediaShare?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var probeTask: Task<Void, Never>?
    @State private var creationTask: Task<Void, Never>?
    @State private var showsRelayShare = false

    init(target: ServerMediaShareTarget, relaySong: Song? = nil) {
        let now = Date()
        self.target = target
        self.relaySong = relaySong
        self.minimumExpirationDate = now
        _expirationDate = State(initialValue: Calendar.current.date(
            byAdding: .day,
            value: 7,
            to: now
        ) ?? now.addingTimeInterval(7 * 24 * 60 * 60))
    }

    var body: some View {
        NavigationStack {
            Form {
                targetSection
                capabilityContent
                relayFallbackSection
                publicReachabilitySection
            }
            .navigationTitle("server_share_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
                        .disabled(isCreating)
                }
            }
        }
        .task(id: target.id) {
            await probeCapability()
        }
        .onDisappear {
            probeTask?.cancel()
            probeTask = nil
            creationTask?.cancel()
            creationTask = nil
        }
        .interactiveDismissDisabled(isCreating)
        .sheet(isPresented: $showsRelayShare) {
            if let relaySong {
                MediaRelayShareSheet(song: relaySong)
            }
        }
        .alert(
            "server_share_error_title",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("done", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var targetSection: some View {
        Section("server_share_target_section") {
            LabeledContent("server_share_target_type") {
                Text(targetKindLabel)
            }
            if !target.title.isEmpty {
                LabeledContent("server_share_target_name") {
                    Text(verbatim: target.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let sourceName = sourcesStore.source(id: target.sourceID)?.name {
                LabeledContent("server_share_source") {
                    Text(verbatim: sourceName)
                }
            }
            LabeledContent("server_share_items") {
                Text(target.itemIDs.count, format: .number)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var capabilityContent: some View {
        switch capabilityState {
        case .checking:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("server_share_checking")
                }
                .accessibilityElement(children: .combine)
            }
        case .available(let features):
            if let createdShare {
                createdShareSection(createdShare)
            } else {
                optionsSection(features)
                createSection
            }
        case .unsupported:
            unavailableSection(
                titleKey: "server_share_unsupported_title",
                messageKey: "server_share_unsupported_message",
                systemImage: "link.badge.slash"
            )
        case .permissionDenied:
            unavailableSection(
                titleKey: "server_share_permission_title",
                messageKey: "server_share_permission_message",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        case .failed(let message):
            Section {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button("retry") {
                    capabilityState = .checking
                    probeTask?.cancel()
                    probeTask = Task { await probeCapability() }
                }
            }
        }
    }

    private func optionsSection(_ features: ServerMediaSharingFeatures) -> some View {
        Section("server_share_options") {
            if features.supportsDescription {
                TextField(
                    "server_share_description_placeholder",
                    text: $descriptionText,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .accessibilityLabel(Text("server_share_description"))
            }

            if features.supportsExpiration {
                Toggle("server_share_expiration_enabled", isOn: $includesExpiration)
                if includesExpiration {
                    DatePicker(
                        "server_share_expiration",
                        selection: $expirationDate,
                        in: minimumExpirationDate...Date.distantFuture
                    )
                }
            }

            if !features.supportsPasswordProtection {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("server_share_password_unsupported_title")
                        Text("server_share_password_unsupported_message")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.slash")
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var createSection: some View {
        Section {
            Button {
                creationTask?.cancel()
                creationTask = Task { await createShare() }
            } label: {
                HStack {
                    Spacer()
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                        Text("server_share_creating")
                    } else {
                        Label("server_share_create", systemImage: "link.badge.plus")
                    }
                    Spacer()
                }
            }
            .disabled(isCreating)
        }
    }

    @ViewBuilder
    private var relayFallbackSection: some View {
        if let relaySong,
           let source = sourcesStore.source(id: relaySong.sourceID),
           MediaRelaySourcePolicy.supports(song: relaySong, sourceType: source.type),
           createdShare == nil {
            Section {
                Button {
                    showsRelayShare = true
                } label: {
                    Label("relay_share_action", systemImage: "externaldrive.badge.icloud")
                }
                .accessibilityHint(Text("relay_share_action_hint"))
            } header: {
                Text("relay_share_fallback_section")
            } footer: {
                Text("relay_share_fallback_footer")
            }
        }
    }

    private func createdShareSection(_ share: ServerMediaShare) -> some View {
        Section {
            Label("server_share_created_message", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Text(verbatim: share.publicURLString)
                .font(.callout)
                .textSelection(.enabled)
                .accessibilityLabel(Text("server_share_public_link"))

            Link(destination: share.publicURL) {
                Label("server_share_open_link", systemImage: "arrow.up.right.square")
            }

            ShareLink(
                item: share.publicURLString,
                subject: Text(verbatim: target.title)
            ) {
                Label("server_share_system_share", systemImage: "square.and.arrow.up")
            }
            .accessibilityHint(Text("server_share_system_share_hint"))
        } header: {
            Text("server_share_created")
        } footer: {
            Text("server_share_verbatim_url_footer")
        }
    }

    private var publicReachabilitySection: some View {
        Section("server_share_public_reachability_title") {
            Label {
                Text("server_share_public_reachability_message")
                    .font(.footnote)
            } icon: {
                Image(systemName: "network")
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func unavailableSection(
        titleKey: LocalizedStringKey,
        messageKey: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 5) {
                    Text(titleKey)
                        .font(.headline)
                    Text(messageKey)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var targetKindLabel: LocalizedStringKey {
        switch target.kind {
        case .song: "server_share_kind_song"
        case .album: "server_share_kind_album"
        case .artist: "server_share_kind_artist"
        case .playlist: "server_share_kind_playlist"
        case .selection: "server_share_kind_selection"
        }
    }

    @MainActor
    private func probeCapability() async {
        do {
            let availability = try await sourceManager.serverMediaSharingAvailability(
                for: target
            )
            try Task.checkCancellation()
            switch availability {
            case .available(let features):
                capabilityState = .available(features)
            case .unsupported:
                capabilityState = .unsupported
            case .permissionDenied:
                capabilityState = .permissionDenied
            }
        } catch is CancellationError {
            return
        } catch {
            capabilityState = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func createShare() async {
        guard !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            if includesExpiration, expirationDate <= Date() {
                throw ServerMediaSharingError.invalidExpiration
            }
            let share = try await sourceManager.createServerMediaShare(
                for: target,
                description: descriptionText,
                expiresAt: includesExpiration ? expirationDate : nil
            )
            guard !Task.isCancelled else { return }
            createdShare = share
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum MediaRelayShareError: LocalizedError {
    case unsupportedSong
    case invalidConfiguration
    case credentialStorageFailed
    case invalidResponse
    case serverRejected(Int)
    case shortSourceRead

    var errorDescription: String? {
        switch self {
        case .unsupportedSong:
            String(localized: "relay_share_error_unsupported")
        case .invalidConfiguration:
            String(localized: "relay_share_error_configuration")
        case .credentialStorageFailed:
            String(localized: "relay_share_error_keychain")
        case .invalidResponse:
            String(localized: "relay_share_error_response")
        case .serverRejected(let statusCode):
            String(
                format: String(localized: "relay_share_error_server_format"),
                statusCode
            )
        case .shortSourceRead:
            String(localized: "relay_share_error_source_read")
        }
    }
}

private enum MediaRelayConfigurationPolicy {
    static func validatedAPIBaseURL(_ rawValue: String) throws -> URL {
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              !rawValue.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else {
            throw MediaRelayShareError.invalidConfiguration
        }
        return url
    }

    static func isOpaqueIdentifier(_ value: String) -> Bool {
        (16...128).contains(value.count) && value.unicodeScalars.allSatisfy {
            let codePoint = $0.value
            return (48...57).contains(codePoint)
                || (65...90).contains(codePoint)
                || (97...122).contains(codePoint)
                || codePoint == 45
                || codePoint == 95
        }
    }
}

private struct MediaRelayCreateRequest: Encodable {
    let fileName: String
    let contentType: String
    let size: Int64
    let expiresAt: String
    let password: String?
}

private struct MediaRelayCreateResponse: Decodable, Sendable {
    let shareID: String
    let uploadToken: String
    let publicURL: String
    let chunkSize: Int64
    let expiresAt: String
}

private struct MediaRelayCompleteResponse: Decodable {
    let shareID: String
    let expiresAt: String
}

private final class MediaRelayNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct MediaRelayClient: @unchecked Sendable {
    private static let responseByteLimit = 64 * 1024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        return URLSession(
            configuration: configuration,
            delegate: MediaRelayNoRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    let baseURL: URL
    let adminToken: String

    func createUpload(
        fileName: String,
        contentType: String,
        size: Int64,
        expiresAt: Date,
        password: String?
    ) async throws -> MediaRelayCreateResponse {
        let body = try JSONEncoder().encode(MediaRelayCreateRequest(
            fileName: fileName,
            contentType: contentType,
            size: size,
            expiresAt: Self.dateString(expiresAt),
            password: password?.isEmpty == false ? password : nil
        ))
        let data = try await perform(
            method: "POST",
            pathComponents: ["v1", "uploads"],
            bearerToken: adminToken,
            contentType: "application/json",
            body: body,
            expectedStatus: 201
        )
        let response = try JSONDecoder().decode(MediaRelayCreateResponse.self, from: data)
        do {
            guard MediaRelayConfigurationPolicy.isOpaqueIdentifier(response.shareID),
                  MediaRelayConfigurationPolicy.isOpaqueIdentifier(response.uploadToken),
                  (256 * 1024...32 * 1024 * 1024).contains(response.chunkSize),
                  let publicURL = URL(string: response.publicURL),
                  publicURL.scheme?.lowercased() == "https",
                  publicURL.query == nil,
                  publicURL.fragment == nil,
                  !publicURL.path.hasSuffix("/") else {
                throw MediaRelayShareError.invalidResponse
            }
            let publicPath = publicURL.path.split(separator: "/")
            guard publicPath.count >= 2,
                  publicPath[publicPath.count - 2] == "s",
                  MediaRelayConfigurationPolicy.isOpaqueIdentifier(
                      String(publicPath[publicPath.count - 1])
                  ) else {
                throw MediaRelayShareError.invalidResponse
            }
            try ServerMediaShare.validatePublicURL(response.publicURL)
            guard ISO8601DateFormatter().date(from: response.expiresAt) != nil else {
                throw MediaRelayShareError.invalidResponse
            }
            return response
        } catch {
            if MediaRelayConfigurationPolicy.isOpaqueIdentifier(response.shareID),
               MediaRelayConfigurationPolicy.isOpaqueIdentifier(response.uploadToken) {
                try? await revoke(
                    shareID: response.shareID,
                    controlToken: response.uploadToken
                )
            }
            throw error
        }
    }

    func uploadChunk(
        shareID: String,
        uploadToken: String,
        index: Int64,
        offset: Int64,
        totalSize: Int64,
        data: Data
    ) async throws {
        let end = offset + Int64(data.count) - 1
        _ = try await perform(
            method: "PUT",
            pathComponents: ["v1", "uploads", shareID, "chunks", String(index)],
            bearerToken: uploadToken,
            contentType: "application/octet-stream",
            body: data,
            additionalHeaders: [
                "Content-Range": "bytes \(offset)-\(end)/\(totalSize)",
            ],
            expectedStatus: 204
        )
    }

    func complete(shareID: String, uploadToken: String) async throws {
        let data = try await perform(
            method: "POST",
            pathComponents: ["v1", "uploads", shareID, "complete"],
            bearerToken: uploadToken,
            expectedStatus: 200
        )
        let response = try JSONDecoder().decode(MediaRelayCompleteResponse.self, from: data)
        guard response.shareID == shareID,
              ISO8601DateFormatter().date(from: response.expiresAt) != nil else {
            throw MediaRelayShareError.invalidResponse
        }
    }

    func revoke(shareID: String, controlToken: String) async throws {
        _ = try await perform(
            method: "DELETE",
            pathComponents: ["v1", "shares", shareID],
            bearerToken: controlToken,
            expectedStatus: 204
        )
    }

    private func perform(
        method: String,
        pathComponents: [String],
        bearerToken: String,
        contentType: String? = nil,
        body: Data? = nil,
        additionalHeaders: [String: String] = [:],
        expectedStatus: Int
    ) async throws -> Data {
        guard !bearerToken.isEmpty,
              pathComponents.allSatisfy({ !$0.isEmpty }) else {
            throw MediaRelayShareError.invalidConfiguration
        }
        let endpoint = pathComponents.reduce(baseURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MediaRelayShareError.invalidResponse
        }
        guard http.statusCode == expectedStatus else {
            throw MediaRelayShareError.serverRejected(http.statusCode)
        }
        if response.expectedContentLength > Int64(Self.responseByteLimit) {
            throw MediaRelayShareError.invalidResponse
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < Self.responseByteLimit else {
                throw MediaRelayShareError.invalidResponse
            }
            data.append(byte)
        }
        return data
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct MediaRelayShareRecord: Codable, Identifiable, Sendable {
    let shareID: String
    let title: String
    let publicURLString: String
    let apiBaseURLString: String
    let controlToken: String
    let createdAt: Date
    let expiresAt: Date
    var isComplete: Bool

    var id: String { shareID }
    var publicURL: URL? { URL(string: publicURLString) }
}

@MainActor
private enum MediaRelaySettingsStore {
    private static let endpointKey = "mediaRelay.apiBaseURL"
    private static let tokenAccount = "media-relay.admin-token"

    static var endpoint: String {
        UserDefaults.standard.string(forKey: endpointKey) ?? ""
    }

    static var token: String {
        KeychainService.localOnlyPasswordLookup(for: tokenAccount).password ?? ""
    }

    static func save(endpoint: String, token: String) throws {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty,
              KeychainService.setLocalOnlyPassword(trimmedToken, for: tokenAccount) else {
            throw MediaRelayShareError.credentialStorageFailed
        }
        UserDefaults.standard.set(endpoint, forKey: endpointKey)
    }
}

@MainActor
private enum MediaRelayShareRegistry {
    private static let idsKey = "mediaRelay.managedShareIDs"
    private static let accountPrefix = "media-relay.share."

    static func records() -> [MediaRelayShareRecord] {
        let ids = UserDefaults.standard.stringArray(forKey: idsKey) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return ids.compactMap { id in
            guard MediaRelayConfigurationPolicy.isOpaqueIdentifier(id),
                  let value = KeychainService.localOnlyPasswordLookup(
                    for: accountPrefix + id
                  ).password,
                  let data = value.data(using: .utf8),
                  let record = try? decoder.decode(MediaRelayShareRecord.self, from: data),
                  record.shareID == id else {
                return nil
            }
            return record
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ record: MediaRelayShareRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(record)
        guard let value = String(data: data, encoding: .utf8),
              KeychainService.setLocalOnlyPassword(
                value,
                for: accountPrefix + record.shareID
              ) else {
            throw MediaRelayShareError.credentialStorageFailed
        }
        var ids = UserDefaults.standard.stringArray(forKey: idsKey) ?? []
        ids.removeAll { $0 == record.shareID }
        ids.insert(record.shareID, at: 0)
        var retained = Array(ids.prefix(50))
        for evictedID in ids.dropFirst(retained.count) {
            if !KeychainService.deletePassword(for: accountPrefix + evictedID) {
                retained.append(evictedID)
            }
        }
        UserDefaults.standard.set(retained, forKey: idsKey)
    }

    static func remove(_ record: MediaRelayShareRecord) {
        guard KeychainService.deletePassword(for: accountPrefix + record.shareID) else {
            return
        }
        var ids = UserDefaults.standard.stringArray(forKey: idsKey) ?? []
        ids.removeAll { $0 == record.shareID }
        UserDefaults.standard.set(ids, forKey: idsKey)
    }
}

struct MediaRelayShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore

    let song: Song
    private let minimumExpirationDate: Date
    private let maximumExpirationDate: Date

    @State private var endpoint = ""
    @State private var adminToken = ""
    @State private var password = ""
    @State private var expirationDate: Date
    @State private var progress = 0.0
    @State private var uploadedBytes: Int64 = 0
    @State private var isUploading = false
    @State private var errorMessage: String?
    @State private var createdRecord: MediaRelayShareRecord?
    @State private var records: [MediaRelayShareRecord] = []
    @State private var revokingShareID: String?
    @State private var uploadTask: Task<Void, Never>?

    init(song: Song) {
        let now = Date()
        self.song = song
        self.minimumExpirationDate = now.addingTimeInterval(60)
        self.maximumExpirationDate = now.addingTimeInterval(30 * 24 * 60 * 60)
        _expirationDate = State(
            initialValue: now.addingTimeInterval(7 * 24 * 60 * 60)
        )
    }

    private var source: MusicSource? {
        sourcesStore.source(id: song.sourceID)
    }

    private var isSupported: Bool {
        guard let source else { return false }
        return MediaRelaySourcePolicy.supports(song: song, sourceType: source.type)
    }

    var body: some View {
        NavigationStack {
            Form {
                mediaSection
                configurationSection
                optionsSection
                createSection
                if let createdRecord {
                    createdSection(createdRecord)
                }
                managedSharesSection
                securitySection
            }
            .navigationTitle("relay_share_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
                        .disabled(isUploading)
                }
            }
        }
        .interactiveDismissDisabled(isUploading)
        .task(id: song.id) {
            endpoint = MediaRelaySettingsStore.endpoint
            adminToken = MediaRelaySettingsStore.token
            records = MediaRelayShareRegistry.records()
        }
        .onDisappear {
            uploadTask?.cancel()
            uploadTask = nil
        }
        .alert(
            "server_share_error_title",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("done", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var mediaSection: some View {
        Section("server_share_target_section") {
            LabeledContent("server_share_target_name") {
                Text(verbatim: song.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            if let source {
                LabeledContent("server_share_source") {
                    Text(verbatim: source.name)
                }
            }
            LabeledContent("relay_share_format") {
                Text(verbatim: song.fileFormat.displayName)
            }
            LabeledContent("relay_share_size") {
                Text(ByteCountFormatter.string(
                    fromByteCount: song.fileSize,
                    countStyle: .file
                ))
            }
            if !isSupported {
                Label("relay_share_unsupported_message", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private var configurationSection: some View {
        Section {
            TextField("relay_share_endpoint_placeholder", text: $endpoint)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .accessibilityLabel(Text("relay_share_endpoint"))
            SecureField("relay_share_token_placeholder", text: $adminToken)
                .textContentType(.password)
                .privacySensitive()
                .accessibilityLabel(Text("relay_share_token"))
        } header: {
            Text("relay_share_configuration")
        } footer: {
            Text("relay_share_configuration_footer")
        }
    }

    private var optionsSection: some View {
        Section("server_share_options") {
            DatePicker(
                "server_share_expiration",
                selection: $expirationDate,
                in: minimumExpirationDate...maximumExpirationDate
            )
            SecureField("relay_share_password_placeholder", text: $password)
                .textContentType(.newPassword)
                .privacySensitive()
                .accessibilityLabel(Text("relay_share_password"))
            Text("relay_share_password_footer")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var createSection: some View {
        Section {
            if isUploading {
                ProgressView(value: progress) {
                    Text("relay_share_uploading")
                } currentValueLabel: {
                    Text(ByteCountFormatter.string(
                        fromByteCount: uploadedBytes,
                        countStyle: .file
                    ))
                }
                .accessibilityValue(Text(progress, format: .percent))
            }

            Button {
                uploadTask?.cancel()
                uploadTask = Task { await createRelayShare() }
            } label: {
                HStack {
                    Spacer()
                    Label("relay_share_create", systemImage: "link.badge.plus")
                    Spacer()
                }
            }
            .disabled(
                isUploading
                    || !isSupported
                    || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || adminToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityHint(Text("relay_share_create_hint"))
        }
    }

    private func createdSection(_ record: MediaRelayShareRecord) -> some View {
        Section("server_share_created") {
            Label("relay_share_created_message", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(verbatim: record.publicURLString)
                .font(.callout)
                .textSelection(.enabled)
                .privacySensitive()
                .accessibilityLabel(Text("server_share_public_link"))
            if let url = record.publicURL {
                Link(destination: url) {
                    Label("server_share_open_link", systemImage: "arrow.up.right.square")
                }
            }
            ShareLink(item: record.publicURLString, subject: Text(verbatim: record.title)) {
                Label("server_share_system_share", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                Task { await revoke(record) }
            } label: {
                if revokingShareID == record.shareID {
                    ProgressView()
                } else {
                    Label("relay_share_revoke", systemImage: "link.badge.minus")
                }
            }
            .disabled(revokingShareID != nil)
        }
    }

    @ViewBuilder
    private var managedSharesSection: some View {
        let managed = records.filter { $0.shareID != createdRecord?.shareID }
        if !managed.isEmpty {
            Section("relay_share_managed") {
                ForEach(managed.prefix(10)) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: record.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(record.expiresAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            if record.isComplete {
                                ShareLink(item: record.publicURLString) {
                                    Label("server_share_system_share", systemImage: "square.and.arrow.up")
                                }
                            } else {
                                Label("relay_share_pending_cleanup", systemImage: "clock.badge.exclamationmark")
                                    .font(.caption)
                            }
                            Spacer()
                            Button("relay_share_revoke", role: .destructive) {
                                Task { await revoke(record) }
                            }
                            .disabled(revokingShareID != nil)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private var securitySection: some View {
        Section {
            Label("relay_share_security_bytes", systemImage: "lock.shield")
            Label("relay_share_security_range", systemImage: "arrow.left.and.right")
            Label("relay_share_security_storage", systemImage: "externaldrive.badge.checkmark")
        } header: {
            Text("relay_share_security")
        } footer: {
            Text("relay_share_security_footer")
        }
    }

    @MainActor
    private func createRelayShare() async {
        guard !isUploading else { return }
        isUploading = true
        progress = 0
        uploadedBytes = 0
        defer { isUploading = false }

        var pendingRecord: MediaRelayShareRecord?
        var client: MediaRelayClient?
        do {
            guard let source, MediaRelaySourcePolicy.supports(
                song: song,
                sourceType: source.type
            ) else {
                throw MediaRelayShareError.unsupportedSong
            }
            let baseURL = try MediaRelayConfigurationPolicy.validatedAPIBaseURL(endpoint)
            let trimmedToken = adminToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard expirationDate > Date(), expirationDate <= maximumExpirationDate else {
                throw ServerMediaSharingError.invalidExpiration
            }
            try MediaRelaySettingsStore.save(endpoint: baseURL.absoluteString, token: trimmedToken)
            let relayClient = MediaRelayClient(baseURL: baseURL, adminToken: trimmedToken)
            client = relayClient

            let creation = try await relayClient.createUpload(
                fileName: MediaRelaySourcePolicy.suggestedFileName(for: song),
                contentType: MediaRelaySourcePolicy.contentType(for: song.fileFormat),
                size: song.fileSize,
                expiresAt: expirationDate,
                password: password
            )
            guard let decodedExpiration = ISO8601DateFormatter().date(
                from: creation.expiresAt
            ) else {
                throw MediaRelayShareError.invalidResponse
            }
            var record = MediaRelayShareRecord(
                shareID: creation.shareID,
                title: song.title,
                publicURLString: creation.publicURL,
                apiBaseURLString: baseURL.absoluteString,
                controlToken: creation.uploadToken,
                createdAt: Date(),
                expiresAt: decodedExpiration,
                isComplete: false
            )
            pendingRecord = record
            try MediaRelayShareRegistry.save(record)
            records = MediaRelayShareRegistry.records()

            let connector = try await sourceManager.connectorForSong(song)
            var offset: Int64 = 0
            var chunkIndex: Int64 = 0
            while offset < song.fileSize {
                try Task.checkCancellation()
                let length = min(creation.chunkSize, song.fileSize - offset)
                let data = try await connector.fetchRange(
                    path: song.filePath,
                    offset: offset,
                    length: length,
                    priority: .background
                )
                guard data.count == Int(length) else {
                    throw MediaRelayShareError.shortSourceRead
                }
                try await relayClient.uploadChunk(
                    shareID: creation.shareID,
                    uploadToken: creation.uploadToken,
                    index: chunkIndex,
                    offset: offset,
                    totalSize: song.fileSize,
                    data: data
                )
                offset += length
                chunkIndex += 1
                uploadedBytes = offset
                progress = Double(offset) / Double(song.fileSize)
            }

            try await relayClient.complete(
                shareID: creation.shareID,
                uploadToken: creation.uploadToken
            )
            record.isComplete = true
            try MediaRelayShareRegistry.save(record)
            pendingRecord = nil
            createdRecord = record
            records = MediaRelayShareRegistry.records()
            password = ""
        } catch {
            if let pendingRecord, let client {
                let cleanup = Task.detached {
                    try await client.revoke(
                        shareID: pendingRecord.shareID,
                        controlToken: pendingRecord.controlToken
                    )
                }
                if case .success = await cleanup.result {
                    MediaRelayShareRegistry.remove(pendingRecord)
                }
                records = MediaRelayShareRegistry.records()
            }
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func revoke(_ record: MediaRelayShareRecord) async {
        guard revokingShareID == nil else { return }
        revokingShareID = record.shareID
        defer { revokingShareID = nil }
        do {
            let baseURL = try MediaRelayConfigurationPolicy.validatedAPIBaseURL(
                record.apiBaseURLString
            )
            let client = MediaRelayClient(baseURL: baseURL, adminToken: "")
            try await client.revoke(
                shareID: record.shareID,
                controlToken: record.controlToken
            )
            MediaRelayShareRegistry.remove(record)
            if createdRecord?.shareID == record.shareID {
                createdRecord = nil
            }
            records = MediaRelayShareRegistry.records()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
