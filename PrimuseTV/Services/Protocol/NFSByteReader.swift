#if os(tvOS)
import Foundation
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

/// tvOS 直连 NFS:用 libnfs(`LibNFSSession`)按 byte range(NFS_READ RPC)读远端文件,喂给
/// `TVProtocolResourceLoader`,不经 iPhone 中继。
///
/// song.filePath 是 iOS 扫描时编码的选择路径 `nfs::<b64url(export)>::<b64url(relative)>`,
/// 这里复刻其解码(NFSSelectionPathCodec 在 iOS target,不复用,只搬这段纯字符串逻辑)。
actor NFSByteReader: ByteRangeReader {
    private let session: LibNFSSession
    private let exportPath: String
    private let relativePath: String

    private var connected = false
    private var cachedSize: Int64?
    private let operationGate = TVProtocolOperationGate()

    /// 单个 NFS 请求的等待上限,避免某个文件读挂死拖死扫描/播放。
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
        let host = (source.host ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        // NFSv3 经 rpcbind 查 MOUNT 和 NFS 端口,不用源里填的端口。
        session = LibNFSSession(
            configuration: .init(host: host, port: nil, version: .v3, timeout: Self.requestStallTimeout),
            label: "tv.reader"
        )
        exportPath = scoped.exportPath
        relativePath = scoped.relativePath
    }

    /// Must only be called while `operationGate` is held.
    private func ensureWhileLocked() async throws {
        if connected { return }
        try await session.mount(exportPath: exportPath)
        try Task.checkCancellation()
        connected = true
    }

    /// 请求出错后下一次重新挂载,不沿用可能已经断开的连接。
    private func resetAfterFailure(_ error: Error) async {
        guard !(error is CancellationError) else { return }
        connected = false
        await session.unmount()
    }

    func contentLength() async throws -> Int64 {
        if let cachedSize { return cachedSize }
        return try await withSerializedOperation {
            if let cachedSize { return cachedSize }
            let total: Int64
            do {
                try await ensureWhileLocked()
                total = Int64(clamping: try await session.fileSize(relativePath))
            } catch {
                await resetAfterFailure(error)
                throw error
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
            let cancellation = TVNFSReadCancellation()
            let data: Data
            do {
                try await ensureWhileLocked()
                // 取消时读完当前这一块就停,请求本身照常收尾。
                data = try await withTaskCancellationHandler {
                    try await session.read(
                        relativePath,
                        offset: UInt64(offset),
                        length: Int(clamping: end - offset),
                        shouldContinue: { cancellation.shouldContinue }
                    )
                } onCancel: {
                    cancellation.cancel()
                }
            } catch {
                await resetAfterFailure(error)
                throw error
            }
            try Task.checkCancellation()
            return data
        }
    }

    func close() async {
        await operationGate.acquire()
        if connected {
            await session.unmount()
        }
        connected = false
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
