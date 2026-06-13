#if os(tvOS)
import Foundation
import NFSKit
import PrimuseKit

/// tvOS 直连 NFS:用 NFSKit(libnfs)按 byte range(NFS_READ RPC)读远端文件,喂给
/// `TVProtocolResourceLoader`,不经 iPhone 中继。NFSKit 是回调式 API、NFSClient 非 Sendable,
/// 故用 actor 隔离 + continuation 包装(与 iOS `NFSSource` 同法)。
///
/// song.filePath 是 iOS 扫描时编码的选择路径 `nfs::<b64url(export)>::<b64url(relative)>`,
/// 这里复刻其解码(NFSSelectionPathCodec 在 iOS target,不复用,只搬这段纯字符串逻辑)。
actor NFSByteReader: ByteRangeReader {
    private let url: URL
    private let exportPath: String
    private let relativePath: String

    private var client: NFSClient?
    private var connected = false
    private var cachedSize: Int64?

    init?(source: MusicSource, filePath: String) {
        guard let parsed = Self.parseSelection(filePath) else { return nil }
        let host = (source.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let urlHost = (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        var comps = URLComponents()
        comps.scheme = "nfs"
        comps.host = urlHost
        if let p = source.port, p > 0 { comps.port = p }
        guard let u = comps.url else { return nil }
        url = u
        exportPath = parsed.export
        relativePath = parsed.relative
    }

    private func ensure() async throws -> NFSClient {
        if let client, connected { return client }
        let c: NFSClient
        if let existing = client {
            c = existing
        } else {
            guard let made = try NFSClient(url: url) else { throw NFSReaderError.invalidConfig }
            client = made
            c = made
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.connect(export: exportPath) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        connected = true
        return c
    }

    func contentLength() async throws -> Int64 {
        if let cachedSize { return cachedSize }
        let c = try await ensure()
        let rel = relativePath
        let total: Int64 = try await withCheckedThrowingContinuation { cont in
            c.attributesOfItem(atPath: rel) { result in
                switch result {
                case .success(let attrs):
                    let size = (attrs[.fileSizeKey] as? Int64)
                        ?? (attrs[.fileSizeKey] as? Int).map(Int64.init) ?? 0
                    cont.resume(returning: size)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
        cachedSize = total
        return total
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
        let c = try await ensure()
        let end = offset + max(0, length)
        guard offset < end else { return Data() }
        let rel = relativePath
        return try await withCheckedThrowingContinuation { cont in
            c.contents(atPath: rel, range: offset..<end, progress: nil) { result in
                switch result {
                case .success(let data): cont.resume(returning: data)
                case .failure(let error): cont.resume(throwing: error)
                }
            }
        }
    }

    enum NFSReaderError: Error { case invalidConfig }

    /// 解码 `nfs::<b64url(export)>::<b64url(relative)>`(对齐 iOS NFSSelectionPathCodec)。
    static func parseSelection(_ path: String) -> (export: String, relative: String)? {
        guard path.hasPrefix("nfs::") else { return nil }
        let payload = String(path.dropFirst("nfs::".count))
        guard let sep = payload.range(of: "::") else { return nil }
        let exTok = String(payload[..<sep.lowerBound])
        let relTok = String(payload[sep.upperBound...])
        guard let ex = b64urlDecode(exTok), let rel = b64urlDecode(relTok) else { return nil }
        let export = ex.hasPrefix("/") ? ex : "/" + ex
        let relative = rel.isEmpty ? "/" : (rel.hasPrefix("/") ? rel : "/" + rel)
        return (export, relative)
    }

    private static func b64urlDecode(_ value: String) -> String? {
        var b64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad != 0 { b64 += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
