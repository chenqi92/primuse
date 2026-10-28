import Foundation

struct WatchOfflineFileMetadata: Codable, Sendable {
    static let messageKey = "primuseOfflineFile"
    let id: String
    let path: String
    let size: Int64
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var displayPath: String { path.hasSuffix(".watchlyrics") ? (path as NSString).deletingPathExtension : path }
}

struct WatchOfflineLyric: Codable, Equatable, Sendable {
    let time: TimeInterval
    let text: String

    static func visibleLines(_ lines: [Self], at time: TimeInterval) -> (current: String, next: String) {
        let next = lines.firstIndex { $0.time > time } ?? lines.count
        return (next > 0 ? lines[next - 1].text : "", next < lines.count ? lines[next].text : "")
    }
}

struct WatchOfflineFile: Identifiable, Sendable {
    let path: String
    let size: Int64
    let title: String
    let artist: String
    let album: String
    var id: String { path }
    var displayPath: String { path.hasSuffix(".watchlyrics") ? (path as NSString).deletingPathExtension : path }
    var isAudio: Bool { WatchOfflineStorage.audioExtensions.contains((path as NSString).pathExtension.lowercased()) }
}

enum WatchOfflineStorageError: String, Error, LocalizedError {
    case invalidFile, unsupportedFile, notEnoughSpace, conflict
    var errorDescription: String? { rawValue }
}

/// WCSession 的临时文件在接收回调返回后失效，入库和索引写入必须在回调内完成。
final class WatchOfflineStorage: @unchecked Sendable {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "caf", "flac", "alac"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic"]
    static let supportedExtensions = audioExtensions.union(imageExtensions).union(["watchlyrics"])
    static let maximumSize: Int64 = 2 * 1024 * 1024 * 1024
    let root: URL
    private let lock = NSLock()
    private let fm = FileManager.default
    private var index: [String: WatchOfflineFileMetadata]

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(".index.json")
        if fm.fileExists(atPath: url.path) {
            index = try JSONDecoder().decode([String: WatchOfflineFileMetadata].self, from: Data(contentsOf: url))
        } else { index = [:] }
    }

    func resolve(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 32, path.utf8.count <= 2048,
              !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && $0.utf8.count <= 255 }) else {
            throw WatchOfflineStorageError.invalidFile
        }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw WatchOfflineStorageError.invalidFile
            }
        }
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw WatchOfflineStorageError.invalidFile
        }
        return url
    }

    func receive(_ source: URL, metadata: WatchOfflineFileMetadata) throws {
        try lock.withLock {
            let destination = try resolve(metadata.path)
            guard Self.supportedExtensions.contains(destination.pathExtension.lowercased()) else {
                throw WatchOfflineStorageError.unsupportedFile
            }
            if Self.imageExtensions.contains(destination.pathExtension.lowercased()), metadata.size > 20 * 1024 * 1024 {
                throw WatchOfflineStorageError.invalidFile
            }
            if destination.pathExtension.lowercased() == "watchlyrics", metadata.size > 8 * 1024 * 1024 {
                throw WatchOfflineStorageError.invalidFile
            }
            var freshSource = source
            freshSource.removeAllCachedResourceValues()
            let values = try freshSource.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  metadata.size > 0, metadata.size <= Self.maximumSize,
                  Int64(values.fileSize ?? -1) == metadata.size else { throw WatchOfflineStorageError.invalidFile }
            if fm.fileExists(atPath: destination.path) {
                // 已接收但回执尚未送达时，重试必须幂等。
                guard index[metadata.path]?.id == metadata.id,
                      (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == metadata.size else {
                    throw WatchOfflineStorageError.conflict
                }
                return
            }
            let available = try fm.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
            if let available, available.int64Value < metadata.size + 64 * 1024 * 1024 {
                throw WatchOfflineStorageError.notEnoughSpace
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: destination)
            var next = index
            next[metadata.path] = metadata
            do { try persist(next) }
            catch { try? fm.removeItem(at: destination); throw error }
            index = next
        }
    }

    func files() -> [WatchOfflineFile] {
        lock.withLock {
            index.values.compactMap { metadata in
                guard let url = try? resolve(metadata.path), fm.fileExists(atPath: url.path) else { return nil }
                return WatchOfflineFile(path: metadata.path, size: metadata.size,
                                        title: metadata.title.isEmpty ? url.deletingPathExtension().lastPathComponent : metadata.title,
                                        artist: metadata.artist, album: metadata.album)
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    func remove(_ path: String) throws {
        try lock.withLock {
            let url = try resolve(path)
            guard index[path] != nil else { throw WatchOfflineStorageError.invalidFile }
            // 删除当前文件；同目录的其他曲目和共用封面保留。
            try fm.removeItem(at: url)
            index[path] = nil
            try persist(index)
        }
    }

    func companionURL(for path: String, extensions: [String]) -> URL? {
        lock.withLock {
            let stem = (path as NSString).deletingPathExtension
            let folder = (path as NSString).deletingLastPathComponent
            let names = [stem] + ["cover", "folder"].map { folder.isEmpty ? $0 : folder + "/" + $0 }
            for name in names {
                for ext in extensions {
                    let candidate = name + "." + ext
                    if index[candidate] != nil, let url = try? resolve(candidate), fm.fileExists(atPath: url.path) { return url }
                }
            }
            return nil
        }
    }

    private func persist(_ index: [String: WatchOfflineFileMetadata]) throws {
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent(".index.json"), options: .atomic)
    }
}

struct WatchFileDeliveryState: Codable, Equatable {
    private(set) var status = "watchQueued"
    private(set) var error: String?
    private(set) var hasReceipt = false

    mutating func transferFinished(error: String?) {
        guard !hasReceipt else { return }
        status = error == nil ? "watchAwaitingReceipt" : "failed"
        self.error = error
    }

    mutating func acknowledge(error: String?) {
        hasReceipt = true
        status = error == nil ? "watchReceived" : "failed"
        self.error = error
    }

    mutating func retry() { self = Self() }
}
