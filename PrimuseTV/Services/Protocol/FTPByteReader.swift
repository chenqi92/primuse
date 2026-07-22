#if os(tvOS)
import FilesProvider
import Foundation
import PrimuseKit

/// tvOS 直连 FTP/FTPS:用 FilesProvider 的 FTPFileProvider 按 byte range(REST+RETR)读远端
/// 文件,喂给 `TVProtocolResourceLoader`,不经 iPhone 中继。FTPFileProvider 回调式且非 Sendable,
/// 用 actor 隔离 + continuation 包装(与 iOS `FTPSource` 同法)。
actor FTPByteReader: ByteRangeReader {
    private let provider: FTPFileProvider
    private let filePath: String
    private var cachedSize: Int64?

    init?(source: MusicSource, filePath: String, credential cred: SourceCredential?) {
        let host = (source.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let encryption = source.ftpEncryption ?? .none
        var comps = URLComponents()
        comps.scheme = switch encryption {
        case .none: "ftp"
        case .implicitTLS: "ftps"
        case .explicitTLS: "ftpes"
        }
        comps.host = host
        comps.port = source.port ?? 21
        let base = (source.basePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        comps.path = base.isEmpty ? "/" : (base.hasPrefix("/") ? base : "/" + base)
        guard let baseURL = comps.url else { return nil }

        // FTP 匿名约定:空用户名 → anonymous + 任意口令。
        let rawUser = cred?.username ?? source.username ?? ""
        let user = rawUser.isEmpty ? "anonymous" : rawUser
        let pass = (rawUser.isEmpty && (cred?.password ?? "").isEmpty) ? "anonymous@primuse" : (cred?.password ?? "")
        let credential = URLCredential(user: user, password: pass, persistence: .forSession)

        guard let p = FTPFileProvider(baseURL: baseURL, credential: credential) else { return nil }
        p.securedDataConnection = encryption != .none
        provider = p
        self.filePath = filePath
    }

    func contentLength() async throws -> Int64 {
        if let cachedSize { return cachedSize }
        let path = filePath
        let p = provider
        let size: Int64 = try await withCheckedThrowingContinuation { cont in
            p.attributesOfItem(path: path) { obj, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: obj?.size ?? 0) }
            }
        }
        cachedSize = size
        return size
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
        guard SafeByteRange.exclusiveEnd(offset: offset, length: length) != nil else {
            return Data()
        }
        let path = filePath
        let p = provider
        let len = Int(min(max(0, length), Int64(Int.max)))
        guard len > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { cont in
            _ = p.contents(path: path, offset: offset, length: len) { data, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: data ?? Data()) }
            }
        }
    }
}
#endif
