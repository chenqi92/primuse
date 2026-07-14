#if os(tvOS)
import AMSMB2
import Foundation
import PrimuseKit

/// tvOS 直连 SMB:用 AMSMB2(libsmb2)按 byte range 读远端文件,喂给 `TVProtocolResourceLoader`。
/// 不经 iPhone 中继。一首歌一个实例(持有自己的 share 连接 + 解析好的相对路径)。
actor SMBByteReader: ByteRangeReader {
    private let serverURL: URL
    private let credential: URLCredential
    private let shareName: String
    private let relativePath: String

    private var manager: SMB2Manager?
    private var connected = false
    private var cachedSize: Int64?

    /// 从同步过来的 `MusicSource` + 这首歌的 filePath + 凭据构造。host/share 缺失时返回 nil。
    init?(source: MusicSource, filePath: String, credential cred: SourceCredential?) {
        let host = (source.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let port = source.port ?? 445
        // IPv6 字面量加方括号;IPv4 / 主机名直用(libsmb2 的 IPv6 拼接 bug 在局域网 IPv4 不触发)。
        let hostPart = (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        guard let url = URL(string: "smb://\(hostPart):\(port)") else { return nil }
        serverURL = url

        let user = (cred?.username ?? source.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = (cred?.password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isGuest = user.isEmpty && pass.isEmpty
        credential = URLCredential(user: isGuest ? "guest" : user, password: pass, persistence: .forSession)

        let (share, rel) = Self.resolve(share: source.shareName ?? "", path: filePath)
        guard !share.isEmpty else { return nil }
        shareName = share
        relativePath = rel
    }

    private func ensure() async throws -> SMB2Manager {
        if let manager, connected { return manager }
        let m = manager ?? SMB2Manager(url: serverURL, credential: credential)
        guard let m else { throw SMBReaderError.invalidConfig }
        m.timeout = 20   // 单次操作上限,避免某个文件读挂死拖死扫描/播放
        manager = m
        try await m.connectShare(name: shareName)
        connected = true
        return m
    }

    func contentLength() async throws -> Int64 {
        if let cachedSize { return cachedSize }
        let m = try await ensure()
        let attrs = try await m.attributesOfItem(atPath: relativePath)
        let size = (attrs[.fileSizeKey] as? Int64) ?? (attrs[.fileSizeKey] as? Int).map(Int64.init) ?? 0
        cachedSize = size
        return size
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
        let m = try await ensure()
        let end = offset + max(0, length)
        guard offset < end else { return Data() }
        return try await m.contents(atPath: relativePath, range: UInt64(offset)..<UInt64(end))
    }

    enum SMBReaderError: Error { case invalidConfig }

    /// 把(配置的 share + 这首歌的 filePath)解析成(share 名, share 内相对路径)。
    /// 对齐 iOS `SMBSource.resolve`:配置了 share 则 filePath 视为 share 内路径(可能带 /share 前缀);
    /// 未配置 share 则 filePath 第一段即 share 名。
    static func resolve(share rawShare: String, path rawPath: String) -> (share: String, relative: String) {
        let slashes = CharacterSet(charactersIn: "/")
        let share = rawShare.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: slashes)
        let p = normalize(rawPath)
        if !share.isEmpty {
            let root = "/" + share
            if p == root { return (share, "/") }
            if p.hasPrefix(root + "/") { return (share, String(p.dropFirst(root.count))) }
            return (share, p)
        }
        let comps = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = comps.first else { return ("", "/") }
        let rest = comps.dropFirst()
        return (first, rest.isEmpty ? "/" : "/" + rest.joined(separator: "/"))
    }

    static func normalize(_ path: String) -> String {
        let comps = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
    }
}
#endif
