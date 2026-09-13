#if os(tvOS)
import Foundation
import PrimuseKit

/// 把 iOS / macOS 那套 `MusicSourceConnector` 直接搬到电视端当目录列举器用。
///
/// 电视端此前给每种协议单独写一份 lister,和手机端的实现容易走偏。凡是纯
/// Foundation 的连接器(SFTP / UPnP / 各家云盘)都没有必要重写:它们的
/// `listFiles(at:)` 返回的 `RemoteFileItem` 字段与 `TVDirEntry` 一一对应,
/// 包成一层就能复用,连 providerID、revision 这些扫描去重要用的字段都不会丢。
actor TVConnectorLister: TVDirectoryLister {
    private let connector: any MusicSourceConnector
    private let rootPath: String
    private let stableIdentity: Bool
    private let prepare: (@Sendable () async -> Void)?
    private var prepared = false
    private var connected = false

    /// - Parameters:
    ///   - rootPath: 该连接器认的根。路径传空或 "/" 时用它替换。
    ///   - usesStableProviderSongIdentity: 云盘用 item ID 定位文件,重命名后
    ///     路径会变但 ID 不变,扫描器据此判断能否用 providerID 做歌曲身份。
    ///   - prepare: 首次列举前跑一次的准备动作(云盘用来把电视端的凭据补进
    ///     连接器要读的那份钥匙串)。`makeLister` 是同步的,所以只能推迟到这里。
    init(
        connector: any MusicSourceConnector,
        rootPath: String = "/",
        usesStableProviderSongIdentity: Bool = false,
        prepare: (@Sendable () async -> Void)? = nil
    ) {
        self.connector = connector
        self.rootPath = rootPath
        self.stableIdentity = usesStableProviderSongIdentity
        self.prepare = prepare
    }

    nonisolated var usesStableProviderSongIdentity: Bool { stableIdentity }

    func list(_ path: String) async throws -> [TVDirEntry] {
        if !prepared {
            await prepare?()
            prepared = true
        }
        if !connected {
            try await connector.connect()
            connected = true
        }
        let target = (path.isEmpty || path == "/") ? rootPath : path
        let items = try await connector.listFiles(at: target)
        return items.map {
            TVDirEntry(
                name: $0.name,
                isDir: $0.isDirectory,
                size: $0.size,
                path: $0.path,
                providerID: $0.providerID,
                parentPath: $0.parentPath ?? target,
                modifiedDate: $0.modifiedDate,
                revision: $0.revision
            )
        }
    }
}

/// 用连接器的 `fetchRange` 给 `TVProtocolResourceLoader` 供字节。
///
/// AVPlayer 在第一次 range 请求前就要知道 contentLength,而 `MusicSourceConnector`
/// 没有单文件 stat 方法。优先用扫描时记下的文件大小,只有它缺失(老库、刚从手机
/// 同步过来还没补全)时才退回列一次父目录 —— 大目录每次起播都 LIST 一遍太贵。
actor TVConnectorByteReader: ByteRangeReader {
    private let connector: any MusicSourceConnector
    private let filePath: String
    private let prepare: (@Sendable () async -> Void)?
    private var prepared = false
    private var cachedLength: Int64?
    private var connected = false
    private let gate = TVProtocolOperationGate()

    init(
        connector: any MusicSourceConnector,
        filePath: String,
        knownLength: Int64? = nil,
        prepare: (@Sendable () async -> Void)? = nil
    ) {
        self.connector = connector
        self.filePath = filePath
        self.prepare = prepare
        if let knownLength, knownLength > 0 { self.cachedLength = knownLength }
    }

    private func ensureConnected() async throws {
        if !prepared {
            await prepare?()
            prepared = true
        }
        guard !connected else { return }
        try await connector.connect()
        connected = true
    }

    func contentLength() async throws -> Int64 {
        if let cachedLength { return cachedLength }
        return try await withSerializedOperation {
            if let cachedLength = self.cachedLength { return cachedLength }
            try await self.ensureConnected()
            let parent = TVConnectorPathPolicy.parentDirectory(of: self.filePath)
            let name = TVConnectorPathPolicy.lastComponent(of: self.filePath)
            let items = try await self.connector.listFiles(at: parent)
            guard let match = items.first(where: {
                $0.path == self.filePath || ($0.name == name && !$0.isDirectory)
            }) else {
                throw TVScanError.connectFailed
            }
            self.cachedLength = match.size
            return match.size
        }
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
        try await withSerializedOperation {
            try await self.ensureConnected()
            return try await self.connector.fetchRange(
                path: self.filePath, offset: offset, length: length
            )
        }
    }

    func close() async {
        await gate.acquire()
        await connector.disconnect()
        connected = false
        await gate.release()
    }

    /// 连接器内部包着一个可变会话(SFTP 是一条 SSH 通道),读操作必须整体串行,
    /// 只把属性放进 actor 不够 —— `await` 期间 actor 会重入。
    private func withSerializedOperation<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }
}

/// 远端路径的父目录 / 末段拆分。远端一律是 POSIX 分隔符,不能用 `URL` 去算
/// (`URL` 会把 `#`、`?` 当成片段分隔符,云盘的文件名里这两个字符都是合法的)。
enum TVConnectorPathPolicy {
    static func parentDirectory(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "/" }
        let parent = String(path[path.startIndex..<index])
        return parent.isEmpty ? "/" : parent
    }

    static func lastComponent(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: index)...])
    }
}
#endif
