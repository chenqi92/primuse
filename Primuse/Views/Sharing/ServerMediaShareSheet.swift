import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PrimuseKit
import SwiftUI

struct SongShareSheet: View {
    private enum PresentedLinkSheet: Identifiable {
        case musicServer(ServerMediaShareTarget)
        case primuseRelay

        var id: String {
            switch self {
            case .musicServer(let target):
                "server:\(target.id)"
            case .primuseRelay:
                "relay"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicLibrary.self) private var library

    let song: Song

    @State private var selectedMethod = SongShareLinkMethod.automatic
    @State private var nativeStatus = SongShareNativeCapabilityStatus.checking
    @State private var nativeFailureMessage: String?
    @State private var presentedLinkSheet: PresentedLinkSheet?

    private var source: MusicSource? {
        sourcesStore.source(id: song.sourceID)
    }

    private var nativeTarget: ServerMediaShareTarget? {
        guard let source else { return nil }
        return try? ServerMediaShareTargetPolicy.makeTarget(
            kind: .song,
            title: song.title,
            songs: [song],
            source: source
        )
    }

    private var relaySupported: Bool {
        guard let source else { return false }
        return MediaRelaySourcePolicy.supports(song: song, sourceType: source.type)
    }

    private var capabilities: SongShareLinkCapabilities {
        SongShareLinkCapabilities(
            canTryMusicServer: nativeTarget != nil,
            canUsePrimuseRelay: relaySupported
        )
    }

    private var decision: SongShareLinkDecision {
        SongShareLinkPolicy.decision(
            for: selectedMethod,
            nativeStatus: nativeStatus,
            capabilities: capabilities
        )
    }

    private var informationText: String {
        let artist = library.artistDisplayName(for: song)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return artist.isEmpty ? song.title : "\(song.title) — \(artist)"
    }

    var body: some View {
        NavigationStack {
            Form {
                songSection
                informationSection
                playableLinkSection
            }
            .navigationTitle("share_sheet_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
        .task(id: nativeTarget?.id) {
            await probeNativeCapability()
        }
        .sheet(item: $presentedLinkSheet) { destination in
            switch destination {
            case .musicServer(let target):
                ServerMediaShareSheet(
                    target: target,
                    relaySong: relaySupported ? song : nil
                )
            case .primuseRelay:
                MediaRelayShareSheet(song: song)
            }
        }
    }

    private var songSection: some View {
        Section {
            HStack(spacing: 14) {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 64,
                    cornerRadius: 12,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: song.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let artist = library.artistDisplayName(for: song), !artist.isEmpty {
                        Text(verbatim: artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let source {
                        Text(verbatim: source.name)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var informationSection: some View {
        Section {
            ShareLink(item: informationText, subject: Text(verbatim: song.title)) {
                Label("share_song_information_action", systemImage: "text.quote")
            }
            .accessibilityHint(Text("share_song_information_hint"))
        } header: {
            Text("share_song_information")
        } footer: {
            Text("share_song_information_footer")
        }
    }

    private var playableLinkSection: some View {
        Section {
            Picker("share_link_method", selection: $selectedMethod) {
                ForEach(SongShareLinkPolicy.availableMethods(for: capabilities)) { method in
                    Text(methodTitle(method)).tag(method)
                }
            }

            capabilitySummary

            Button(action: performPrimaryLinkAction) {
                HStack {
                    Spacer()
                    Label(primaryActionTitle, systemImage: primaryActionSymbol)
                    Spacer()
                }
            }
            .disabled(decision == .waitForMusicServer || decision == .unavailable)
            .accessibilityHint(Text(primaryActionHint))
        } header: {
            Text("share_create_playable_link")
        } footer: {
            Text("share_link_permissions_footer")
        }
    }

    @ViewBuilder
    private var capabilitySummary: some View {
        switch decision {
        case .waitForMusicServer:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("share_server_checking")
            }
            .accessibilityElement(children: .combine)
        case .useMusicServer:
            Label("share_auto_server_ready", systemImage: "server.rack")
                .foregroundStyle(.secondary)
        case .usePrimuseRelay:
            Label("share_relay_selected_summary", systemImage: "externaldrive.badge.icloud")
                .foregroundStyle(.secondary)
        case .confirmPrimuseRelay:
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(nativeFallbackTitle)
                    Text("share_auto_relay_recommended")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
        case .unavailable:
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(nativeUnavailableTitle)
                    if let nativeFailureMessage {
                        Text(verbatim: nativeFailureMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "link.badge.slash")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func methodTitle(_ method: SongShareLinkMethod) -> LocalizedStringKey {
        switch method {
        case .automatic: "share_method_automatic"
        case .musicServer: "share_method_music_server"
        case .primuseRelay: "share_method_primuse_relay"
        }
    }

    private var nativeFallbackTitle: LocalizedStringKey {
        switch nativeStatus {
        case .permissionDenied: "share_server_permission_denied"
        case .failed: "share_server_failed"
        case .checking: "share_server_checking"
        case .available: "share_auto_server_ready"
        case .unsupported: "share_server_unsupported"
        }
    }

    private var nativeUnavailableTitle: LocalizedStringKey {
        if selectedMethod == .musicServer {
            return nativeFallbackTitle
        }
        return "share_link_unavailable"
    }

    private var primaryActionTitle: LocalizedStringKey {
        switch decision {
        case .waitForMusicServer: "share_server_checking"
        case .useMusicServer: "share_continue_music_server"
        case .usePrimuseRelay: "share_continue_primuse_relay"
        case .confirmPrimuseRelay: "share_choose_primuse_relay"
        case .unavailable: "share_link_unavailable"
        }
    }

    private var primaryActionSymbol: String {
        switch decision {
        case .useMusicServer: "server.rack"
        case .usePrimuseRelay, .confirmPrimuseRelay: "externaldrive.badge.icloud"
        case .waitForMusicServer: "hourglass"
        case .unavailable: "link.badge.slash"
        }
    }

    private var primaryActionHint: LocalizedStringKey {
        switch decision {
        case .confirmPrimuseRelay: "share_choose_primuse_relay_hint"
        default: "share_create_playable_link_hint"
        }
    }

    private func performPrimaryLinkAction() {
        switch decision {
        case .useMusicServer:
            if let nativeTarget {
                presentedLinkSheet = .musicServer(nativeTarget)
            }
        case .usePrimuseRelay:
            presentedLinkSheet = .primuseRelay
        case .confirmPrimuseRelay:
            selectedMethod = .primuseRelay
        case .waitForMusicServer, .unavailable:
            break
        }
    }

    @MainActor
    private func probeNativeCapability() async {
        nativeFailureMessage = nil
        guard let nativeTarget else {
            nativeStatus = .unsupported
            return
        }
        nativeStatus = .checking
        do {
            let availability = try await sourceManager.serverMediaSharingAvailability(
                for: nativeTarget
            )
            try Task.checkCancellation()
            switch availability {
            case .available:
                nativeStatus = .available
            case .unsupported:
                nativeStatus = .unsupported
            case .permissionDenied:
                nativeStatus = .permissionDenied
            }
        } catch is CancellationError {
            return
        } catch {
            nativeFailureMessage = error.localizedDescription
            nativeStatus = .failed
        }
    }
}

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
    @State private var didFailCreation = false

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
           shouldOfferRelayFallback,
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

    private var shouldOfferRelayFallback: Bool {
        if didFailCreation { return true }
        switch capabilityState {
        case .unsupported, .permissionDenied, .failed:
            return true
        case .checking, .available:
            return false
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
        didFailCreation = false
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
            didFailCreation = true
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

    static func isShortCode(_ value: String) -> Bool {
        (4...6).contains(value.count) && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
        }
    }
}

private struct MediaRelayCreateRequest: Encodable {
    let fileName: String
    let contentType: String
    let size: Int64
    let expiresAt: String
    let password: String?
    let title: String
    let artist: String?
    let album: String?
    let audioFormat: String
    let quality: String?
    let durationSeconds: Double
    let allowPlayback: Bool
    let allowDownload: Bool
    let allowImport: Bool
    let linkType: String
    let shortCodeLength: Int?
}

private struct MediaRelayCreateResponse: Decodable, Sendable {
    let shareID: String
    let uploadToken: String
    let publicURL: String
    let chunkSize: Int64
    let expiresAt: String
    let accessCode: String?
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
        password: String?,
        title: String,
        artist: String?,
        album: String?,
        audioFormat: String,
        quality: String?,
        durationSeconds: Double,
        allowPlayback: Bool,
        allowDownload: Bool,
        allowImport: Bool,
        linkType: String,
        shortCodeLength: Int?
    ) async throws -> MediaRelayCreateResponse {
        let body = try JSONEncoder().encode(MediaRelayCreateRequest(
            fileName: fileName,
            contentType: contentType,
            size: size,
            expiresAt: Self.dateString(expiresAt),
            password: password?.isEmpty == false ? password : nil,
            title: title,
            artist: artist,
            album: album,
            audioFormat: audioFormat,
            quality: quality,
            durationSeconds: durationSeconds,
            allowPlayback: allowPlayback,
            allowDownload: allowDownload,
            allowImport: allowImport,
            linkType: linkType,
            shortCodeLength: shortCodeLength
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
            if linkType == "short" {
                guard let expectedLength = shortCodeLength,
                      let accessCode = response.accessCode,
                      accessCode.count == expectedLength else {
                    throw MediaRelayShareError.invalidResponse
                }
            } else if response.accessCode != nil {
                throw MediaRelayShareError.invalidResponse
            }
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
                  publicPath[publicPath.count - 2] == "s" else {
                throw MediaRelayShareError.invalidResponse
            }
            let publicIdentifier = String(publicPath[publicPath.count - 1])
            if let accessCode = response.accessCode {
                guard MediaRelayConfigurationPolicy.isShortCode(accessCode),
                      publicIdentifier == accessCode else {
                    throw MediaRelayShareError.invalidResponse
                }
            } else if !MediaRelayConfigurationPolicy.isOpaqueIdentifier(publicIdentifier) {
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
    let passwordProtected: Bool?
    let allowsPlayback: Bool?
    let allowsDownload: Bool?
    let allowsImport: Bool?
    let accessCode: String?
    var isComplete: Bool

    var id: String { shareID }
    var publicURL: URL? { URL(string: publicURLString) }
}

@MainActor
private enum MediaRelaySettingsStore {
    private static let endpointKey = "mediaRelay.apiBaseURL"
    private static let tokenAccount = "media-relay.admin-token"

    static var endpoint: String {
        UserDefaults.standard.string(forKey: endpointKey) ?? "https://share.soundisle.com"
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
    private enum AccessMode: String, CaseIterable, Identifiable {
        case publicAccess
        case password

        var id: String { rawValue }
    }

    private enum PublicLinkStyle: String, CaseIterable, Identifiable {
        case shortCode = "short"
        case secureLink = "long"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore

    let song: Song
    private let minimumExpirationDate: Date
    private let maximumExpirationDate: Date
    private let shortCodeMaximumExpirationDate: Date

    @State private var endpoint = ""
    @State private var adminToken = ""
    @State private var accessMode: AccessMode = .publicAccess
    @State private var password = ""
    @State private var publicLinkStyle: PublicLinkStyle = .shortCode
    @State private var shortCodeLength = 6
    @State private var allowsPlayback = true
    @State private var allowsDownload = false
    @State private var allowsImport = true
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
        self.shortCodeMaximumExpirationDate = now.addingTimeInterval(24 * 60 * 60)
        _expirationDate = State(
            initialValue: now.addingTimeInterval(60 * 60)
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
                in: minimumExpirationDate...effectiveMaximumExpirationDate
            )

            Picker("relay_share_link_style", selection: $publicLinkStyle) {
                Text("relay_share_link_short").tag(PublicLinkStyle.shortCode)
                Text("relay_share_link_secure").tag(PublicLinkStyle.secureLink)
            }
            .onChange(of: publicLinkStyle) { _, newValue in
                if newValue == .shortCode, expirationDate > shortCodeMaximumExpirationDate {
                    expirationDate = shortCodeMaximumExpirationDate
                }
            }

            if publicLinkStyle == .shortCode {
                Picker("relay_share_code_length", selection: $shortCodeLength) {
                    ForEach(4...6, id: \.self) { length in
                        Text(length, format: .number).tag(length)
                    }
                }
                Text("relay_share_short_code_footer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Picker("relay_share_access_mode", selection: $accessMode) {
                Text("relay_share_access_public").tag(AccessMode.publicAccess)
                Text("relay_share_access_password").tag(AccessMode.password)
            }
            .pickerStyle(.segmented)

            if accessMode == .password {
                SecureField("relay_share_password_placeholder", text: $password)
                    .textContentType(.newPassword)
                    .privacySensitive()
                    .accessibilityLabel(Text("relay_share_password"))
                Text("relay_share_password_footer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("relay_share_code_password_separate")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("relay_share_allow_playback", isOn: $allowsPlayback)
            Toggle("relay_share_allow_download", isOn: $allowsDownload)
            Toggle("relay_share_allow_import", isOn: $allowsImport)

            if !allowsPlayback && !allowsDownload && !allowsImport {
                Label("relay_share_no_actions_warning", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
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
                    || (accessMode == .password && password.isEmpty)
                    || (!allowsPlayback && !allowsDownload && !allowsImport)
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
                MediaRelayQRCodeView(value: record.publicURLString)
                    .frame(width: 172, height: 172)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("relay_share_qr_accessibility"))

                Link(destination: url) {
                    Label("server_share_open_link", systemImage: "arrow.up.right.square")
                }
            }
            if let accessCode = record.accessCode {
                LabeledContent("relay_share_access_code") {
                    Text(verbatim: accessCode)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel(Text("relay_share_access_code"))
                }
            }
            LabeledContent("relay_share_access_mode") {
                if record.passwordProtected == true {
                    Text("relay_share_access_password")
                } else {
                    Text("relay_share_access_public")
                }
            }
            if record.allowsPlayback == true {
                Label("relay_share_allow_playback", systemImage: "play.circle")
            }
            if record.allowsDownload == true {
                Label("relay_share_allow_download", systemImage: "arrow.down.circle")
            }
            if record.allowsImport == true {
                Label("relay_share_allow_import", systemImage: "square.and.arrow.down")
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
            guard expirationDate > Date(), expirationDate <= effectiveMaximumExpirationDate else {
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
                password: accessMode == .password ? password : nil,
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle,
                audioFormat: song.fileFormat.displayName,
                quality: qualityDescription,
                durationSeconds: max(0, song.duration),
                allowPlayback: allowsPlayback,
                allowDownload: allowsDownload,
                allowImport: allowsImport,
                linkType: publicLinkStyle.rawValue,
                shortCodeLength: publicLinkStyle == .shortCode ? shortCodeLength : nil
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
                passwordProtected: accessMode == .password,
                allowsPlayback: allowsPlayback,
                allowsDownload: allowsDownload,
                allowsImport: allowsImport,
                accessCode: creation.accessCode,
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

    private var effectiveMaximumExpirationDate: Date {
        publicLinkStyle == .shortCode
            ? shortCodeMaximumExpirationDate
            : maximumExpirationDate
    }

    private var qualityDescription: String? {
        var components: [String] = []
        if let bitDepth = song.bitDepth, bitDepth > 0 {
            components.append("\(bitDepth)-bit")
        }
        if let sampleRate = song.sampleRate, sampleRate > 0 {
            let kilohertz = Double(sampleRate) / 1_000
            components.append(kilohertz.formatted(.number.precision(.fractionLength(0...1))) + " kHz")
        }
        if components.isEmpty, let bitRate = song.bitRate, bitRate > 0 {
            components.append("\(bitRate) kbps")
        }
        return components.isEmpty ? nil : components.joined(separator: " / ")
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

private struct MediaRelayQRCodeView: View {
    let value: String

    var body: some View {
        ZStack {
            Color.white
            if let image = Self.makeQRCode(value) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .padding(12)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private static func makeQRCode(_ value: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, floor(768 / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(
            scaled,
            from: scaled.extent
        )
    }
}

struct MediaRelayImportRequest: Identifiable, Equatable {
    let importURL: URL

    var id: String { importURL.absoluteString }

    init?(url: URL) {
        guard let deepLink = URLComponents(url: url, resolvingAgainstBaseURL: false),
              deepLink.scheme?.lowercased() == "primuse",
              deepLink.host?.lowercased() == "import-share",
              deepLink.user == nil,
              deepLink.password == nil,
              deepLink.fragment == nil,
              deepLink.path.isEmpty || deepLink.path == "/",
              deepLink.queryItems?.count == 1,
              let rawImportURL = deepLink.queryItems?.first(where: {
                  $0.name == "url"
              })?.value,
              deepLink.queryItems?.filter({ $0.name == "url" }).count == 1,
              let importURL = URL(string: rawImportURL),
              let target = URLComponents(
                  url: importURL,
                  resolvingAgainstBaseURL: false
              ),
              target.scheme?.lowercased() == "https",
              target.user == nil,
              target.password == nil,
              target.query == nil,
              target.fragment == nil else {
            return nil
        }
        let path = target.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 2,
              path[0] == "i",
              MediaRelayConfigurationPolicy.isOpaqueIdentifier(String(path[1])),
              (try? ServerMediaShare.validatePublicURL(importURL.absoluteString)) != nil else {
            return nil
        }
        self.importURL = importURL
    }
}

private enum MediaRelayImportError: LocalizedError {
    case invalidResponse
    case unsupportedFile
    case fileTooLarge
    case emptyFile
    case localImportFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            String(localized: "relay_import_error_response")
        case .unsupportedFile:
            String(localized: "relay_import_error_format")
        case .fileTooLarge:
            String(localized: "relay_import_error_too_large")
        case .emptyFile:
            String(localized: "relay_import_error_empty")
        case .localImportFailed:
            String(localized: "relay_import_error_copy")
        }
    }
}

enum MediaRelayImportPolicy {
    static let maximumFileSize: Int64 = 20 * 1024 * 1024 * 1024
    static let minimumFileSize: Int64 = 1_024

    static func validatedFileName(_ suggestedName: String?) throws -> String {
        guard var name = suggestedName?.precomposedStringWithCanonicalMapping,
              !name.isEmpty else {
            throw MediaRelayImportError.unsupportedFile
        }
        name = name.replacingOccurrences(of: "\\", with: "_")
        name = name.replacingOccurrences(of: "/", with: "_")
        name = String(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != ".", name != "..", !name.hasPrefix(".") else {
            throw MediaRelayImportError.unsupportedFile
        }
        let fileExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard PrimuseConstants.supportedAudioExtensions.contains(fileExtension) else {
            throw MediaRelayImportError.unsupportedFile
        }
        if name.count > 180 {
            let suffix = "." + fileExtension
            name = String(name.prefix(max(1, 180 - suffix.count))) + suffix
        }
        return name
    }
}

struct MediaRelayImportSheet: View {
    private enum Phase: Equatable {
        case ready
        case downloading
        case copying(Double?)
        case scanning
        case finished
    }

    private static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(
            configuration: configuration,
            delegate: MediaRelayNoRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var musicLibrary
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(SourceManager.self) private var sourceManager
    @Environment(ScanService.self) private var scanService
    @Environment(MusicScraperService.self) private var scraperService

    let request: MediaRelayImportRequest

    @State private var phase: Phase = .ready
    @State private var downloadedBytes: Int64 = 0
    @State private var ticketConsumed = false
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?

    private var isWorking: Bool {
        switch phase {
        case .downloading, .copying, .scanning:
            true
        case .ready, .finished:
            false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(verbatim: request.importURL.host ?? "")
                    } icon: {
                        Image(systemName: "link.badge.plus")
                            .foregroundStyle(Color.accentColor)
                    }
                    Text("relay_import_ticket_note")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("relay_import_source")
                }

                Section {
                    phaseView
                } header: {
                    Text("relay_import_status")
                }

                Section {
                    if phase == .finished || ticketConsumed {
                        Button("done") { dismiss() }
                            .frame(maxWidth: .infinity)
                    } else {
                        Button {
                            importTask?.cancel()
                            errorMessage = nil
                            importTask = Task { await downloadAndImport() }
                        } label: {
                            HStack {
                                Spacer()
                                Label("relay_import_action", systemImage: "square.and.arrow.down")
                                Spacer()
                            }
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .navigationTitle("relay_import_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
        .onDisappear {
            importTask?.cancel()
            importTask = nil
        }
        .alert(
            "relay_import_error_title",
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

    @ViewBuilder
    private var phaseView: some View {
        switch phase {
        case .ready:
            if ticketConsumed {
                Label("relay_import_ticket_consumed", systemImage: "arrow.uturn.backward.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("relay_import_ready", systemImage: "music.note")
            }
        case .downloading:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                Text("relay_import_downloading")
                if downloadedBytes > 0 {
                    Text(ByteCountFormatter.string(
                        fromByteCount: downloadedBytes,
                        countStyle: .file
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        case .copying(let progress):
            VStack(alignment: .leading, spacing: 8) {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
                Text("relay_import_copying")
            }
        case .scanning:
            HStack(spacing: 12) {
                ProgressView()
                Text("relay_import_scanning")
            }
        case .finished:
            Label("relay_import_finished", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    @MainActor
    private func downloadAndImport() async {
        phase = .downloading
        downloadedBytes = 0

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseShareImport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        do {
            var urlRequest = URLRequest(url: request.importURL)
            urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            urlRequest.setValue("audio/*, application/octet-stream", forHTTPHeaderField: "Accept")
            urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            // Import tickets are intentionally single-use. Once the request is sent,
            // a retry must start from the original share page to obtain a fresh ticket.
            ticketConsumed = true
            let (temporaryURL, response) = try await Self.downloadSession.download(for: urlRequest)
            try Task.checkCancellation()

            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                throw MediaRelayImportError.invalidResponse
            }
            let mediaType = (http.mimeType ?? "").lowercased()
            guard mediaType.isEmpty
                    || mediaType.hasPrefix("audio/")
                    || mediaType == "application/octet-stream"
                    || mediaType == "application/ogg"
                    || mediaType == "video/mp4" else {
                throw MediaRelayImportError.unsupportedFile
            }
            if response.expectedContentLength > MediaRelayImportPolicy.maximumFileSize {
                throw MediaRelayImportError.fileTooLarge
            }
            let resourceValues = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(resourceValues.fileSize ?? 0)
            guard size >= MediaRelayImportPolicy.minimumFileSize else {
                throw MediaRelayImportError.emptyFile
            }
            guard size <= MediaRelayImportPolicy.maximumFileSize else {
                throw MediaRelayImportError.fileTooLarge
            }
            downloadedBytes = size

            let fileName = try MediaRelayImportPolicy.validatedFileName(
                response.suggestedFilename
            )
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            let stagedURL = stagingDirectory.appendingPathComponent(
                fileName,
                isDirectory: false
            )
            try FileManager.default.moveItem(at: temporaryURL, to: stagedURL)

            phase = .copying(nil)
            let session = LocalImportService.copySession(
                [stagedURL],
                cleanupPickedCopies: true
            )
            var finalResult: LocalImportService.CopyResult?
            await withTaskCancellationHandler {
                for await event in session.events {
                    switch event {
                    case .progress(let progress):
                        phase = .copying(progress.fraction)
                    case .finished(let result):
                        finalResult = result
                    }
                }
            } onCancel: {
                session.cancel()
            }
            try Task.checkCancellation()
            guard let finalResult, finalResult.copied > 0 else {
                throw MediaRelayImportError.localImportFailed
            }

            phase = .scanning
            let localSource = sourcesStore.source(id: LocalImportService.sourceID)
                ?? LocalImportService.makeSource(
                    name: String(localized: "local_import_source_name")
                )
            if sourcesStore.source(id: localSource.id) == nil {
                try sourcesStore.addDurably(localSource)
            }
            _ = scanService.scanSource(
                localSource,
                sourceManager: sourceManager,
                library: musicLibrary,
                sourceStore: sourcesStore,
                scraperService: scraperService
            )
            phase = .finished
        } catch is CancellationError {
            phase = .ready
        } catch {
            phase = .ready
            errorMessage = error.localizedDescription
        }
    }
}
