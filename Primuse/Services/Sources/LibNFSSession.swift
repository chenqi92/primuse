import Foundation
import LibNFS

/// 一个挂载好的 libnfs 上下文,iPhone、Mac(`NFSClientBackend`)和 Apple TV
/// (`NFSByteReader`、`TVNFSLister`)共用。
///
/// 所有调用都在自己的串行队列上用 libnfs 的同步接口完成。同步接口在请求结束
/// (成功、按 `timeout` 超时或连接出错)之前不会返回,出错时也会先把排队的请求
/// 全部回调掉,所以不会有请求留在 libnfs 里、回调进已经返回的调用。代价是任务
/// 取消打断不了正在进行的请求,只能等它按超时结束。挂载例外:它要先建 TCP 连接,
/// 改用异步接口自己计时(`mountWithDeadline`)。
///
/// 目录项只给原始字段:路径和修改时间怎么算由调用方决定,v3 一直沿用 NFSKit
/// 的算法,改了会让已扫描的歌被当成换了文件。
final class LibNFSSession: @unchecked Sendable {
    enum Version: Sendable {
        case v3
        case v4
    }

    struct Configuration: Sendable {
        /// 不带方括号的主机名或地址。
        var host: String
        /// 只给 NFSv4 用:NFSv3 的 MOUNT 和 NFS 端口都经 rpcbind 查。
        var port: Int?
        var version: Version
        /// 单个 RPC 请求的超时。
        var timeout: TimeInterval
    }

    struct DirectoryEntry: Sendable {
        let name: String
        /// NF3REG、NF3DIR 等。
        let type: UInt32
        let mode: UInt32
        let size: UInt64
        let mtimeSeconds: Int
        let mtimeMicroseconds: Int
        let mtimeNanoseconds: UInt32
        let ctimeSeconds: Int
        let ctimeNanoseconds: UInt32

        var isNFS3Directory: Bool { type == UInt32(NF3DIR.rawValue) }
        var isModeDirectory: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR) }
    }

    /// NFSKit 每次最多读、写 1 MB(服务器上限更小时按服务器的)。
    private static let maximumTransferSize = 1_048_576

    let configuration: Configuration
    private let queue: DispatchQueue
    private var context: OpaquePointer?
    private var mountedExportPath: String?

    init(configuration: Configuration, label: String) {
        self.configuration = configuration
        self.queue = DispatchQueue(label: "primuse.libnfs.\(label)")
    }

    deinit {
        // 卸载要等服务器回话,放到自己的队列上做,不卡住最后放手的那个线程。
        guard let context else { return }
        let owned = ContextBox(context)
        queue.async {
            _ = nfs_umount(owned.context)
            nfs_destroy_context(owned.context)
        }
    }

    // MARK: - Mount

    func mount(exportPath: String) async throws {
        try await perform {
            if self.mountedExportPath == exportPath, self.context != nil { return }
            self.destroyContext()

            guard let context = nfs_init_context() else {
                throw SourceError.connectionFailed("Unable to create NFS context")
            }
            nfs_set_timeout(context, Self.milliseconds(self.configuration.timeout))
            if self.configuration.version == .v4 {
                if let port = self.configuration.port, port > 0 {
                    nfs_set_nfsport(context, Int32(clamping: port))
                }
                let status = nfs_set_version(context, Int32(NFS_V4))
                guard status == 0 else {
                    let error = self.makeError(context: context, status: status, operation: "set version")
                    nfs_destroy_context(context)
                    throw error
                }
            }

            do {
                try self.mountWithDeadline(context: context, exportPath: exportPath)
            } catch let abandoned as AbandonedContext {
                throw abandoned.error
            } catch {
                nfs_destroy_context(context)
                throw error
            }

            if self.configuration.version == .v3 {
                // 与 NFSKit 一样:挂载后用导出根目录属主的 uid/gid 访问,不是所有人
                // 都能读的共享也读得到。读不到根目录就保持默认身份。
                var attributes = nfs_stat_64()
                if nfs_stat64(context, "/", &attributes) == 0 {
                    nfs_set_uid(context, Int32(truncatingIfNeeded: attributes.nfs_uid))
                    nfs_set_gid(context, Int32(truncatingIfNeeded: attributes.nfs_gid))
                }
            }

            self.context = context
            self.mountedExportPath = exportPath
        }
    }

    func unmount() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.destroyContext()
                continuation.resume()
            }
        }
    }

    /// MOUNT 协议列出的导出目录,按服务器给的顺序。
    static func exports(host: String, timeout: TimeInterval) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            exportListQueue.async {
                guard let list = host.withCString({
                    mount_getexports_timeout($0, milliseconds(timeout))
                }) else {
                    continuation.resume(throwing: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EIO),
                        userInfo: [NSLocalizedDescriptionKey: "NFS export list unavailable from \(host)"]
                    ))
                    return
                }
                defer { mount_free_export_list(list) }
                var exports: [String] = []
                var node: UnsafeMutablePointer<exportnode>? = list
                while let current = node {
                    if let directory = current.pointee.ex_dir {
                        exports.append(String(cString: directory))
                    }
                    node = current.pointee.ex_next
                }
                // libnfs 把列表倒着串起来,翻回服务器给的顺序。
                continuation.resume(returning: exports.reversed())
            }
        }
    }

    private static let exportListQueue = DispatchQueue(label: "primuse.libnfs.exports")

    // MARK: - Files

    func listDirectory(_ path: String) async throws -> [DirectoryEntry] {
        try await perform {
            let context = try self.requireContext()
            var directory: OpaquePointer?
            let status = path.withCString { nfs_opendir(context, $0, &directory) }
            guard status == 0, let directory else {
                throw self.makeError(context: context, status: status, operation: "open directory")
            }
            defer { nfs_closedir(context, directory) }

            var entries: [DirectoryEntry] = []
            while let pointer = nfs_readdir(context, directory) {
                let entry = pointer.pointee
                guard let namePointer = entry.name else { continue }
                let name = String(cString: namePointer)
                guard name != ".", name != ".." else { continue }
                entries.append(DirectoryEntry(
                    name: name,
                    type: entry.type,
                    mode: entry.mode,
                    size: entry.size,
                    mtimeSeconds: Int(entry.mtime.tv_sec),
                    mtimeMicroseconds: Int(entry.mtime.tv_usec),
                    mtimeNanoseconds: entry.mtime_nsec,
                    ctimeSeconds: Int(entry.ctime.tv_sec),
                    ctimeNanoseconds: entry.ctime_nsec
                ))
            }
            return entries
        }
    }

    func fileSize(_ path: String) async throws -> UInt64 {
        try await perform {
            let context = try self.requireContext()
            var attributes = nfs_stat_64()
            let status = path.withCString { nfs_stat64(context, $0, &attributes) }
            guard status == 0 else {
                throw self.makeError(context: context, status: status, operation: "stat")
            }
            return attributes.nfs_size
        }
    }

    /// 读 `[offset, offset + length)`,超出文件末尾的部分不读。每读完一块问一次
    /// `shouldContinue`,返回 false 就带着已读到的数据停下。
    func read(
        _ path: String,
        offset: UInt64,
        length: Int,
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Data {
        guard length > 0 else { return Data() }
        return try await perform {
            let context = try self.requireContext()
            let file = try self.open(path, flags: O_RDONLY, context: context, operation: "open file")
            defer { _ = nfs_close(context, file) }

            var attributes = nfs_stat_64()
            let statStatus = nfs_fstat64(context, file, &attributes)
            guard statStatus == 0 else {
                throw self.makeError(context: context, status: statStatus, operation: "stat")
            }
            guard attributes.nfs_size > offset else { return Data() }
            let available = attributes.nfs_size - offset
            let total = Int(min(UInt64(length), available, UInt64(Int.max)))
            let chunkSize = self.transferSize(context: context, maximum: nfs_get_readmax(context))

            var data = Data(count: total)
            var received = 0
            while received < total {
                let requested = min(chunkSize, total - received)
                let status = data.withUnsafeMutableBytes { buffer in
                    nfs_pread(
                        context,
                        file,
                        buffer.baseAddress?.advanced(by: received),
                        requested,
                        offset + UInt64(received)
                    )
                }
                guard status >= 0 else {
                    throw self.makeError(context: context, status: status, operation: "read")
                }
                guard status > 0 else { break }
                received += Int(status)
                guard shouldContinue() else { break }
            }
            data.count = received
            return data
        }
    }

    func download(_ path: String, to localURL: URL) async throws {
        try await perform {
            let context = try self.requireContext()
            let file = try self.open(path, flags: O_RDONLY, context: context, operation: "open file")
            defer { _ = nfs_close(context, file) }

            _ = FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: localURL)
            defer { try? output.close() }

            let chunkSize = self.transferSize(context: context, maximum: nfs_get_readmax(context))
            var buffer = Data(count: chunkSize)
            var offset: UInt64 = 0
            while true {
                let status = buffer.withUnsafeMutableBytes { bytes in
                    nfs_pread(context, file, bytes.baseAddress, chunkSize, offset)
                }
                guard status >= 0 else {
                    throw self.makeError(context: context, status: status, operation: "download")
                }
                guard status > 0 else { break }
                try output.write(contentsOf: buffer.prefix(Int(status)))
                offset += UInt64(status)
            }
        }
    }

    /// `createFlags` 为 nil 时用 `nfs_creat(mode)` 新建(NFSv4 一直这样);否则用
    /// `nfs_open(flags)`(NFSv3 沿用 NFSKit 的 O_RDWR|O_CREAT|O_EXCL)。
    func upload(from localURL: URL, to path: String, createFlags: Int32?, mode: Int32 = 0o600) async throws {
        try await perform {
            let context = try self.requireContext()
            let input = try FileHandle(forReadingFrom: localURL)
            defer { try? input.close() }

            let file: OpaquePointer
            if let createFlags {
                file = try self.open(path, flags: createFlags, context: context, operation: "create upload file")
            } else {
                var handle: OpaquePointer?
                let status = path.withCString { nfs_creat(context, $0, mode, &handle) }
                guard status == 0, let handle else {
                    throw self.makeError(context: context, status: status, operation: "create upload file")
                }
                file = handle
            }
            defer { _ = nfs_close(context, file) }

            let chunkSize = self.transferSize(context: context, maximum: nfs_get_writemax(context))
            var offset: UInt64 = 0
            while true {
                let chunk = try input.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                let written = chunk.withUnsafeBytes { bytes in
                    nfs_pwrite(context, file, bytes.baseAddress, chunk.count, offset)
                }
                guard written == chunk.count else {
                    throw self.makeError(context: context, status: min(written, -Int32(EIO)), operation: "upload")
                }
                offset += UInt64(written)
            }
        }
    }

    func remove(_ path: String) async throws {
        try await perform {
            let context = try self.requireContext()
            let status = path.withCString { nfs_unlink(context, $0) }
            guard status == 0 else {
                throw self.makeError(context: context, status: status, operation: "delete")
            }
        }
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await perform {
            let context = try self.requireContext()
            let status = path.withCString { source in
                newPath.withCString { nfs_rename(context, source, $0) }
            }
            guard status == 0 else {
                throw self.makeError(context: context, status: status, operation: "rename")
            }
        }
    }

    // MARK: - Helpers

    private final class MountWait: @unchecked Sendable {
        var finished = false
        var status: Int32 = 0
        var message: String?
    }

    /// 上下文已经在这里销毁了,调用方不要再销毁一次。
    private struct AbandonedContext: Error {
        let error: NSError
    }

    /// 同步的 `nfs_mount` 会一直等到 TCP 建连失败为止(系统的建连超时,iPhone 上
    /// 七十多秒),`nfs_set_timeout` 管不到这一段。这里用异步接口自己等,到
    /// `timeout` 还没挂上就销毁上下文:销毁时 libnfs 把排队的请求连同回调一起了结,
    /// 回调写的是这里还持有着的 `MountWait`,不会写进已经返回的调用。
    private func mountWithDeadline(context: OpaquePointer, exportPath: String) throws {
        let wait = MountWait()
        let token = Unmanaged.passRetained(wait)
        defer { token.release() }

        let queued = configuration.host.withCString { host in
            exportPath.withCString { export in
                nfs_mount_async(context, host, export, { status, _, data, privateData in
                    guard let privateData else { return }
                    let wait = Unmanaged<MountWait>.fromOpaque(privateData).takeUnretainedValue()
                    wait.status = status
                    if status < 0, let data {
                        wait.message = String(cString: data.assumingMemoryBound(to: CChar.self))
                    }
                    wait.finished = true
                }, token.toOpaque())
            }
        }
        guard queued == 0 else {
            throw makeError(context: context, status: queued, operation: "mount")
        }

        let deadline = Date().addingTimeInterval(configuration.timeout)
        while !wait.finished {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                let error = makeError(
                    context: context,
                    status: -Int32(ETIMEDOUT),
                    operation: "mount",
                    detail: "no answer within \(Int(configuration.timeout))s"
                )
                nfs_destroy_context(context)
                throw AbandonedContext(error: error)
            }
            var descriptor = pollfd(
                fd: nfs_get_fd(context),
                events: Int16(truncatingIfNeeded: nfs_which_events(context)),
                revents: 0
            )
            let ready = poll(&descriptor, 1, Int32(min(remaining, 0.25) * 1000) + 1)
            if ready < 0, errno == EINTR { continue }
            let revents = ready < 0 ? -1 : Int32(descriptor.revents)
            if nfs_service(context, revents) < 0 {
                let error = makeError(context: context, status: -Int32(EIO), operation: "mount")
                nfs_destroy_context(context)
                throw AbandonedContext(error: error)
            }
        }
        guard wait.status == 0 else {
            throw makeError(context: context, status: wait.status, operation: "mount", detail: wait.message)
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func requireContext() throws -> OpaquePointer {
        guard let context else {
            throw SourceError.connectionFailed("NFS share is not connected")
        }
        return context
    }

    private func open(
        _ path: String,
        flags: Int32,
        context: OpaquePointer,
        operation: String
    ) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let status = path.withCString { nfs_open(context, $0, flags, &handle) }
        guard status == 0, let handle else {
            throw makeError(context: context, status: status, operation: operation)
        }
        return handle
    }

    private func transferSize(context: OpaquePointer, maximum: some BinaryInteger) -> Int {
        let serverMaximum = Int(clamping: maximum)
        return serverMaximum > 0 ? min(serverMaximum, Self.maximumTransferSize) : Self.maximumTransferSize
    }

    private func destroyContext() {
        guard let context else { return }
        _ = nfs_umount(context)
        nfs_destroy_context(context)
        self.context = nil
        mountedExportPath = nil
    }

    private func makeError(
        context: OpaquePointer,
        status: Int32,
        operation: String,
        detail explicitDetail: String? = nil
    ) -> NSError {
        let detail = explicitDetail ?? nfs_get_error(context).map { String(cString: $0) } ?? ""
        let label = configuration.version == .v4 ? "NFSv4" : "NFSv3"
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: -Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(label) \(operation) failed (\(status)): \(detail)"]
        )
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int32 {
        Int32(clamping: Int((interval * 1000).rounded()))
    }

    private struct ContextBox: @unchecked Sendable {
        let context: OpaquePointer
        init(_ context: OpaquePointer) { self.context = context }
    }
}
