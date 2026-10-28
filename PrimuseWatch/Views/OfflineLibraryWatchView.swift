import SwiftUI

struct OfflineLibraryWatchView: View {
    @Environment(WatchPlayerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: WatchOfflineFile?

    var body: some View {
        List {
            if store.isOfflinePlayback {
                Button {
                    store.returnToPhone()
                    dismiss()
                } label: { Label(WatchString("ext.watch.offline.phone"), systemImage: "iphone") }
            }
            if store.offlineFiles.isEmpty {
                Text(WatchString("ext.watch.offline.empty"))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(store.offlineFiles.filter(\.isAudio)) { file in
                        Button {
                            store.playOffline(file)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.title).lineLimit(2)
                                Text([file.artist, ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .swipeActions { deleteButton(file) }
                    }
                } footer: {
                    Text(ByteCountFormatter.string(fromByteCount: store.offlineFiles.reduce(0) { $0 + $1.size }, countStyle: .file))
                }
                if store.offlineFiles.contains(where: { !$0.isAudio }) {
                    Section(WatchString("ext.watch.offline.companions")) {
                        ForEach(store.offlineFiles.filter { !$0.isAudio }) { file in
                            NavigationLink {
                                OfflineFilePreview(file: file)
                            } label: {
                                Label((file.displayPath as NSString).lastPathComponent,
                                      systemImage: file.path.hasSuffix(".watchlyrics") ? "text.alignleft" : "photo")
                                    .font(.footnote).lineLimit(2)
                            }
                            .swipeActions { deleteButton(file) }
                        }
                    }
                }
            }
        }
        .navigationTitle(WatchString("ext.watch.offline.title"))
        .onAppear { store.reloadOfflineFiles() }
        .confirmationDialog(WatchString("ext.watch.offline.delete"), isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { file in
            Button(WatchString("ext.watch.offline.delete"), role: .destructive) { store.removeOffline(file); pendingDeletion = nil }
            Button(WatchString("ext.watch.offline.cancel"), role: .cancel) { pendingDeletion = nil }
        } message: { file in Text((file.displayPath as NSString).lastPathComponent) }
    }

    private func deleteButton(_ file: WatchOfflineFile) -> some View {
        Button(role: .destructive) { pendingDeletion = file } label: {
            Label(WatchString("ext.watch.offline.delete"), systemImage: "trash")
        }
    }
}

private struct OfflineFilePreview: View {
    @Environment(WatchPlayerStore.self) private var store
    let file: WatchOfflineFile
    @State private var image: UIImage?
    @State private var lyrics: [WatchOfflineLyric] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                ForEach(Array(lyrics.enumerated()), id: \.offset) { _, line in
                    Text(line.text).font(.body)
                }
                Text(file.displayPath).font(.caption2).foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(WatchString("ext.watch.offline.companions"))
        .task {
            guard let url = try? store.offlineStorage?.resolve(file.path) else { return }
            if file.path.hasSuffix(".watchlyrics") {
                if let data = try? Data(contentsOf: url), data.count <= 8 * 1024 * 1024 {
                    lyrics = (try? JSONDecoder().decode([WatchOfflineLyric].self, from: data)) ?? []
                }
            } else { image = WatchOfflinePlayer.thumbnail(at: url) }
        }
    }
}
