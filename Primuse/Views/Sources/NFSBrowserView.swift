import SwiftUI
import PrimuseKit

struct NFSBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector
    private let initialPath: String

    init(source: MusicSource, selectedDirectories: Binding<[String]>) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = NFSSource(
            sourceID: source.id,
            host: source.host ?? "",
            port: source.port,
            exportPath: source.exportPath,
            nfsVersion: source.nfsVersion ?? .auto
        )

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
            selectedDirectories: $selectedDirectories
        )
    }
}

private struct NFSDirectoryBrowserView: View {
    let source: MusicSource
    let connector: any MusicSourceConnector
    let initialPath: String
    @Binding var selectedDirectories: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath: String
    @State private var pathStack: [String]
    @State private var items: [RemoteFileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoadedRoot = false

    init(
        source: MusicSource,
        connector: any MusicSourceConnector,
        initialPath: String,
        selectedDirectories: Binding<[String]>
    ) {
        self.source = source
        self.connector = connector
        self.initialPath = initialPath
        self._selectedDirectories = selectedDirectories
        self._currentPath = State(initialValue: initialPath)
        self._pathStack = State(initialValue: [initialPath])
    }

    var body: some View {
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
            guard hasLoadedRoot == false else { return }
            hasLoadedRoot = true
            loadDirectory()
        }
    }

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
                        selectedDirectories: $selectedDirectories
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
                        onNavigate: { enterDirectory(item) }
                    )
                }
            }
        }
        .directoryBrowserListStyle()
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

        Task {
            do {
                try await connector.connect()
                items = try await connector.listFiles(at: currentPath)
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func displayName(for path: String) -> String {
        if path == "/" {
            return source.exportPath?.isEmpty == false
                ? NFSSelectionPathCodec.displayName(forExportPath: source.exportPath ?? "/")
                : "NFS Exports"
        }

        return NFSSelectionPathCodec.displayComponents(for: path).last
            ?? String(localized: "current_directory")
    }

    private func displayBreadcrumb(for path: String) -> String {
        NFSSelectionPathCodec.displayComponents(for: path).joined(separator: " / ")
    }
}
