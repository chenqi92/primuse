#if os(iOS)
import Foundation
import Observation
@preconcurrency import WatchConnectivity
import PrimuseKit

@MainActor @Observable
final class WatchFileTransferService {
    static let shared = WatchFileTransferService()

    struct Entry: Codable, Identifiable {
        let metadata: WatchOfflineFileMetadata
        var delivery = WatchFileDeliveryState()
        var state: String { delivery.status }
        var error: String? { delivery.error }
        var id: String { metadata.id }
    }

    private(set) var entries: [Entry] = []
    private(set) var isAvailable = false
    private(set) var persistenceError: String?
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WatchTransfers", isDirectory: true)

    private init() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var directory = root; try directory.setResourceValues(values)
            let manifest = root.appendingPathComponent("queue.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: manifest))
            }
        } catch { persistenceError = error.localizedDescription }
    }

    func refresh() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        isAvailable = session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
        guard isAvailable else { return }
        let outstanding = Set(session.outstandingFileTransfers.compactMap { Self.metadata($0.file.metadata)?.id })
        // 上次退出时可能已写入队列但还没交给系统；相同 ID 在 Watch 端幂等接收。
        for entry in entries where entry.state == "watchQueued" && !outstanding.contains(entry.id) {
            submit(entry)
        }
    }

    func enqueue(staged: URL, path: String, size: Int64, song: Song?) async throws {
        guard isAvailable, persistenceError == nil else { throw WiFiTransferError.unavailable }
        let id = UUID().uuidString
        var path = path
        var size = size
        let ext = (path as NSString).pathExtension.lowercased()
        let destination = root.appendingPathComponent(id)
        do {
            if PrimuseConstants.readableLyricsExtensions.contains(ext) {
                guard size <= 8 * 1024 * 1024 else { throw WiFiTransferError.tooLarge }
                let text = try String(contentsOf: staged, encoding: .utf8)
                let lines = LyricsContentParser.parse(text).map { WatchOfflineLyric(time: $0.timestamp, text: $0.text) }
                guard !lines.isEmpty else { throw WiFiTransferError.unsupportedFile }
                let data = try JSONEncoder().encode(lines)
                try await WiFiTransferFilePreparation.write(data, to: destination)
                path = (path as NSString).deletingPathExtension + ".watchlyrics"
                size = Int64(data.count)
            } else {
                if WatchOfflineStorage.imageExtensions.contains(ext), size > 20 * 1024 * 1024 { throw WiFiTransferError.tooLarge }
                guard WatchOfflineStorage.supportedExtensions.contains(ext), size <= WatchOfflineStorage.maximumSize else {
                    throw WiFiTransferError.unsupportedFile
                }
                try await WiFiTransferFilePreparation.moveItem(at: staged, to: destination)
            }
            try Task.checkCancellation()
            let metadata = WatchOfflineFileMetadata(id: id, path: path, size: size,
                                                    title: song?.title ?? "", artist: song?.artistName ?? "", album: song?.albumTitle ?? "")
            let entry = Entry(metadata: metadata)
            entries.append(entry)
            do { try persist() }
            catch { entries.removeAll { $0.id == id }; throw error }
            submit(entry)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func retry(_ id: String) {
        guard isAvailable, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].delivery.retry()
        saveChanges()
        submit(entries[index])
    }

    func cancel(_ id: String) {
        for transfer in WCSession.default.outstandingFileTransfers where Self.metadata(transfer.file.metadata)?.id == id { transfer.cancel() }
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
        saveChanges()
    }

    func finished(id: String, error: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // 系统完成投递不代表文件已入库；成功只认 Watch 写盘后的回执。
        entries[index].delivery.transferFinished(error: error)
        saveChanges()
    }

    func acknowledge(id: String, error: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].delivery.acknowledge(error: error.map { WiFiTransferText.string($0 == "invalidFile" ? "invalidRequest" : $0) })
        if error == nil { try? FileManager.default.removeItem(at: root.appendingPathComponent(id)) }
        saveChanges()
    }

    private func submit(_ entry: Entry) {
        guard isAvailable, let data = try? JSONEncoder().encode(entry.metadata) else { return }
        let file = root.appendingPathComponent(entry.id)
        guard FileManager.default.fileExists(atPath: file.path) else {
            finished(id: entry.id, error: WiFiTransferText.string("notFound")); return
        }
        WCSession.default.transferFile(file, metadata: [WatchOfflineFileMetadata.messageKey: data])
    }

    nonisolated static func metadata(_ dictionary: [String: Any]?) -> WatchOfflineFileMetadata? {
        guard let data = dictionary?[WatchOfflineFileMetadata.messageKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchOfflineFileMetadata.self, from: data)
    }

    private func persist() throws {
        try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("queue.json"), options: .atomic)
    }

    private func saveChanges() {
        do { try persist(); persistenceError = nil }
        catch { persistenceError = error.localizedDescription }
    }
}
#endif
