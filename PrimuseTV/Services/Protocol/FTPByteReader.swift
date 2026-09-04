#if os(tvOS)
import FilesProvider
import Foundation
import PrimuseKit

private final class TVFTPFileProvider: FTPFileProvider {
    override func attributesOfItem(
        path: String,
        completionHandler: @escaping (FileObject?, (any Error)?) -> Void
    ) {
        // FilesProvider 0.26 can call the RFC 3659 completion both before and
        // after its LIST fallback. Force the dependency's single-callback path.
        super.attributesOfItem(
            path: path,
            rfc3659enabled: FTPTransferPolicy.usesRFC3659ForAttributes,
            completionHandler: completionHandler
        )
    }
}

private final class TVFTPRequestBox<Value: Sendable>: @unchecked Sendable {
    private let race = CancellableResultRace<Value>()
    private let cancellations = OneShotCancellationRegistry()

    var isResolved: Bool { race.isResolved }

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        race.install(continuation)
    }

    func updateProgress(_ progress: Progress?) {
        guard let progress else { return }
        _ = cancellations.register { progress.cancel() }
    }

    func resolve(_ result: Result<Value, any Error>) {
        guard race.resolve(result) else { return }
        _ = cancellations.cancelAll()
    }

    func cancel() {
        _ = cancellations.cancelAll()
        _ = race.cancel()
    }
}

/// tvOS 直连 FTP/FTPS:用 FilesProvider 的 FTPFileProvider 按 byte range(REST+RETR)读远端
/// 文件,喂给 `TVProtocolResourceLoader`,不经 iPhone 中继。FTPFileProvider 回调式且非 Sendable,
/// 用 actor 隔离 + continuation 包装(与 iOS `FTPSource` 同法)。
actor FTPByteReader: ByteRangeReader {
    private let provider: FTPFileProvider
    private let filePath: String
    private var cachedSize: Int64?
    private let operationGate = TVProtocolOperationGate()

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
        // FilesProvider applies `ftpPath` more than once in several operations.
        // Keep its base URL rooted and pass one absolute operation path.
        comps.path = FTPPathPolicy.providerBaseURLPath
        guard let baseURL = comps.url else { return nil }

        // FTP 匿名约定:空用户名 → anonymous + 任意口令。
        let rawUser = cred?.username ?? source.username ?? ""
        let user = rawUser.isEmpty ? "anonymous" : rawUser
        let pass = (rawUser.isEmpty && (cred?.password ?? "").isEmpty) ? "anonymous@primuse" : (cred?.password ?? "")
        let credential = URLCredential(user: user, password: pass, persistence: .forSession)

        guard let p = TVFTPFileProvider(baseURL: baseURL, credential: credential) else { return nil }
        p.dispatch_queue = DispatchQueue(
            label: "com.welape.yuanyin.tv.ftp.callbacks.\(UUID().uuidString)"
        )
        p.securedDataConnection = encryption != .none
        provider = p
        self.filePath = FTPPathPolicy(basePath: source.basePath)
            .providerPath(forSourcePath: filePath)
    }

    func contentLength() async throws -> Int64 {
        if let cachedSize { return cachedSize }
        return try await withSerializedOperation {
            if let cachedSize { return cachedSize }
            let path = filePath
            let p = provider
            let size: Int64 = try await performRequest { request in
                p.attributesOfItem(path: path) { object, error in
                    if let error {
                        request.resolve(.failure(error))
                    } else if let object, object.size > 0 {
                        request.resolve(.success(object.size))
                    } else {
                        request.resolve(.failure(FTPReaderError.invalidContentLength))
                    }
                }
            }
            try Task.checkCancellation()
            cachedSize = size
            return size
        }
    }

    func read(offset: Int64, length: Int64) async throws -> Data {
        guard SafeByteRange.exclusiveEnd(offset: offset, length: length) != nil else {
            return Data()
        }
        let len = Int(min(max(0, length), Int64(Int.max)))
        guard len > 0 else { return Data() }
        return try await withSerializedOperation {
            let path = filePath
            let p = provider
            let data: Data = try await performRequest { request in
                let progress = p.contents(path: path, offset: offset, length: len) { data, error in
                    if let error {
                        request.resolve(.failure(error))
                    } else {
                        request.resolve(.success(data ?? Data()))
                    }
                }
                request.updateProgress(progress)
            }
            try Task.checkCancellation()
            return data
        }
    }

    func close() async {
        await operationGate.acquire()
        provider.session.invalidateAndCancel()
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

    private func performRequest<Value: Sendable>(
        start: (TVFTPRequestBox<Value>) -> Void
    ) async throws -> Value {
        let request = TVFTPRequestBox<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                guard !request.isResolved else { return }
                start(request)
            }
        } onCancel: {
            request.cancel()
        }
    }

    private enum FTPReaderError: Error {
        case invalidContentLength
    }
}
#endif
