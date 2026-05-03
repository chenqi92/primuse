import SwiftUI
import PrimuseKit

struct MediaServerBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector

    init(source: MusicSource, selectedDirectories: Binding<[String]>) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = MediaServerSource(
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
    @State private var sslTrustDomain: String?
    @State private var sslTrustContinuation: CheckedContinuation<Bool, Never>?

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
                    libraryList
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
        .alert(
            String(localized: "ssl_trust_title"),
            isPresented: Binding(
                get: { sslTrustDomain != nil },
                set: { if !$0 { resolveSSLTrust(approved: false) } }
            )
        ) {
            Button(String(localized: "trust_domain"), role: .destructive) { resolveSSLTrust(approved: true) }
            Button(String(localized: "dont_trust"), role: .cancel) { resolveSSLTrust(approved: false) }
        } message: {
            if let domain = sslTrustDomain { Text("ssl_trust_message \(domain)") }
        }
    }

    private func resolveSSLTrust(approved: Bool) {
        if approved, let domain = sslTrustDomain { SSLTrustStore.shared.trust(domain: domain) }
        let cont = sslTrustContinuation
        sslTrustDomain = nil; sslTrustContinuation = nil
        cont?.resume(returning: approved)
    }

    private func promptSSLTrust(for error: Error) async -> Bool {
        guard let domain = SSLTrustStore.sslErrorDomain(from: error) else { return false }
        if SSLTrustStore.shared.isTrusted(domain: domain) { return true }
        return await withCheckedContinuation { continuation in
            sslTrustDomain = domain; sslTrustContinuation = continuation
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

    private func loadLibraries() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await connector.connect()
                libraries = try await connector.listFiles(at: "/")
                isLoading = false
            } catch {
                let trusted = await promptSSLTrust(for: error)
                if trusted {
                    do {
                        try await connector.connect()
                        libraries = try await connector.listFiles(at: "/")
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
}
