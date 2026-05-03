import SwiftUI
import PrimuseKit

struct UPnPBrowserView: View {
    let source: MusicSource
    @Binding var selectedDirectories: [String]

    private let connector: any MusicSourceConnector

    init(source: MusicSource, selectedDirectories: Binding<[String]>) {
        self.source = source
        self._selectedDirectories = selectedDirectories
        self.connector = UPnPSource(sourceID: source.id)
    }

    var body: some View {
        UPnPDirectoryBrowserView(
            source: source,
            connector: connector,
            selectedDirectories: $selectedDirectories
        )
    }
}

private struct UPnPDirectoryBrowserView: View {
    let source: MusicSource
    let connector: any MusicSourceConnector
    @Binding var selectedDirectories: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = "/"
    @State private var pathStack: [String] = ["/"]
    @State private var items: [RemoteFileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoadedRoot = false

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
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("no_subdirectories_desc")
                )
            } else {
                if currentPath != "/" {
                    DirectoryCheckRow(
                        name: String(localized: "current_directory"),
                        subtitle: displayBreadcrumb(for: currentPath),
                        path: currentPath,
                        icon: "music.note.house.fill",
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
                        icon: currentPath == "/" ? "music.note.house.fill" : "folder.fill",
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
            return String(localized: "shared_folders")
        }

        return pathDisplayComponents(path).last ?? String(localized: "current_directory")
    }

    private func displayBreadcrumb(for path: String) -> String {
        pathDisplayComponents(path).joined(separator: " / ")
    }

    private func pathDisplayComponents(_ path: String) -> [String] {
        guard path.hasPrefix("upnp::"),
              let displayPath = path.components(separatedBy: "::").last else {
            return []
        }

        return displayPath
            .split(separator: "/")
            .map { String($0) }
            .map {
                $0.replacingOccurrences(of: "∕", with: "/")
                    .replacingOccurrences(of: "꞉", with: ":")
            }
    }
}
