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
                breadcrumbBar
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

                bottomBar
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            guard hasLoadedRoot == false else { return }
            hasLoadedRoot = true
            loadDirectory()
        }
    }

    private var breadcrumbBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(pathStack.enumerated()), id: \.offset) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }

                        Button { navigateTo(index: index) } label: {
                            Text(displayName(for: segment))
                                .font(.caption)
                                .fontWeight(index == pathStack.count - 1 ? .semibold : .regular)
                                .foregroundStyle(index == pathStack.count - 1 ? Color.primary : Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .onChange(of: pathStack.count) { _, _ in
                withAnimation { proxy.scrollTo(pathStack.count - 1, anchor: .trailing) }
            }
        }
        .background(.bar)
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
        .listStyle(.plain)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if selectedDirectories.isEmpty {
                    Label("no_dirs_selected", systemImage: "music.note.list")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "\(selectedDirectories.count) \(String(localized: "directories_selected"))",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)

                    Spacer()

                    Button("clear_all") {
                        withAnimation { selectedDirectories.removeAll() }
                    }
                    .font(.caption)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
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
