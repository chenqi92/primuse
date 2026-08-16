import SwiftUI
import PrimuseKit

struct MediaServerBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector

    init(
        source: MusicSource,
        connector: any MusicSourceConnector,
        selectedDirectories: Binding<[String]>
    ) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = connector
    }

    var body: some View {
        MediaServerLibraryBrowserView(
            source: source,
            connector: connector,
            selectedDirectories: $selectedDirectories
        )
    }
}

private struct MediaServerLibraryBrowserView: View {
    let source: MusicSource
    let connector: any MusicSourceConnector
    @Binding var selectedDirectories: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var libraries: [RemoteFileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoadedLibraries = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    Spacer()
                    ProgressView()
                    Text("loading_directories")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                } else if let errorMessage {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("retry") {
                            loadLibraries()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 40)
                    Spacer()
                } else {
                    browserContent
                }

                BrowserBottomBar(
                    selectedCount: selectedDirectories.count,
                    idleIcon: "music.note.list"
                ) {
                    withAnimation { selectedDirectories.removeAll() }
                }
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                DirectoryBrowserToolbar(
                    onCancel: { dismiss() },
                    onConfirm: { dismiss() }
                )
            }
        }
        .directoryBrowserSheetFrame()
        .onAppear {
            guard hasLoadedLibraries == false else { return }
            hasLoadedLibraries = true
            loadLibraries()
        }
        .transportTrustAlerts()
    }

    private func promptSSLTrust(for error: Error) async -> Bool {
        guard let domain = SSLTrustStore.sslErrorDomain(from: error) else { return false }
        return await SSLTrustStore.shared.requestTrust(domain: domain)
    }

    private func ensureInsecureHTTPAccess() async throws {
        guard let url = NetworkURLBuilder.baseURL(
            host: source.host ?? "",
            scheme: source.useSsl ? "https" : "http",
            port: source.port
        ),
        TrustedHTTPTransport.requiresPlainSocket(for: url),
        let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
        !SSLTrustStore.shared.allowsInsecureHTTP(domain: trustTarget) else {
            return
        }

        let approved = await SSLTrustStore.shared.requestInsecureHTTPTrust(domain: trustTarget)
        guard approved else {
            throw TrustedHTTPTransportError.permissionRequired(host: trustTarget)
        }
    }

    private var libraryList: some View {
        List {
            if libraries.isEmpty {
                ContentUnavailableView(
                    "no_subdirectories",
                    systemImage: "music.note.house",
                    description: Text("no_subdirectories_desc")
                )
            } else {
                ForEach(libraries, id: \.path) { item in
                    DirectoryCheckRow(
                        name: item.name,
                        subtitle: nil,
                        path: item.path,
                        icon: "music.note.house.fill",
                        iconColor: .accentColor,
                        isNavigable: false,
                        selectedDirectories: $selectedDirectories
                    )
                }
            }
        }
        .directoryBrowserListStyle()
    }

    @ViewBuilder
    private var browserContent: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            libraryList
            Rectangle().fill(PMColor.divider).frame(width: 0.5)
            DirectoryPreviewPane(
                title: source.name,
                path: "/",
                items: libraries,
                selectedCount: selectedDirectories.count
            )
        }
        #else
        libraryList
        #endif
    }

    private func loadLibraries() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                libraries = try await loadLibrariesWithAuthorizationGrace()
                isLoading = false
            } catch {
                let trusted = await promptSSLTrust(for: error)
                if trusted {
                    do {
                        libraries = try await loadLibrariesWithAuthorizationGrace()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }
    }

    private func loadLibrariesWithAuthorizationGrace() async throws -> [RemoteFileItem] {
        try await DirectoryBrowserNetworkRetry.loadWithLocalNetworkAuthorizationGrace {
            try await ensureInsecureHTTPAccess()
            try await connector.connect()
            return try await connector.listFiles(at: "/")
        }
    }
}
