import SwiftUI
import PrimuseKit

struct WebDAVBrowserView: View {
    let source: MusicSource
    @State private var currentPath = "/"
    @State private var items: [SMBBrowserView.FileItem] = []
    @State private var isLoading = false

    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "empty_directory",
                    systemImage: "folder",
                    description: Text("no_files_found")
                )
            } else {
                ForEach(items) { item in
                    if item.isDirectory {
                        Button {
                            currentPath = item.path
                            loadDirectory()
                        } label: {
                            Label(item.name, systemImage: "folder.fill")
                        }
                    } else {
                        HStack {
                            Label(item.name, systemImage: "music.note")
                            Spacer()
                            Text(formatSize(item.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadDirectory() }
    }

    private func loadDirectory() {
        isLoading = true
        // Will be connected to WebDAVSource
        Task {
            try? await Task.sleep(for: .seconds(1))
            isLoading = false
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
