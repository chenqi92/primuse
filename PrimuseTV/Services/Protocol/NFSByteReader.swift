#if os(tvOS)
import Foundation
import NFSKit
import PrimuseKit

private final class TVNFSReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }
}

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

    private var session: RemoteSessionGuard<NFSClient>?
    private var connected = false
    private var cachedSize: Int64?
    private let operationGate = TVProtocolOperationGate()

    /// 单次操作的等待上限,避免某个文件读挂死拖死扫描/播放。由 `RemoteSessionGuard`
    /// 在外面计时,NFSKit 本身不放弃请求(见 `RemoteRequestDeadline`)。
    static let requestStallTimeout: TimeInterval = 20

    init?(source: MusicSource, filePath: String) {
        guard let parsed = Self.parseSelection(filePath) else { return nil }
        guard let scoped = NFSSelectionScopePolicy.resolve(
            exportPath: parsed.export,
            relativePath: parsed.relative,
            configuredExportPath: source.basePath
        ) else { return nil }
        let requestedVersion = source.nfsVersion ?? .auto
        guard requestedVersion.canStartWithV3OnlyBackend else { return nil }
        let host = (source.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let urlHost = (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        var comps = URLComponents()
        comps.scheme = "nfs"
        comps.host = urlHost
        // NFSKit's v3 wrapper appends URL ports to the hostname before libnfs
        // performs rpcbind lookup. Leave it unset so rpcbind discovers both
        // MOUNT and NFS service ports instead of resolving "host:2049".
        guard let u = comps.url else { return nil }
        url = u
        exportPath = scoped.exportPath
        relativePath = scoped.relativePath
    }

    deinit {
        // 释放仍挂载着的客户端时 NFSKit 会在放手的那个线程上同步卸载。没退役的
        // 客户端上没有在途请求,卸载沿用原来 20 秒的上限;退役的由别处持有。
        session?.ifNotRetired { $0.timeout = Self.requestStallTimeout }
    }

    /// 包一层 `RemoteSessionGuard`:请求可能还挂在 libnfs 里时把客户端永久停用
    /// (不卸载、不释放),见 `NFSContextDisposalPolicy`。
    static func guarded(_ client: NFSClient) -> RemoteSessionGuard<NFSClient> {
        client.timeout = RemoteRequestDeadline.libraryTimeout
        return RemoteSessionGuard(client, mayHaveAbandonedRequest: { error in
            let nsError = error as NSError
            return NFSContextDisposalPolicy.mayHaveAbandonedRequest(
                errorDomain: nsError.domain,
                errorCode: nsError.code
            )
        })
    }

    /// Must only be called while `operationGate` is held. NFSKit owns one
    /// libnfs context and actor methods can otherwise re-enter while awaiting a
    /// callback from that context.
    private func ensureWhileLocked() async throws -> RemoteSessionGuard<NFSClient> {
        if let session, connected, !session.isRetired { return session }
        let s: RemoteSessionGuard<NFSClient>
        if let existing = session, !existing.isRetired {
            s = existing
        } else {
            // 上一个客户端退役了(或还没有):换一个新的重新挂载。
            guard let made = try NFSClient(url: url) else { throw NFSReaderError.invalidConfig }
            s = Self.guarded(made)
            session = s
            connected = false
        }
        let exportPath = exportPath
        try await s.request(stallTimeout: Self.requestStallTimeout) { client, _ in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                client.connect(export: exportPath) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        }
        try Task.checkCancellation()
        connected = true
        return s
    }

    func contentLength() async throws -> Int64 {
        if let cachedSize { return cachedSize }
        return try await withSerializedOperation {
            if let cachedSize { return cachedSize }
            let s = try await ensureWhileLocked()
            let rel = relativePath
            let total: Int64 = try await s.request(stallTimeout: Self.requestStallTimeout) { client, _ in
                try await withCheckedThrowingContinuation { cont in
                    client.attributesOfItem(atPath: rel) { result in
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
            }
            try Task.checkCancellation()
            guard total > 0 else { throw NFSReaderError.invalidContentLength(total) }
            cachedSize = total
            return total
        }
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
        guard let end = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
            return Data()
        }
        return try await withSerializedOperation {
            let s = try await ensureWhileLocked()
            let rel = relativePath
            let cancellation = TVNFSReadCancellation()
            let data: Data = try await withTaskCancellationHandler {
                // 取消时让 NFSKit 读完当前这一块就停,请求本身照常收尾;
                // 每读完一块都算进度,给计时续命。
                try await s.request(stallTimeout: Self.requestStallTimeout) { client, activity in
                    try await withCheckedThrowingContinuation { cont in
                        client.contents(
                            atPath: rel,
                            range: offset..<end,
                            progress: { _, _ in
                                activity.noteProgress()
                                return cancellation.shouldContinue
                            }
                        ) { result in
                            switch result {
                            case .success(let data): cont.resume(returning: data)
                            case .failure(let error): cont.resume(throwing: error)
                            }
                        }
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
            return data
        }
    }

    func close() async {
        await operationGate.acquire()
        if let session, connected, !session.isRetired {
            // 卸载没在时限内结束时客户端会被退役,而不是在这里释放。
            let exportPath = exportPath
            _ = try? await session.request(stallTimeout: Self.requestStallTimeout) { client, _ in
                await withCheckedContinuation { continuation in
                    client.disconnect(export: exportPath, gracefully: false) { _ in
                        continuation.resume()
                    }
                }
            }
        }
        connected = false
        session = nil
        await operationGate.release()
    }

    private func withSerializedOperation<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            await operationGate.release()
            return result
        } catch {
            await operationGate.release()
            throw error
        }
    }

    enum NFSReaderError: Error {
        case invalidConfig
        case invalidContentLength(Int64)
    }

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
