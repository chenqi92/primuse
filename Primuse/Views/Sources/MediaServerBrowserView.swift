import SwiftUI
import PrimuseKit

struct MediaServerBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector
    private let onEditAddress: (() -> Void)?

    init(
        source: MusicSource,
        connector: any MusicSourceConnector,
        selectedDirectories: Binding<[String]>,
        onEditAddress: (() -> Void)? = nil
    ) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = connector
        self.onEditAddress = onEditAddress
    }

    var body: some View {
        MediaServerLibraryBrowserView(
            source: source,
            connector: connector,
            selectedDirectories: $selectedDirectories,
            onEditAddress: onEditAddress
        )
    }
}

private struct MediaServerLibraryBrowserView: View {
    let source: MusicSource
    let connector: any MusicSourceConnector
    @Binding var selectedDirectories: [String]
    var onEditAddress: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var libraries: [RemoteFileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoadedLibraries = false
    @State private var failureReport = SourceConnectionFailureReport()

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
                        SourceConnectionFailureDetails(
                            report: failureReport,
                            errorText: errorMessage,
                            emphasis: .inline
                        )
                        Button("retry") {
                            loadLibraries()
                        }
                        .buttonStyle(.bordered)
                        SourceConnectionEditAddressButton(
                            report: failureReport,
                            onEditAddress: onEditAddress
                        )
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
        failureReport = SourceConnectionFailureReport()

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
                        await presentFailure(error)
                    }
                } else {
                    await presentFailure(error)
                }
                isLoading = false
            }
        }
    }

    /// 先把「这次连的是哪个地址」问出来再落错误文本,免得失败页先闪一下只有
    /// 错误、随后才补上地址那一行。
    private func presentFailure(_ error: Error) async {
        failureReport = await SourceConnectionFailureReport.resolve(
            for: source,
            suggestsAddressEdit: SourceConnectionFailureReport.errorSuggestsAddressEdit(error)
        )
        errorMessage = error.localizedDescription
    }

    private func loadLibrariesWithAuthorizationGrace() async throws -> [RemoteFileItem] {
        try await DirectoryBrowserNetworkRetry.loadWithLocalNetworkAuthorizationGrace {
            try await ensureInsecureHTTPAccess()
            try await connector.connect()
            return try await connector.listFiles(at: "/")
        }
    }
}
