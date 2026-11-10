import Foundation
import PrimuseKit
import SwiftUI

@MainActor
final class LyricsCacheObserver {
    private let load: @MainActor (String) async -> [LyricLine]?
    private let center: NotificationCenter
    private var token: NSObjectProtocol?
    private var editToken: NSObjectProtocol?
    private var songID: String?
    private var receive: ((String, [LyricLine]) -> Void)?
    private var task: Task<Void, Never>?
    private var generation: UInt = 0

    init(center: NotificationCenter = .default,
         load: @escaping @MainActor (String) async -> [LyricLine]? = { await MetadataAssetStore.shared.cachedLyrics(forSongID: $0) }) {
        self.center = center
        self.load = load
    }

    func select(songID: String?, receive: @escaping (String, [LyricLine]) -> Void) {
        if self.songID != songID {
            generation &+= 1
            task?.cancel()
            task = nil
        }
        self.songID = songID
        self.receive = receive
        guard songID != nil else { stop(); return }
        if token == nil {
            token = center.addObserver(forName: .primuseLyricsDidCache, object: nil, queue: .main) { [weak self] note in
                guard let id = note.userInfo?["songID"] as? String else { return }
                MainActor.assumeIsolated { self?.cacheChanged(songID: id) }
            }
            editToken = center.addObserver(forName: .primuseLyricsDidChange, object: nil, queue: .main) { [weak self] note in
                guard let id = note.object as? String else { return }
                MainActor.assumeIsolated {
                    guard let self, self.songID == id else { return }
                    self.generation &+= 1
                    self.task?.cancel()
                    self.task = nil
                }
            }
        }
    }

    @discardableResult
    func cacheChanged(songID: String) -> Task<Void, Never>? {
        guard self.songID == songID else { return nil }
        task?.cancel()
        generation &+= 1
        let revision = generation
        let load = load
        // 只读已经写好的缓存；重新请求来源会再次写缓存并形成通知循环。
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let lines = await load(songID)
            guard !Task.isCancelled, let self, self.generation == revision,
                  self.songID == songID else { return }
            self.task = nil
            if let lines, !lines.isEmpty { self.receive?(songID, lines) }
        }
        return task
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        songID = nil
        receive = nil
        if let token { center.removeObserver(token) }
        if let editToken { center.removeObserver(editToken) }
        token = nil
        editToken = nil
    }

    func waitForPendingLoad() async {
        while let task { await task.value }
    }

    isolated deinit {
        task?.cancel()
        if let token { center.removeObserver(token) }
        if let editToken { center.removeObserver(editToken) }
    }
}

private struct LyricsCacheUpdates: ViewModifier {
    let songID: String?
    let receive: (String, [LyricLine]) -> Void
    @State private var observer = LyricsCacheObserver()

    func body(content: Content) -> some View {
        content
            .task(id: songID) { observer.select(songID: songID, receive: receive) }
            .onDisappear { observer.stop() }
    }
}

extension View {
    func onCachedLyricsChanged(songID: String?, receive: @escaping (String, [LyricLine]) -> Void) -> some View {
        modifier(LyricsCacheUpdates(songID: songID, receive: receive))
    }
}
