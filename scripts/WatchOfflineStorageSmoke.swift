import Foundation

@main struct WatchOfflineStorageSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-offline-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let storage = try WatchOfflineStorage(root: library)
        func source(_ name: String = UUID().uuidString) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data([1, 2, 3]).write(to: url)
            return url
        }
        func rejects(_ body: () throws -> Void) {
            do { try body(); fatalError("invalid operation succeeded") } catch {}
        }
        let reused = try source()
        _ = try reused.resourceValues(forKeys: [.fileSizeKey])
        try Data([1, 2, 3, 4]).write(to: reused)
        try storage.receive(reused, metadata: .init(id: "reused", path: "Reused.m4a", size: 4))
        try storage.remove("Reused.m4a")
        let track = WatchOfflineFileMetadata(id: "track", path: "Album/Music.mp3", size: 3, title: "Song", artist: "Artist")
        let incoming = try source()
        try storage.receive(incoming, metadata: track)
        precondition(!FileManager.default.fileExists(atPath: incoming.path))
        precondition(storage.files().count == 1 && storage.files()[0].title == "Song")
        try storage.receive(source(), metadata: track)
        precondition(storage.files().count == 1)
        rejects { try storage.receive(source(), metadata: .init(id: "different", path: track.path, size: 3)) }
        rejects { try storage.receive(source(), metadata: .init(id: "short", path: "bad.mp3", size: 4)) }
        rejects { try storage.receive(source(), metadata: .init(id: "unsupported", path: "file.exe", size: 3)) }
        for path in ["../escape.mp3", "/escape.mp3", "foo/../escape.mp3", "foo//escape.mp3", "foo\\escape.mp3", ".hidden.mp3"] {
            rejects { try storage.receive(source(), metadata: .init(id: "bad", path: path, size: 3)) }
        }
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("link"), withDestinationURL: root)
        rejects { _ = try storage.resolve("link/escape.mp3") }
        try storage.receive(source(), metadata: .init(id: "cover", path: "Album/Music.jpg", size: 3))
        precondition(storage.companionURL(for: track.path, extensions: ["jpg"]) != nil)
        let restarted = try WatchOfflineStorage(root: library)
        precondition(restarted.files().count == 2)
        try restarted.remove(track.path)
        precondition(restarted.files().count == 1 && restarted.files()[0].isAudio == false)
        let afterDeletion = try WatchOfflineStorage(root: library)
        precondition(afterDeletion.files().count == 1)
        let lyrics = [WatchOfflineLyric(time: 3, text: "first"), .init(time: 7, text: "second"), .init(time: 11, text: "")]
        precondition(WatchOfflineLyric.visibleLines(lyrics, at: 0).current.isEmpty)
        precondition(WatchOfflineLyric.visibleLines(lyrics, at: 3).current == "first")
        precondition(WatchOfflineLyric.visibleLines(lyrics, at: 8).next.isEmpty)
        precondition(WatchOfflineLyric.visibleLines(lyrics, at: 12).current.isEmpty)
        precondition(WatchOfflineLyric.visibleLines(lyrics, at: 4).next == "second")
        precondition(WatchOfflineLocalization.string("watchReceived", language: "zh-Hans") == "已保存到 Apple Watch")
        var delivery = WatchFileDeliveryState()
        delivery.acknowledge(error: "notEnoughSpace")
        delivery.transferFinished(error: nil)
        precondition(delivery.status == "failed" && delivery.error == "notEnoughSpace")
        delivery.retry()
        precondition(!delivery.hasReceipt && delivery.status == "watchQueued")
        delivery.transferFinished(error: nil)
        precondition(delivery.status == "watchAwaitingReceipt")
        delivery.acknowledge(error: nil)
        delivery.transferFinished(error: "late error")
        precondition(delivery.status == "watchReceived" && delivery.error == nil)
        let restoredDelivery = try JSONDecoder().decode(WatchFileDeliveryState.self, from: JSONEncoder().encode(delivery))
        precondition(restoredDelivery == delivery)
        print("Watch offline: durable import, retry, collision, size, traversal, symlink, delete, companions, lyrics and localization passed")
    }
}
