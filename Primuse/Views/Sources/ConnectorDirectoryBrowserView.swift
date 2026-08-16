import SwiftUI
import PrimuseKit

struct ConnectorDirectoryBrowserView: View {
    private struct BreadcrumbSegment: Equatable {
        let path: String
        let title: String
    }

    let source: MusicSource
    let connector: any MusicSourceConnector
    @Binding var selectedDirectories: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = "/"
    @State private var pathStack: [BreadcrumbSegment] = [
        .init(path: "/", title: String(localized: "shared_folders"))
    ]
    @State private var items: [RemoteFileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoadedRoot = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Group {
            #if os(macOS)
            MacDirTreeBrowser(
                title: String(
                    format: String(localized: "browse_source_format"),
                    source.type.displayName,
                    source.name
                ),
                subtitle: macConnectionString,
                rootTitle: source.basePath ?? source.name,
                selectedDirectories: policySelectedDirectories,
                load: { path in
                    try await ensureInsecureHTTPAccess()
                    try await connector.connect()
                    return try await connector.listFiles(at: path)
                },
                rootPath: SourceDirectorySelectionPolicy.connectorPath(
                    for: source.type,
                    browserPath: "/"
                ),
                selectableRootPath: SourceDirectorySelectionPolicy.selectableRootPath(
                    for: source.type,
                    browserPath: "/"
                )
            )
            #else
            iosBody
            #endif
        }
        .transportTrustAlerts()
    }

    #if os(macOS)
    /// 顶栏副标题用的连接串, 例如 `smb://10.0.0.4/Music`。
    private var macConnectionString: String {
        let scheme = source.type.displayName.lowercased()
        let host = source.host ?? ""
        let share = source.shareName ?? ""
        if host.isEmpty { return scheme }
        if share.isEmpty { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host)/\(share)"
    }
    #endif

    private var iosBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DirectoryBreadcrumb(
                    segments: pathStack.map { .init(path: $0.path, title: $0.title) },
                    onSelect: navigateTo
                )
                Divider()

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
                        Button("retry") { loadDirectory() }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 40)
                    Spacer()
                } else {
                    browserContent
                }

                BrowserBottomBar(selectedCount: selectedDirectories.count) {
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
            guard !hasLoadedRoot else { return }
            hasLoadedRoot = true
            loadDirectory()
        }
    }

    private func promptSSLTrust(for error: Error) async -> Bool {
        guard let domain = SSLTrustStore.sslErrorDomain(from: error) else { return false }
        return await SSLTrustStore.shared.requestTrust(domain: domain)
    }

    private func promptTransportTrust(for error: Error) async -> Bool {
        if case TrustedHTTPTransportError.permissionRequired(let host) = error {
            return await promptInsecureHTTPTrust(host: host)
        }
        return await promptSSLTrust(for: error)
    }

    private var directoryList: some View {
        let directories = items.filter(\.isDirectory)
        let selectableRootPath = SourceDirectorySelectionPolicy.selectableRootPath(
            for: source.type,
            browserPath: currentPath
        )

        return List {
            if let selectableRootPath {
                DirectoryCheckRow(
                    name: String(localized: "current_directory"),
                    subtitle: source.basePath,
                    path: selectableRootPath,
                    icon: "shippingbox.fill",
                    iconColor: .orange,
                    isNavigable: false,
                    selectedDirectories: policySelectedDirectories
                )
            }

            if directories.isEmpty, selectableRootPath == nil {
                ContentUnavailableView(
                    "no_subdirectories",
                    systemImage: "folder",
                    description: Text("no_subdirectories_desc")
                )
            } else {
                if currentPath != "/" {
                    DirectoryCheckRow(
                        name: String(localized: "current_directory"),
                        subtitle: currentDirectorySubtitle,
                        path: currentPath,
                        icon: "folder.fill",
                        iconColor: .orange,
                        isNavigable: false,
                        selectedDirectories: policySelectedDirectories
                    )
                }

                ForEach(directories, id: \.path) { item in
                    DirectoryCheckRow(
                        name: item.name,
                        subtitle: nil,
                        path: item.path,
                        icon: "folder.fill",
                        iconColor: .blue,
                        isNavigable: true,
                        selectedDirectories: policySelectedDirectories,
                        onNavigate: { enterDirectory(item) }
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
            directoryList
            Rectangle().fill(PMColor.divider).frame(width: 0.5)
            DirectoryPreviewPane(
                title: pathStack.last?.title ?? source.name,
                path: currentPath,
                items: items,
                selectedCount: selectedDirectories.count
            )
        }
        #else
        directoryList
        #endif
    }

    private var currentDirectorySubtitle: String? {
        guard currentPath != "/" else { return nil }
        if source.type.isCloudDrive {
            return pathStack.last?.title
        }
        return currentPath
    }

    private func enterDirectory(_ item: RemoteFileItem) {
        currentPath = item.path
        pathStack.append(.init(path: item.path, title: item.name))
        loadDirectory()
    }

    private func navigateTo(index: Int) {
        guard index < pathStack.count else { return }

        currentPath = pathStack[index].path
        pathStack = Array(pathStack.prefix(index + 1))
        loadDirectory()
    }

    private func loadDirectory() {
        loadTask?.cancel()

        isLoading = true
        errorMessage = nil

        // 捕获本次请求对应的路径, 写回前校验仍是当前目录, 避免快速导航时晚到的响应覆盖列表。
        let requestPath = currentPath
        loadTask = Task {
            do {
                let loaded = try await loadItems(at: requestPath)
                guard !Task.isCancelled, requestPath == currentPath else { return }
                applyLoadedItems(loaded)
                isLoading = false
            } catch {
                guard !Task.isCancelled, requestPath == currentPath else { return }
                let trusted = await promptTransportTrust(for: error)
                guard !Task.isCancelled, requestPath == currentPath else { return }
                if trusted {
                    do {
                        let loaded = try await loadItems(at: requestPath)
                        guard !Task.isCancelled, requestPath == currentPath else { return }
                        applyLoadedItems(loaded)
                    } catch {
                        guard !Task.isCancelled, requestPath == currentPath else { return }
                        errorMessage = error.localizedDescription
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }
    }

    private func loadItems(at path: String) async throws -> [RemoteFileItem] {
        let connectorPath = SourceDirectorySelectionPolicy.connectorPath(
            for: source.type,
            browserPath: path
        )
        return try await DirectoryBrowserNetworkRetry.loadWithLocalNetworkAuthorizationGrace {
            try await ensureInsecureHTTPAccess()
            try await connector.connect()
            return try await connector.listFiles(at: connectorPath)
        }
    }

    private func ensureInsecureHTTPAccess() async throws {
        guard Self.usesHTTPTransport(source.type),
              let url = NetworkURLBuilder.baseURL(
                  host: source.host ?? "",
                  scheme: source.useSsl ? "https" : "http",
                  port: source.port
              ),
              TrustedHTTPTransport.requiresPlainSocket(for: url),
              let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
              !SSLTrustStore.shared.allowsInsecureHTTP(domain: trustTarget) else {
            return
        }

        let approved = await promptInsecureHTTPTrust(host: trustTarget)
        guard approved else {
            throw TrustedHTTPTransportError.permissionRequired(host: trustTarget)
        }
    }

    private static func usesHTTPTransport(_ type: MusicSourceType) -> Bool {
        switch type {
        case .qnap, .ugreen, .fnos, .webdav, .s3:
            return true
        default:
            return false
        }
    }

    private func promptInsecureHTTPTrust(host: String) async -> Bool {
        await SSLTrustStore.shared.requestInsecureHTTPTrust(domain: host)
    }

    private var policySelectedDirectories: Binding<[String]> {
        Binding(
            get: { selectedDirectories },
            set: {
                selectedDirectories = SourceDirectorySelectionPolicy.normalizedSelections(
                    $0,
                    for: source.type
                )
            }
        )
    }

    private func applyLoadedItems(_ loaded: [RemoteFileItem]) {
        items = loaded
        if source.type.isCloudDrive {
            CloudDirectoryNameStore.save(items, for: source.id)
            if let current = pathStack.last {
                CloudDirectoryNameStore.saveName(current.title, for: current.path, sourceID: source.id)
            }
        }
    }
}
