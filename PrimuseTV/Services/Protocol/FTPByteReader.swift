#if os(tvOS)
import Foundation
import PrimuseKit

extension FTPSessionConfiguration {
    /// 电视端从音乐源设置拼出 FTP 会话配置(与手机端同一套客户端)。
    init?(tvSource source: MusicSource, credential: SourceCredential?) {
        let host = (source.host ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        self.init(
            host: host,
            port: source.port.flatMap { $0 > 0 ? $0 : nil },
            username: credential?.username ?? source.username ?? "",
            password: credential?.password ?? "",
            encryption: source.ftpEncryption ?? .none,
            dataConnectionMode: source.ftpDataConnectionMode ?? .automatic,
            log: { plog("🎬 \($0)") }
        )
    }
}

/// tvOS 直连 FTP/FTPS:按 byte range(REST+RETR)读远端文件,喂给 `TVProtocolResourceLoader`,
/// 不经 iPhone 中继。读完一段,控制连接留在池里给下一段用。
actor FTPByteReader: ByteRangeReader {
    private let pool: FTPSessionPool
    private let filePath: String
    private var cachedSize: Int64?

    init?(source: MusicSource, filePath: String, credential: SourceCredential?) {
        guard let configuration = FTPSessionConfiguration(tvSource: source, credential: credential) else {
            return nil
        }
        pool = FTPSessionPool(configuration: configuration, maximumSessions: 1)
        self.filePath = FTPPathPolicy(basePath: source.basePath)
            .providerPath(forSourcePath: filePath)
    }

    func contentLength() async throws -> Int64 {
        if let cachedSize { return cachedSize }
        let path = filePath
        let size = try await pool.withSession { session -> Int64 in
            if let reported = try await session.size(path), reported > 0 {
                return reported
            }
            let name = (path as NSString).lastPathComponent
            let parent = (path as NSString).deletingLastPathComponent
            let entries = try await session.list(parent.isEmpty ? "/" : parent)
            guard let entry = entries.first(where: { !$0.isDirectory && $0.name == name }),
                  entry.size > 0 else {
                throw FTPReaderError.invalidContentLength
            }
            return entry.size
        }
        try Task.checkCancellation()
        cachedSize = size
        return size
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
        guard SafeByteRange.exclusiveEnd(offset: offset, length: length) != nil else {
            return Data()
        }
        let count = Int(min(max(0, length), Int64(Int.max)))
        guard count > 0 else { return Data() }
        let path = filePath
        let data = try await pool.withSession { session in
            try await session.retrieve(path, offset: offset, length: count)
        }
        try Task.checkCancellation()
        return data
    }

    func close() async {
        await pool.shutdown()
    }

    private enum FTPReaderError: Error {
        case invalidContentLength
    }
}

/// 电视端列 FTP 目录(扫描与选目录用)。
actor TVFTPLister: TVDirectoryLister {
    private let pool: FTPSessionPool
    private let basePath: String

    init?(source: MusicSource, credential: SourceCredential?) {
        guard let configuration = FTPSessionConfiguration(tvSource: source, credential: credential) else {
            return nil
        }
        pool = FTPSessionPool(configuration: configuration, maximumSessions: 2)
        basePath = (source.basePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func list(_ path: String) async throws -> [TVDirEntry] {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let relative = (normalized.isEmpty || normalized == "/") ? "/" : normalized
        let providerPath = TVFilesProviderPathPolicy.providerPath(base: basePath, path: relative)
        let base = basePath
        let entries = try await pool.withSession { session in
            try await session.list(providerPath)
        }
        return entries
            .filter { !$0.name.hasPrefix(".") }
            .map { entry in
                TVDirEntry(
                    name: entry.name,
                    isDir: entry.isDirectory,
                    size: entry.size,
                    path: TVFilesProviderPathPolicy.sourcePath(
                        base: base,
                        providerPath: (providerPath as NSString).appendingPathComponent(entry.name)
                    ),
                    parentPath: relative,
                    modifiedDate: entry.modifiedDate
                )
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}
#endif
