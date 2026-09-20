#if os(iOS)
import MusicKit
import SwiftUI
import PrimuseKit

/// 系统自带的 Apple Music 选歌器（`.musicPicker`，iOS 27 起）。
///
/// **只有 iOS。** `musicPicker(isPresented:title:selection:)` 在 macOS 上被显式标成
/// unavailable（不是版本门槛，是整个平台没有），`MusicLibrary.shared` 在 macOS 上
/// 同样不存在。所以整份文件用 `#if os(iOS)` 圈起来，Mac 端不提供这个入口。
///
/// 选中的歌**先加进用户自己的 Apple Music 资料库**，再触发一次同步，让它按正常
/// 链路进 Primuse。不直接把目录曲塞进本地库：音乐源的启动对账会把「源里已经没有
/// 的歌」清掉，硬塞进去的目录曲下次同步就会被抹掉，歌单会莫名其妙变空。
///
/// 只有系统够新、且用户已授权 Apple Music 时才出现这个入口。
struct AppleMusicCatalogPickerButton: View {
    /// 选完并加进资料库后触发一次同步。
    var onAdded: () -> Void

    @State private var isPresented = false
    @State private var picked: [MusicKit.Song] = []
    @State private var status: Status?

    private enum Status: Equatable {
        case adding
        case added(Int)
        case failed(String)
    }

    var body: some View {
        if #available(iOS 27.0, *) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    isPresented = true
                } label: {
                    Label("apple_music_pick_from_catalog", systemImage: "plus.magnifyingglass")
                }
                .disabled(status == .adding)
                .musicPicker(isPresented: $isPresented, selection: $picked)
                .onChange(of: picked) { _, songs in
                    guard !songs.isEmpty else { return }
                    Task { await addToLibrary(songs) }
                }

                if let status {
                    statusLabel(status)
                }
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: Status) -> some View {
        switch status {
        case .adding:
            Text("apple_music_pick_adding")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .added(let count):
            Text(String(format: PMString("apple_music_pick_added"), count))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @available(iOS 27.0, *)
    private func addToLibrary(_ songs: [MusicKit.Song]) async {
        status = .adding
        var added = 0
        var firstFailure: String?
        for song in songs {
            do {
                // 一次只能加一首 —— MusicLibrary 没有批量接口。
                try await MusicLibrary.shared.add(song)
                added += 1
            } catch {
                if firstFailure == nil { firstFailure = error.localizedDescription }
            }
        }
        picked = []
        if added > 0 {
            status = .added(added)
            onAdded()
        } else {
            status = .failed(firstFailure ?? PMString("apple_music_pick_failed"))
        }
    }
}
#endif
