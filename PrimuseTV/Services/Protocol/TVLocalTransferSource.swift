#if os(tvOS)
import Foundation
import PrimuseKit

enum TVLocalTransferSource {
    private static let idKey = "tv_received_music_source_v1"
    private static let scanLock = NSLock()

    static func markPendingScan(in defaults: UserDefaults = .standard) {
        scanLock.withLock {
            defaults.set(UUID().uuidString, forKey: "tv.transfer.scanRevision")
            defaults.set(true, forKey: "tv.transfer.pendingScan")
        }
    }

    static func scanRevision(in defaults: UserDefaults) -> String? {
        scanLock.withLock { defaults.string(forKey: "tv.transfer.scanRevision") }
    }

    static func clearPendingScan(ifRevisionMatches revision: String?, in defaults: UserDefaults) {
        scanLock.withLock {
            guard defaults.string(forKey: "tv.transfer.scanRevision") == revision else { return }
            defaults.removeObject(forKey: "tv.transfer.pendingScan")
            defaults.removeObject(forKey: "tv.transfer.scanRevision")
        }
    }

    static var sourceID: String {
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    static var root: URL {
        FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("Primuse/ReceivedMusic", isDirectory: true)
    }

    static func isOwned(_ source: MusicSource) -> Bool {
        guard source.type == .local, source.id == UserDefaults.standard.string(forKey: idKey),
              let base = source.basePath else { return false }
        let stored = URL(fileURLWithPath: base).standardizedFileURL.path
        let current = root.standardizedFileURL.path
        if stored == current { return true }
        func container(_ path: String) -> String? {
            let normalized = path.hasPrefix("/private/var/") ? String(path.dropFirst(8)) : path
            let parts = normalized.split(separator: "/").map(String.init)
            guard parts.count >= 8,
                  Array(parts.suffix(4)) == ["Library", "Caches", "Primuse", "ReceivedMusic"],
                  UUID(uuidString: parts[parts.count - 5]) != nil,
                  Array(parts.suffix(8).prefix(3)) == ["Containers", "Data", "Application"] else { return nil }
            return parts.dropLast(5).joined(separator: "/")
        }
        return container(stored) != nil && container(stored) == container(current)
    }

    static func url(for path: String) throws -> URL {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        if relative.isEmpty { return root }
        guard parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw WiFiTransferError.invalidPath
        }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw WiFiTransferError.invalidPath
            }
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(canonicalRoot + "/") else {
            throw WiFiTransferError.invalidPath
        }
        return url
    }
}

actor TVLocalDirectoryLister: TVDirectoryLister {
    func list(_ path: String) async throws -> [TVDirEntry] {
        try Task.checkCancellation()
        let directory = try TVLocalTransferSource.url(for: path)
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]).compactMap { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { return nil }
                let relative = (path == "/" || path.isEmpty ? "/" : path + "/") + url.lastPathComponent
                return TVDirEntry(name: url.lastPathComponent, isDir: values.isDirectory == true,
                                  size: Int64(values.fileSize ?? 0), path: relative, parentPath: path,
                                  modifiedDate: values.contentModificationDate)
            }
    }
}

actor TVLocalByteRangeReader: ByteRangeReader {
    private let path: String
    private var handle: FileHandle?

    init(filePath: String) { path = filePath }

    func contentLength() async throws -> Int64 {
        try Task.checkCancellation()
        let url = try TVLocalTransferSource.url(for: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WiFiTransferError.notFound }
        return Int64(values.fileSize ?? 0)
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, length > 0, length <= 32 * 1024 * 1024 else { throw WiFiTransferError.invalidRequest }
        let url = try TVLocalTransferSource.url(for: path)
        if handle == nil { handle = try FileHandle(forReadingFrom: url) }
        guard let handle else { throw WiFiTransferError.notFound }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: Int(length)) ?? Data()
    }

    func close() async { try? handle?.close(); handle = nil }
    deinit { try? handle?.close() }
}
#endif
