import SwiftUI
import PrimuseKit

struct NFSBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector
    private let initialPath: String
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

        if let exportPath = source.exportPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           exportPath.isEmpty == false {
            self.initialPath = NFSSelectionPathCodec.makeSelectionPath(
                exportPath: exportPath,
                relativePath: "/"
            )
        } else {
            self.initialPath = "/"
        }
    }

    var body: some View {
        NFSDirectoryBrowserView(
            source: source,
            connector: connector,
            initialPath: initialPath,
            selectedDirectories: $selectedDirectories,
            onEditAddress: onEditAddress
        )
    }
}

private struct NFSDirectoryBrowserView: View {
    let source: MusicSource
    let connector: any MusicSourceConnector
    let initialPath: String
    @Binding var selectedDirectories: [String]
    let onEditAddress: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath: String
    @State private var pathStack: [String]
    @State private var items: [RemoteFileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoadedRoot = false
    @State private var failureReport = SourceConnectionFailureReport()

    init(
        source: MusicSource,
        connector: any MusicSourceConnector,
        initialPath: String,
        selectedDirectories: Binding<[String]>,
        onEditAddress: (() -> Void)?
    ) {
        self.source = source
        self.connector = connector
        self.initialPath = initialPath
        self._selectedDirectories = selectedDirectories
        self.onEditAddress = onEditAddress
        self._currentPath = State(initialValue: initialPath)
        self._pathStack = State(initialValue: [initialPath])
    }

    var body: some View {
        #if os(macOS)
        MacDirTreeBrowser(
            title: String(
                format: String(localized: "browse_source_format"),
                source.type.displayName,
                source.name
            ),
            subtitle: macConnectionString,
            rootTitle: source.exportPath ?? source.name,
            selectedDirectories: $selectedDirectories,
            load: { path in
                try await connector.connect()
                return try await connector.listFiles(at: path)
            },
            rootPath: initialPath,
            selectableRootPath: initialPath == "/" ? nil : initialPath,
            failureSource: source,
            onEditAddress: onEditAddress,
            tagSource: source
        )
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    private var macConnectionString: String {
        let host = source.host ?? ""
        guard !host.isEmpty else { return source.name }
        let exportPath = source.exportPath ?? ""
        guard !exportPath.isEmpty else { return "nfs://\(host)" }
        return "nfs://\(host)\(exportPath.hasPrefix("/") ? exportPath : "/\(exportPath)")"
    }
    #else
    private var iosBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DirectoryBreadcrumb(
                    segments: pathStack.map {
                        .init(path: $0, title: displayName(for: $0))
                    },
                    onSelect: navigateTo
                )
                Divider()

                if isLoading {
                    Spacer()
                    ProgressView()
                        .pmAppearFade(.contentAppear)
                    Text("loading_directories")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .pmAppearFade(.contentAppear)
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
                        Button("retry") { loadDirectory() }
                            .buttonStyle(.bordered)
                        SourceConnectionEditAddressButton(
                            report: failureReport,
                            onEditAddress: onEditAddress
                        )
                    }
                    .padding(.horizontal, 40)
                    .pmAppearFade(.contentAppear)
                    Spacer()
                } else {
                    browserContent
                        .pmAppearFade(.contentAppear)
                }

                BrowserBottomBar(
                    selectedCount: selectedDirectories.count,
                    idleIcon: "music.note.list",
                    chips: selectedDirectories.map { path in
                        BrowserSelectionChip(
                            id: path,
                            title: (path as NSString).lastPathComponent,
                            isSpokenWord: DirectoryFolderTag.forFolder(path: path, of: source)?.isSpokenWord == true
                        )
                    },
                    onRemove: { path in
                        pmWithAnimation(.list) { selectedDirectories.removeAll { $0 == path } }
                    }
                ) {
                    pmWithAnimation(.list) { selectedDirectories.removeAll() }
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
            guard hasLoadedRoot == false else { return }
            hasLoadedRoot = true
            loadDirectory()
        }
    }
    #endif

    private var directoryList: some View {
        let directories = items.filter(\.isDirectory)

        return List {
            if directories.isEmpty {
                ContentUnavailableView(
                    "no_subdirectories",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("no_subdirectories_desc")
                )
            } else {
                if currentPath != "/" {
                    DirectoryCheckRow(
                        name: String(localized: "current_directory"),
                        subtitle: displayBreadcrumb(for: currentPath),
                        path: currentPath,
                        icon: "folder.fill",
                        iconColor: .orange,
                        isNavigable: false,
                        selectedDirectories: $selectedDirectories,
                        folderTag: DirectoryFolderTag.forFolder(path: currentPath, of: source)
                    )
                }

                ForEach(directories, id: \.path) { item in
                    DirectoryCheckRow(
                        name: item.name,
                        subtitle: nil,
                        path: item.path,
                        icon: currentPath == "/" ? "externaldrive.fill" : "folder.fill",
                        iconColor: currentPath == "/" ? .accentColor : .blue,
                        isNavigable: true,
                        selectedDirectories: $selectedDirectories,
                        onNavigate: { enterDirectory(item) },
                        folderTag: DirectoryFolderTag.forFolder(path: item.path, of: source)
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
                title: displayName(for: currentPath),
                path: displayBreadcrumb(for: currentPath).isEmpty ? currentPath : displayBreadcrumb(for: currentPath),
                items: items,
                selectedCount: selectedDirectories.count
            )
        }
        #else
        directoryList
        #endif
    }

    private func enterDirectory(_ item: RemoteFileItem) {
        currentPath = item.path
        pathStack.append(item.path)
        loadDirectory()
    }

    private func navigateTo(index: Int) {
        guard index < pathStack.count else { return }
        currentPath = pathStack[index]
        pathStack = Array(pathStack.prefix(index + 1))
        loadDirectory()
    }

    private func loadDirectory() {
        isLoading = true
        errorMessage = nil
        failureReport = SourceConnectionFailureReport()

        let requestPath = currentPath
        Task {
            do {
                let loaded = try await loadItems(at: requestPath)
                guard requestPath == currentPath else { return }
                items = loaded
                isLoading = false
            } catch {
                guard requestPath == currentPath else { return }
                // 先把「这次连的是哪个地址」问出来再落错误文本,免得失败页
                // 先闪一下只有错误、随后才补上地址那一行。
                failureReport = await SourceConnectionFailureReport.resolve(
                    for: source,
                    suggestsAddressEdit: SourceConnectionFailureReport
                        .errorSuggestsAddressEdit(error)
                )
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func loadItems(at path: String) async throws -> [RemoteFileItem] {
        try await DirectoryBrowserNetworkRetry.loadWithLocalNetworkAuthorizationGrace {
            try await connector.connect()
            return try await connector.listFiles(at: path)
        }
    }

    private func displayName(for path: String) -> String {
        if path == "/" {
            return source.exportPath?.isEmpty == false
                ? NFSSelectionPathCodec.displayName(forExportPath: source.exportPath ?? "/")
                : String(localized: "nfs_exports")
        }

        return NFSSelectionPathCodec.displayComponents(for: path).last
            ?? String(localized: "current_directory")
    }

    private func displayBreadcrumb(for path: String) -> String {
        NFSSelectionPathCodec.displayComponents(for: path).joined(separator: " / ")
    }
}
