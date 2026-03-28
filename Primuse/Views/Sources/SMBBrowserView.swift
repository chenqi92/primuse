import SwiftUI
import PrimuseKit

struct SMBBrowserView: View {
    let source: MusicSource
    @State private var currentPath = "/"
    @State private var items: [FileItem] = []
    @State private var isLoading = false
    @State private var error: String?

    struct FileItem: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        let modifiedDate: Date?
    }

    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ForEach(items) { item in
                    if item.isDirectory {
                        Button {
                            navigate(to: item.path)
                        } label: {
                            Label(item.name, systemImage: "folder.fill")
                        }
                    } else {
                        HStack {
                            Label(item.name, systemImage: audioIcon(for: item.name))

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { loadDirectory() }
    }

    private func navigate(to path: String) {
        currentPath = path
        loadDirectory()
    }

    private func loadDirectory() {
        isLoading = true
        // Will be connected to SMBSource
        Task {
            try? await Task.sleep(for: .seconds(1))
            isLoading = false
        }
    }

    private func audioIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if AudioFormat.from(fileExtension: ext)?.isLossless == true {
            return "waveform"
        }
        return "music.note"
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
