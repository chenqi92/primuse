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

                bottomBar
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            guard hasLoadedLibraries == false else { return }
            hasLoadedLibraries = true
            loadLibraries()
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
                        withAnimation {
                            selectedDirectories.removeAll()
                        }
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

    private func loadLibraries() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await connector.connect()
                libraries = try await connector.listFiles(at: "/")
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}
