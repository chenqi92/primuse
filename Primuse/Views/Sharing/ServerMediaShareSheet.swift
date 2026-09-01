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

    init(target: ServerMediaShareTarget) {
        let now = Date()
        self.target = target
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
                publicReachabilitySection
            }
            .navigationTitle("server_share_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
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
