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
    @State private var sslTrustDomain: String?
    @State private var sslTrustContinuation: CheckedContinuation<Bool, Never>?

    var body: some View {
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
                    directoryList
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

    private var directoryList: some View {
        let directories = items.filter(\.isDirectory)

        return List {
            if directories.isEmpty {
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
                        selectedDirectories: $selectedDirectories
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
                        selectedDirectories: $selectedDirectories,
                        onNavigate: { enterDirectory(item) }
                    )
                }
            }
        }
        .directoryBrowserListStyle()
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
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await connector.connect()
                items = try await connector.listFiles(at: currentPath)
                if source.type.isCloudDrive {
                    CloudDirectoryNameStore.save(items, for: source.id)
                    if let current = pathStack.last {
                        CloudDirectoryNameStore.saveName(current.title, for: current.path, sourceID: source.id)
                    }
                }
                isLoading = false
            } catch {
                let trusted = await promptSSLTrust(for: error)
                if trusted {
                    do {
                        try await connector.connect()
                        items = try await connector.listFiles(at: currentPath)
                        if source.type.isCloudDrive {
                            CloudDirectoryNameStore.save(items, for: source.id)
                            if let current = pathStack.last {
                                CloudDirectoryNameStore.saveName(current.title, for: current.path, sourceID: source.id)
                            }
                        }
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
