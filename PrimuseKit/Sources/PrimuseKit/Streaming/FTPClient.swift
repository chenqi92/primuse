#if canImport(Darwin)
import Darwin
import Foundation
import Security

// Primuse 自己的 FTP 客户端:一条控制连接一个 `FTPSession`,`FTPSessionPool` 复用已登录
// 的会话。数据连接支持被动(EPSV / PASV)与主动(PORT / EPRT);FTPS 隐式与显式 TLS,
// 数据连接复用控制连接的 TLS 会话(vsftpd 默认要求)。
//
// 收发用 CFStream:显式 TLS 要在已连上的连接上中途开启,主动模式要把服务器连进来的
// socket 包成流,这两件事只有它都能做。所有流挂在同一条后台线程的 RunLoop 上。

// MARK: - Errors

public enum FTPClientError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 服务器回了失败码。`command` 是出错的那条命令(不含参数)。
    case replyFailure(command: String, code: Int, message: String)
    /// 等某一步超时:连接、回复、数据连接、数据传输。
    case timedOut(String)
    case connectionClosed
    case connectionFailed(String)
    case dataConnectionFailed(String)
    case activeModeUnavailable(String)
    case invalidReply(String)
    case cancelled

    public var replyCode: Int? {
        if case .replyFailure(_, let code, _) = self { return code }
        return nil
    }

    /// 写进日志、错误详情的技术信息(界面文案由调用方另给)。
    public var description: String {
        switch self {
        case .replyFailure(let command, let code, let message):
            return "FTP \(command) \(code) \(message)"
        case .timedOut(let stage):
            return "FTP timed out: \(stage)"
        case .connectionClosed:
            return "FTP connection closed"
        case .connectionFailed(let detail):
            return "FTP connection failed: \(detail)"
        case .dataConnectionFailed(let detail):
            return "FTP data connection failed: \(detail)"
        case .activeModeUnavailable(let detail):
            return "FTP active mode unavailable: \(detail)"
        case .invalidReply(let detail):
            return "FTP invalid reply: \(detail)"
        case .cancelled:
            return "FTP request cancelled"
        }
    }

    /// 登录被拒(530/532)。
    public var isAuthenticationFailure: Bool {
        replyCode == 530 || replyCode == 532
    }

    /// 文件或目录不存在、没有权限(550/553)。
    public var isPathFailure: Bool {
        replyCode == 550 || replyCode == 553
    }

    /// 数据连接没能建立起来:多半是数据连接方式不对(被动地址连不上、主动模式下服务器
    /// 连不进来)。
    public var isDataConnectionFailure: Bool {
        switch self {
        case .dataConnectionFailed, .activeModeUnavailable: return true
        case .timedOut(let stage): return stage.hasPrefix("data")
        case .replyFailure(_, let code, _): return code == 425
        default: return false
        }
    }
}

// MARK: - Configuration

public struct FTPSessionConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var encryption: FTPEncryption
    public var dataConnectionMode: FTPDataConnectionMode
    public var connectTimeout: TimeInterval
    public var replyTimeout: TimeInterval
    public var dataTimeout: TimeInterval
    /// 诊断日志(连接、数据连接方式、退回与替换)。不记口令和命令原文。
    public var log: (@Sendable (String) -> Void)?

    /// 用户名留空按匿名登录:`anonymous` 加任意口令。
    public init(
        host: String,
        port: Int?,
        username: String,
        password: String,
        encryption: FTPEncryption,
        dataConnectionMode: FTPDataConnectionMode,
        connectTimeout: TimeInterval = 15,
        replyTimeout: TimeInterval = 30,
        dataTimeout: TimeInterval = 30,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.host = host
        self.port = port ?? (encryption == .implicitTLS ? 990 : 21)
        let anonymous = username.trimmingCharacters(in: .whitespaces).isEmpty
        self.username = anonymous ? "anonymous" : username
        self.password = anonymous && password.isEmpty ? "anonymous@primuse" : password
        self.encryption = encryption
        self.dataConnectionMode = dataConnectionMode
        self.connectTimeout = connectTimeout
        self.replyTimeout = replyTimeout
        self.dataTimeout = dataTimeout
        self.log = log
    }
}

/// 同一台服务器上学到的事,所有会话共用:不支持 EPSV / MLSD、文件名编码。
final class FTPServerTraits: @unchecked Sendable {
    private let lock = NSLock()
    private var _rejectsEPSV = false
    private var _rejectsMLSD = false
    private var _textEncoding: FTPTextEncoding = .utf8

    var rejectsEPSV: Bool {
        get { lock.withLock { _rejectsEPSV } }
        set { lock.withLock { _rejectsEPSV = newValue } }
    }

    var rejectsMLSD: Bool {
        get { lock.withLock { _rejectsMLSD } }
        set { lock.withLock { _rejectsMLSD = newValue } }
    }

    var textEncoding: FTPTextEncoding {
        get { lock.withLock { _textEncoding } }
        set { lock.withLock { _textEncoding = newValue } }
    }
}

// MARK: - Stream thread

/// 所有 FTP 流都挂在这条线程的 RunLoop 上收事件;流的状态只在这条线程上读写。
final class FTPStreamThread: Thread, @unchecked Sendable {
    static let shared: FTPStreamThread = {
        let thread = FTPStreamThread()
        thread.name = "Primuse FTP streams"
        thread.qualityOfService = .userInitiated
        thread.start()
        thread.ready.wait()
        return thread
    }()

    private let ready = DispatchSemaphore(value: 0)
    private(set) var runLoop: CFRunLoop?
    private(set) var foundationRunLoop: RunLoop?

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        foundationRunLoop = RunLoop.current
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while true {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
    }

    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}

// MARK: - Stream connection

struct FTPSocketAddress: @unchecked Sendable {
    var storage: sockaddr_storage
    var host: String

    var family: Int32 { Int32(storage.ss_family) }
}

/// 一条 TCP 连接(控制或数据),异步读写,每一步都有超时。
final class FTPStreamConnection: NSObject, StreamDelegate, @unchecked Sendable {
    private let input: InputStream
    private let output: OutputStream
    private let thread = FTPStreamThread.shared

    // 以下状态只在流线程上访问。
    private var buffer = Data()
    private var reachedEOF = false
    private var failure: FTPClientError?
    private var inputOpened = false
    private var outputOpened = false
    private var canWrite = false
    private var isClosed = false
    private var waiterToken = 0
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var readWaiter: CheckedContinuation<Data, Error>?
    private var writeWaiter: (data: Data, offset: Int, continuation: CheckedContinuation<Void, Error>)?
    private var tlsCloseWaiter: CheckedContinuation<Void, Error>?

    private init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
        super.init()
    }

    static func connect(
        host: String,
        port: Int,
        tls: FTPTLSOptions?,
        timeout: TimeInterval
    ) async throws -> FTPStreamConnection {
        var inputStream: InputStream?
        var outputStream: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inputStream, outputStream: &outputStream)
        guard let inputStream, let outputStream else {
            throw FTPClientError.connectionFailed("cannot create streams to \(host):\(port)")
        }
        let connection = FTPStreamConnection(input: inputStream, output: outputStream)
        try await connection.open(tls: tls, timeout: timeout, stage: "connect \(host):\(port)")
        return connection
    }

    /// 主动模式下服务器连进来的 socket。
    static func adopt(socket: Int32, tls: FTPTLSOptions?, timeout: TimeInterval) async throws -> FTPStreamConnection {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, socket, &readStream, &writeStream)
        guard let read = readStream?.takeRetainedValue(), let write = writeStream?.takeRetainedValue() else {
            Darwin.close(socket)
            throw FTPClientError.dataConnectionFailed("cannot wrap accepted socket")
        }
        let input: InputStream = read
        let output: OutputStream = write
        input.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        output.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        let connection = FTPStreamConnection(input: input, output: output)
        try await connection.open(tls: tls, timeout: timeout, stage: "data accept")
        return connection
    }

    private func open(tls: FTPTLSOptions?, timeout: TimeInterval, stage: String) async throws {
        try await waitWithTimeout(timeout, stage: stage) { continuation, token in
            self.openWaiter = continuation
            self.input.delegate = self
            self.output.delegate = self
            if let runLoop = self.thread.foundationRunLoop {
                self.input.schedule(in: runLoop, forMode: .default)
                self.output.schedule(in: runLoop, forMode: .default)
            }
            if let tls { self.applyTLS(tls) }
            self.input.open()
            self.output.open()
            _ = token
        }
    }

    /// 在已连上的连接上开启 TLS(显式 FTPS 的 `AUTH TLS` 之后、PROT P 的数据连接)。
    func startTLS(_ options: FTPTLSOptions) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            thread.perform {
                self.applyTLS(options)
                continuation.resume()
            }
        }
    }

    private func applyTLS(_ options: FTPTLSOptions) {
        let settings: [String: Any] = [kCFStreamSSLPeerName as String: options.peerName]
        let settingsKey = Stream.PropertyKey(kCFStreamPropertySSLSettings as String)
        input.setProperty(settings, forKey: settingsKey)
        output.setProperty(settings, forKey: settingsKey)
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
        if let peerID = options.sessionPeerID, !peerID.isEmpty, let context = sslContext {
            peerID.withUnsafeBytes { bytes in
                _ = SSLSetPeerID(context, bytes.baseAddress, peerID.count)
            }
        }
    }

    private var sslContext: SSLContext? {
        guard let value = input.property(forKey: Stream.PropertyKey(kCFStreamPropertySSLContext as String)) else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (value as! SSLContext)
    }

    /// 控制连接的 TLS 会话标识,数据连接拿它复用同一个会话。
    func tlsSessionPeerID() async -> Data? {
        await withCheckedContinuation { continuation in
            thread.perform {
                guard let context = self.sslContext else {
                    continuation.resume(returning: nil)
                    return
                }
                var peerID: UnsafeRawPointer?
                var length = 0
                guard SSLGetPeerID(context, &peerID, &length) == errSecSuccess,
                      let peerID, length > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Data(bytes: peerID, count: length))
            }
        }
    }

    /// 本端地址(主动模式在这个地址上开监听端口)。
    func localAddress() async -> FTPSocketAddress? {
        await withCheckedContinuation { continuation in
            thread.perform {
                continuation.resume(returning: self.socketAddress(local: true))
            }
        }
    }

    private func socketAddress(local: Bool) -> FTPSocketAddress? {
        guard let handleData = input.property(
            forKey: Stream.PropertyKey(rawValue: CFStreamPropertyKey.socketNativeHandle.rawValue as String)
        ) as? Data, handleData.count >= MemoryLayout<CFSocketNativeHandle>.size else { return nil }
        let socket = handleData.withUnsafeBytes { $0.load(as: CFSocketNativeHandle.self) }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                local ? getsockname(socket, $0, &length) : getpeername(socket, $0, &length)
            }
        }
        guard result == 0, let host = FTPSocketAddress.numericHost(of: storage) else { return nil }
        return FTPSocketAddress(storage: storage, host: host)
    }

    /// 读到至少一个字节;连接正常关闭时返回空数据。
    func read(timeout: TimeInterval, stage: String) async throws -> Data {
        try await waitWithTimeout(timeout, stage: stage) { continuation, _ in
            if !self.buffer.isEmpty {
                let data = self.buffer
                self.buffer = Data()
                continuation.resume(returning: data)
            } else if let failure = self.failure {
                continuation.resume(throwing: failure)
            } else if self.reachedEOF {
                continuation.resume(returning: Data())
            } else {
                self.readWaiter = continuation
            }
        }
    }

    func write(_ data: Data, timeout: TimeInterval, stage: String) async throws {
        guard !data.isEmpty else { return }
        try await waitWithTimeout(timeout, stage: stage) { (continuation: CheckedContinuation<Void, Error>, _) in
            if let failure = self.failure {
                continuation.resume(throwing: failure)
                return
            }
            self.writeWaiter = (data, 0, continuation)
            self.continueWriting()
        }
    }

    func close() {
        thread.perform {
            self.shutDown(with: .cancelled)
        }
    }

    /// STOR 的数据通道必须先送出 TLS close_notify，严格校验关闭握手的服务器才会确认上传。
    func finishTLSWriting(timeout: TimeInterval) async throws {
        try await waitWithTimeout(timeout, stage: "TLS data shutdown") { continuation, _ in
            self.tlsCloseWaiter = continuation
            self.continueTLSClosing()
        }
    }

    private func continueTLSClosing() {
        guard let waiter = tlsCloseWaiter else { return }
        guard let context = sslContext else {
            shutDown(with: .connectionFailed("missing TLS context during data shutdown"))
            return
        }
        let status = SSLClose(context)
        if status == errSSLWouldBlock {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.01) {
                self.thread.perform { self.continueTLSClosing() }
            }
        } else if status == errSecSuccess || status == errSSLClosedGraceful {
            tlsCloseWaiter = nil
            waiterToken += 1
            waiter.resume()
        } else {
            shutDown(with: .connectionFailed("TLS data shutdown failed (\(status))"))
        }
    }

    // MARK: Waiting

    private func waitWithTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        stage: String,
        register: @escaping (CheckedContinuation<T, Error>, Int) -> Void
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                thread.perform {
                    if self.isClosed {
                        continuation.resume(throwing: self.failure ?? .connectionClosed)
                        return
                    }
                    self.waiterToken += 1
                    let token = self.waiterToken
                    register(continuation, token)
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                        self.thread.perform {
                            guard self.waiterToken == token else { return }
                            self.timeOut(stage: stage)
                        }
                    }
                }
            }
        } onCancel: {
            self.close()
        }
    }

    private func timeOut(stage: String) {
        guard openWaiter != nil || readWaiter != nil || writeWaiter != nil || tlsCloseWaiter != nil else { return }
        shutDown(with: .timedOut(stage))
    }

    private func shutDown(with error: FTPClientError) {
        if failure == nil { failure = error }
        let reason = failure ?? error
        if let openWaiter {
            self.openWaiter = nil
            openWaiter.resume(throwing: reason)
        }
        if let readWaiter {
            self.readWaiter = nil
            readWaiter.resume(throwing: reason)
        }
        if let writeWaiter {
            self.writeWaiter = nil
            writeWaiter.continuation.resume(throwing: reason)
        }
        if let tlsCloseWaiter {
            self.tlsCloseWaiter = nil
            tlsCloseWaiter.resume(throwing: reason)
        }
        guard !isClosed else { return }
        isClosed = true
        input.delegate = nil
        output.delegate = nil
        input.close()
        output.close()
        if let runLoop = thread.foundationRunLoop {
            input.remove(from: runLoop, forMode: .default)
            output.remove(from: runLoop, forMode: .default)
        }
    }

    // MARK: Stream events (stream thread)

    func stream(_ stream: Stream, handle event: Stream.Event) {
        if event.contains(.openCompleted) {
            if stream === input { inputOpened = true } else { outputOpened = true }
            completeOpenIfReady()
        }
        if event.contains(.hasBytesAvailable), stream === input {
            inputOpened = true
            drainInput()
            completeOpenIfReady()
        }
        if event.contains(.hasSpaceAvailable), stream === output {
            outputOpened = true
            canWrite = true
            completeOpenIfReady()
            continueWriting()
        }
        if event.contains(.endEncountered), stream === input {
            drainInput()
            reachedEOF = true
            deliverRead()
        }
        if event.contains(.errorOccurred) {
            let detail = stream.streamError?.localizedDescription ?? "stream error"
            shutDown(with: openWaiter != nil ? .connectionFailed(detail) : .connectionFailed(detail))
        }
    }

    private func completeOpenIfReady() {
        guard inputOpened, outputOpened, let openWaiter else { return }
        self.openWaiter = nil
        waiterToken += 1
        openWaiter.resume()
    }

    private func drainInput() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while input.hasBytesAvailable {
            let count = input.read(&chunk, maxLength: chunk.count)
            if count > 0 {
                buffer.append(chunk, count: count)
            } else if count == 0 {
                reachedEOF = true
                break
            } else {
                let detail = input.streamError?.localizedDescription ?? "read failed"
                shutDown(with: .connectionFailed(detail))
                return
            }
        }
        deliverRead()
    }

    private func deliverRead() {
        guard let readWaiter else { return }
        if !buffer.isEmpty {
            self.readWaiter = nil
            waiterToken += 1
            let data = buffer
            buffer = Data()
            readWaiter.resume(returning: data)
        } else if reachedEOF {
            self.readWaiter = nil
            waiterToken += 1
            readWaiter.resume(returning: Data())
        }
    }

    private func continueWriting() {
        guard var pending = writeWaiter else { return }
        while pending.offset < pending.data.count, output.hasSpaceAvailable {
            let written = pending.data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base + pending.offset, maxLength: pending.data.count - pending.offset)
            }
            if written < 0 {
                let detail = output.streamError?.localizedDescription ?? "write failed"
                writeWaiter = pending
                shutDown(with: .connectionFailed(detail))
                return
            }
            if written == 0 { break }
            pending.offset += written
        }
        if pending.offset >= pending.data.count {
            writeWaiter = nil
            waiterToken += 1
            pending.continuation.resume()
        } else {
            writeWaiter = pending
        }
    }
}

struct FTPTLSOptions: Sendable {
    var peerName: String
    var sessionPeerID: Data?
}

extension FTPSocketAddress {
    static func numericHost(of storage: sockaddr_storage) -> String? {
        var storage = storage
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(storage.ss_family == sa_family_t(AF_INET6)
            ? MemoryLayout<sockaddr_in6>.size
            : MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard result == 0 else { return nil }
        let host = String(decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // IPv4 映射到 IPv6 的地址(::ffff:a.b.c.d)按 IPv4 写进 PORT。
        if host.hasPrefix("::ffff:"), FTPActiveCommand.ipv4Octets(String(host.dropFirst(7))) != nil {
            return String(host.dropFirst(7))
        }
        return host
    }
}

// MARK: - Active mode listener

/// 主动模式:在控制连接所在的本机地址上开一个端口,等服务器连进来。
final class FTPActiveListener: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: Int32
    let port: Int
    let host: String

    private init(socket: Int32, port: Int, host: String) {
        self.socket = socket
        self.port = port
        self.host = host
    }

    static func open(on local: FTPSocketAddress) throws -> FTPActiveListener {
        let family = local.family
        let fd = Darwin.socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw FTPClientError.activeModeUnavailable("socket \(errno)") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var storage = local.storage
        let length: socklen_t
        if family == AF_INET6 {
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port = 0 }
            }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port = 0 }
            }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        let bound = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw FTPClientError.activeModeUnavailable("bind/listen \(code)")
        }
        var assigned = sockaddr_storage()
        var assignedLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &assignedLength) }
        }
        let port: Int
        if family == AF_INET6 {
            port = withUnsafePointer(to: &assigned) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
            }
        } else {
            port = withUnsafePointer(to: &assigned) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
            }
        }
        guard port > 0 else {
            Darwin.close(fd)
            throw FTPClientError.activeModeUnavailable("no port assigned")
        }
        return FTPActiveListener(socket: fd, port: port, host: local.host)
    }

    /// 等服务器连进来,返回连进来的 socket。监听端口随即关闭。
    func accept(timeout: TimeInterval) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let deadline = Date().addingTimeInterval(timeout)
                    while true {
                        guard let fd = self.currentSocket() else {
                            continuation.resume(throwing: FTPClientError.cancelled)
                            return
                        }
                        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        let ready = poll(&descriptor, 1, 200)
                        if ready > 0 {
                            let accepted = Darwin.accept(fd, nil, nil)
                            self.close()
                            guard accepted >= 0 else {
                                continuation.resume(throwing: FTPClientError.dataConnectionFailed("accept \(errno)"))
                                return
                            }
                            var on: Int32 = 1
                            setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                            continuation.resume(returning: accepted)
                            return
                        }
                        if ready < 0 && errno != EINTR {
                            self.close()
                            continuation.resume(throwing: FTPClientError.dataConnectionFailed("poll \(errno)"))
                            return
                        }
                        if Date() >= deadline {
                            self.close()
                            continuation.resume(throwing: FTPClientError.timedOut("data accept"))
                            return
                        }
                    }
                }
            }
        } onCancel: {
            self.close()
        }
    }

    private func currentSocket() -> Int32? {
        lock.withLock { socket >= 0 ? socket : nil }
    }

    func close() {
        lock.withLock {
            if socket >= 0 {
                Darwin.close(socket)
                socket = -1
            }
        }
    }
}

// MARK: - Session

/// 一条已登录的控制连接。同一时间只跑一条命令:由 `FTPSessionPool` 保证独占。
public actor FTPSession {
    public let configuration: FTPSessionConfiguration
    let traits: FTPServerTraits
    private var control: FTPStreamConnection?
    private var parser = FTPReplyParser()
    private var queuedReplies: [FTPReply] = []
    private var features = FTPFeatures()
    private var tlsPeerID: Data?
    /// 控制连接出过问题(超时、读到半截回复)就不再复用。
    public private(set) var isReusable = false

    init(configuration: FTPSessionConfiguration, traits: FTPServerTraits) {
        self.configuration = configuration
        self.traits = traits
    }

    public init(configuration: FTPSessionConfiguration) {
        self.init(configuration: configuration, traits: FTPServerTraits())
    }

    private var usesTLS: Bool { configuration.encryption != .none }

    private func log(_ message: @autoclosure () -> String) {
        configuration.log?("FTP \(configuration.host):\(configuration.port) \(message())")
    }
    private var tlsOptions: FTPTLSOptions { FTPTLSOptions(peerName: configuration.host, sessionPeerID: nil) }
    private var dataTLSOptions: FTPTLSOptions { FTPTLSOptions(peerName: configuration.host, sessionPeerID: tlsPeerID) }

    // MARK: Login

    public func open() async throws {
        do {
            let connection = try await FTPStreamConnection.connect(
                host: configuration.host,
                port: configuration.port,
                tls: configuration.encryption == .implicitTLS ? tlsOptions : nil,
                timeout: configuration.connectTimeout
            )
            control = connection
            parser = FTPReplyParser(encoding: traits.textEncoding)
            var greeting = try await readReply(stage: "greeting")
            while greeting.code == 120 { greeting = try await readReply(stage: "greeting") }
            guard greeting.code == 220 else { throw failure("CONNECT", greeting) }

            if configuration.encryption == .explicitTLS {
                let auth = try await command("AUTH", "TLS")
                guard auth.code == 234 else { throw failure("AUTH TLS", auth) }
                await connection.startTLS(tlsOptions)
            }

            let user = try await command("USER", configuration.username)
            if user.code == 331 || user.code == 332 {
                let pass = try await command("PASS", configuration.password, redacted: true)
                guard pass.code == 230 || pass.code == 202 else { throw failure("PASS", pass) }
            } else if user.code != 230 {
                throw failure("USER", user)
            }

            if usesTLS {
                tlsPeerID = await connection.tlsSessionPeerID()
                _ = try await command("PBSZ", "0")
                let prot = try await command("PROT", "P")
                guard prot.isCompletion else { throw failure("PROT", prot) }
            }

            let feat = try await command("FEAT")
            features = FTPFeatures(reply: feat)
            if features.supportsUTF8 {
                _ = try await command("OPTS", "UTF8 ON")
                traits.textEncoding = .utf8
                parser.encoding = .utf8
            }
            let type = try await command("TYPE", "I")
            guard type.isCompletion else { throw failure("TYPE", type) }
            isReusable = true
            log("logged in tls=\(configuration.encryption.rawValue) mode=\(configuration.dataConnectionMode.rawValue) features=\(features.names.sorted().joined(separator: ","))")
        } catch {
            log("login failed: \(error)")
            shutDown()
            throw error
        }
    }

    /// 发 QUIT 再断开;连接已经出过问题就直接断开。
    public func close() async {
        if isReusable, let control {
            if let data = try? FTPCommand.data("QUIT", encoding: .utf8) {
                try? await control.write(data, timeout: 3, stage: "QUIT")
            }
        }
        shutDown()
    }

    private func shutDown() {
        isReusable = false
        control?.close()
        control = nil
    }

    // MARK: Commands

    public func list(_ path: String) async throws -> [FTPListEntry] {
        if !traits.rejectsMLSD {
            do {
                let data = try await readTransfer("MLSD", path)
                return FTPListParser.parseMLSD(decodeListing(data))
            } catch let error as FTPClientError where Self.isUnsupportedCommand(error) {
                traits.rejectsMLSD = true
                log("server rejects MLSD, using LIST")
            }
        }
        let data = try await readTransfer("LIST", path)
        return FTPListParser.parseLIST(decodeListing(data))
    }

    /// `SIZE`(二进制模式下的字节数);服务器不支持时返回 nil。
    public func size(_ path: String) async throws -> Int64? {
        let reply = try await command("SIZE", path)
        if reply.code == 213 { return Int64(reply.text.trimmingCharacters(in: .whitespaces)) }
        // 421 是连接被服务器关了,不是不支持 SIZE:抛出去,池子才会换新会话重试。
        if reply.code == 550 || reply.code == 421 { throw failure("SIZE", reply) }
        return nil
    }

    /// 从 `offset` 起读 `length` 字节(到文件尾为止)。读够就断开数据连接。
    public func retrieve(_ path: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        var collected = Data()
        collected.reserveCapacity(min(length, 8 << 20))
        try await transfer("RETR", path, restartAt: offset, abortsEarly: true) { data in
            while collected.count < length {
                let chunk = try await data.read(timeout: self.configuration.dataTimeout, stage: "data read")
                if chunk.isEmpty { return true }
                let needed = length - collected.count
                collected.append(chunk.prefix(needed))
                if chunk.count >= needed { return false }
            }
            return false
        }
        return collected
    }

    /// 整个文件(或从 `offset` 起)写到本地文件,返回写入的字节数。
    @discardableResult
    public func retrieve(_ path: String, offset: Int64 = 0, to fileURL: URL) async throws -> Int64 {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        var written: Int64 = 0
        try await transfer("RETR", path, restartAt: offset, abortsEarly: false) { data in
            while true {
                let chunk = try await data.read(timeout: self.configuration.dataTimeout, stage: "data read")
                if chunk.isEmpty { return true }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
        }
        return written
    }

    public func store(_ path: String, data payload: Data) async throws {
        try await transfer("STOR", path, restartAt: 0, abortsEarly: false) { data in
            var offset = 0
            while offset < payload.count {
                let end = min(payload.count, offset + 256 * 1024)
                try await data.write(payload.subdata(in: offset..<end), timeout: self.configuration.dataTimeout, stage: "data write")
                offset = end
            }
            return true
        }
    }

    public func store(_ path: String, fileURL: URL) async throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try await transfer("STOR", path, restartAt: 0, abortsEarly: false) { data in
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try await data.write(chunk, timeout: self.configuration.dataTimeout, stage: "data write")
            }
            return true
        }
    }

    public func delete(_ path: String) async throws {
        let reply = try await command("DELE", path)
        guard reply.isCompletion else { throw failure("DELE", reply) }
    }

    public func rename(_ source: String, to destination: String) async throws {
        let from = try await command("RNFR", source)
        guard from.code == 350 else { throw failure("RNFR", from) }
        let to = try await command("RNTO", destination)
        guard to.isCompletion else { throw failure("RNTO", to) }
    }

    // MARK: Transfers

    private func readTransfer(_ verb: String, _ path: String) async throws -> Data {
        var collected = Data()
        try await transfer(verb, path, restartAt: 0, abortsEarly: false) { data in
            while true {
                let chunk = try await data.read(timeout: self.configuration.dataTimeout, stage: "data read")
                if chunk.isEmpty { return true }
                collected.append(chunk)
            }
        }
        return collected
    }

    /// 一次数据传输。`body` 返回 true 表示数据连接读到了尾(或写完了),false 表示提前
    /// 收手(只要一段),这时断开数据连接,服务器回 426/451 也照样算完成。
    private func transfer(
        _ verb: String,
        _ path: String,
        restartAt offset: Int64,
        abortsEarly: Bool,
        body: (FTPStreamConnection) async throws -> Bool
    ) async throws {
        guard isReusable else { throw FTPClientError.connectionClosed }
        let channel = try await prepareDataChannel()
        var dataConnection: FTPStreamConnection?
        do {
            if case .passive(let connection) = channel { dataConnection = connection }
            if offset > 0 {
                // REST 要紧挨着 RETR(RFC 3659 §5):夹在中间的 PASV / EPSV / PORT 会让有的
                // 服务器丢掉续传位置,从文件头发起,读到的就不是要的那一段。
                let rest = try await command("REST", String(offset))
                guard rest.code == 350 else { throw failure("REST", rest) }
            }
            let start = try await command(verb, path)
            guard start.isPreliminary else {
                dataConnection?.close()
                channel.close()
                if start.isCompletion, verb == "LIST" || verb == "MLSD" || verb == "NLST" {
                    return // 空目录:有的服务器不开数据连接,直接回 226。
                }
                throw failure(verb, start)
            }
            if case .active(let listener) = channel {
                let socket = try await listener.accept(timeout: configuration.dataTimeout)
                dataConnection = try await FTPStreamConnection.adopt(
                    socket: socket,
                    tls: nil,
                    timeout: configuration.connectTimeout
                )
            }
            guard let connection = dataConnection else { throw FTPClientError.dataConnectionFailed("no data connection") }
            if usesTLS { await connection.startTLS(dataTLSOptions) }
            let reachedEnd = try await body(connection)
            if usesTLS, verb == "STOR", reachedEnd {
                try await connection.finishTLSWriting(timeout: configuration.dataTimeout)
            }
            connection.close()
            dataConnection = nil
            if !reachedEnd, abortsEarly {
                // 只要了一段就断开了数据连接:服务器回 426/451/226 都算完成;没按时回话
                // 也不影响已经拿到的数据,只是这条控制连接从此不再复用。
                guard let finish = try? await readReply(stage: "\(verb) abort", timeout: 5),
                      finish.isCompletion || [426, 451, 450].contains(finish.code) else {
                    shutDown()
                    return
                }
                return
            }
            let finish = try await readReply(stage: "\(verb) completion")
            guard finish.isCompletion else { throw failure(verb, finish) }
        } catch {
            dataConnection?.close()
            channel.close()
            log("\(verb) failed: \(error)")
            // 提前收手后服务器没按时回话、或者别的半截状态:这条控制连接不能再用了。
            if !(error is FTPClientError) || Self.breaksControlConnection(error) {
                shutDown()
            }
            throw error
        }
    }

    private enum DataChannel {
        case passive(FTPStreamConnection)
        case active(FTPActiveListener)

        func close() {
            switch self {
            case .passive(let connection): connection.close()
            case .active(let listener): listener.close()
            }
        }
    }

    private func prepareDataChannel() async throws -> DataChannel {
        switch configuration.dataConnectionMode {
        case .active:
            return .active(try await openActiveListener())
        case .passive:
            return .passive(try await connectPassive(useEPSV: false))
        case .extendedPassive:
            return .passive(try await connectPassive(useEPSV: true))
        case .automatic:
            return .passive(try await connectPassive(useEPSV: !traits.rejectsEPSV))
        }
    }

    private func connectPassive(useEPSV: Bool) async throws -> FTPStreamConnection {
        var host = configuration.host
        var port: Int
        if useEPSV {
            let reply = try await command("EPSV")
            if reply.isCompletion, let parsed = FTPDataEndpointParser.extendedPassivePort(from: reply) {
                port = parsed
            } else if reply.isPermanentFailure || reply.isCompletion {
                // 不支持 EPSV(或回复看不懂):记下来,这台服务器以后直接用 PASV。
                traits.rejectsEPSV = true
                log("server rejects EPSV (\(reply.code)), using PASV")
                return try await connectPassive(useEPSV: false)
            } else {
                throw dataSetupFailure("EPSV", reply)
            }
        } else {
            let reply = try await command("PASV")
            guard reply.isCompletion, let endpoint = FTPDataEndpointParser.passiveEndpoint(from: reply) else {
                throw dataSetupFailure("PASV", reply)
            }
            host = FTPPassiveAddressPolicy.dataHost(replyAddress: endpoint.host, controlHost: configuration.host)
            port = endpoint.port
            if host != endpoint.host {
                log("PASV reported \(endpoint.host), connecting to \(host) instead")
            }
        }
        do {
            return try await FTPStreamConnection.connect(
                host: host,
                port: port,
                tls: nil,
                timeout: configuration.connectTimeout
            )
        } catch let error as FTPClientError {
            if case .timedOut = error { throw FTPClientError.timedOut("data connect \(host):\(port)") }
            throw FTPClientError.dataConnectionFailed("\(host):\(port) \(error)")
        }
    }

    private func openActiveListener() async throws -> FTPActiveListener {
        guard let local = await control?.localAddress() else {
            throw FTPClientError.activeModeUnavailable("no local address")
        }
        let listener = try FTPActiveListener.open(on: local)
        log("active mode listening on \(listener.host):\(listener.port)")
        do {
            let isIPv4 = FTPActiveCommand.ipv4Octets(listener.host) != nil
            if isIPv4, let port = FTPActiveCommand.port(address: listener.host, port: listener.port) {
                let reply = try await rawCommand(port)
                if reply.isCompletion { return listener }
                guard reply.isPermanentFailure else { throw dataSetupFailure("PORT", reply) }
            }
            guard let eprt = FTPActiveCommand.extendedPort(address: listener.host, port: listener.port) else {
                throw FTPClientError.activeModeUnavailable("unsupported address \(listener.host)")
            }
            let reply = try await rawCommand(eprt)
            guard reply.isCompletion else { throw dataSetupFailure("EPRT", reply) }
            return listener
        } catch {
            listener.close()
            throw error
        }
    }

    // MARK: Control channel

    @discardableResult
    private func command(_ verb: String, _ argument: String? = nil, redacted: Bool = false) async throws -> FTPReply {
        guard let control else { throw FTPClientError.connectionClosed }
        try Task.checkCancellation()
        let data = try FTPCommand.data(verb, argument, encoding: traits.textEncoding)
        do {
            try await control.write(data, timeout: configuration.replyTimeout, stage: "send \(verb)")
        } catch {
            shutDown()
            throw error
        }
        return try await readReply(stage: verb)
    }

    private func rawCommand(_ line: String) async throws -> FTPReply {
        guard let control else { throw FTPClientError.connectionClosed }
        let data = try FTPCommand.data(line, encoding: .utf8)
        do {
            try await control.write(data, timeout: configuration.replyTimeout, stage: "send \(line.prefix(4))")
        } catch {
            shutDown()
            throw error
        }
        return try await readReply(stage: String(line.prefix(4)))
    }

    private func readReply(stage: String, timeout: TimeInterval? = nil) async throws -> FTPReply {
        while queuedReplies.isEmpty {
            guard let control else { throw FTPClientError.connectionClosed }
            let data: Data
            do {
                data = try await control.read(timeout: timeout ?? configuration.replyTimeout, stage: "reply \(stage)")
            } catch {
                shutDown()
                throw error
            }
            if data.isEmpty {
                shutDown()
                throw FTPClientError.connectionClosed
            }
            do {
                queuedReplies.append(contentsOf: try parser.append(data))
            } catch {
                shutDown()
                throw FTPClientError.invalidReply("\(error)")
            }
        }
        let reply = queuedReplies.removeFirst()
        if reply.code == 421 {
            // 服务器要断开(超时、连接数满):这条连接不能再用。
            shutDown()
        }
        return reply
    }

    private func failure(_ command: String, _ reply: FTPReply) -> FTPClientError {
        .replyFailure(command: command, code: reply.code, message: reply.text)
    }

    /// 建数据连接的命令本身被拒(服务器关了被动模式会对 PASV 回 550 之类):这是数据连接
    /// 方式不对,不是文件不存在;421 仍按连接被关处理。
    private func dataSetupFailure(_ command: String, _ reply: FTPReply) -> FTPClientError {
        if reply.code == 421 { return failure(command, reply) }
        return .dataConnectionFailed("\(command) \(reply.code) \(reply.text)")
    }

    private func decodeListing(_ data: Data) -> String {
        let encoding = traits.textEncoding
        if let text = encoding.decode(data) { return text }
        if encoding == .utf8, !features.supportsUTF8, let detected = FTPTextEncoding.detect(data), detected != encoding {
            traits.textEncoding = detected
            parser.encoding = detected
            log("file names are \(detected.rawValue)")
            if let text = detected.decode(data) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isUnsupportedCommand(_ error: FTPClientError) -> Bool {
        guard let code = error.replyCode else { return false }
        return [500, 501, 502, 504].contains(code)
    }

    private static func breaksControlConnection(_ error: Error) -> Bool {
        guard let error = error as? FTPClientError else { return true }
        switch error {
        case .replyFailure(_, let code, _): return code == 421
        case .activeModeUnavailable: return false
        default: return true
        }
    }
}

// MARK: - Pool

/// 复用已登录的会话:目录列表、读一段、整份下载都从这里借。服务器常限制同一地址的
/// 连接数,所以同时最多开 `maximumSessions` 条,其余排队;闲置一会儿的会话发 QUIT 关掉。
public actor FTPSessionPool {
    public let configuration: FTPSessionConfiguration
    private let traits = FTPServerTraits()
    private var maximumSessions: Int
    private let idleTimeout: TimeInterval
    private var idle: [(session: FTPSession, since: Date)] = []
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isShutDown = false
    private var reaper: Task<Void, Never>?

    public init(configuration: FTPSessionConfiguration, maximumSessions: Int = 3, idleTimeout: TimeInterval = 20) {
        self.configuration = configuration
        self.maximumSessions = max(1, maximumSessions)
        self.idleTimeout = idleTimeout
    }

    /// 借一个会话跑 `body`。`retriesOnStaleConnection` 为 true 时,复用的闲置会话一开口
    /// 就断(服务器或路由器早把它掐了)会换一个新会话重做一次——只给读操作用。
    public func withSession<T: Sendable>(
        retriesOnStaleConnection: Bool = true,
        _ body: @Sendable (FTPSession) async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            let (session, reused) = try await acquire()
            do {
                let result = try await body(session)
                await release(session)
                return result
            } catch {
                await release(session)
                attempt += 1
                guard retriesOnStaleConnection, reused, attempt == 1, Self.isStaleConnection(error),
                      !Task.isCancelled else { throw error }
            }
        }
    }

    public func shutdown() async {
        isShutDown = true
        reaper?.cancel()
        let sessions = idle.map(\.session)
        idle.removeAll()
        for session in sessions { await session.close() }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func acquire() async throws -> (FTPSession, Bool) {
        while true {
            if isShutDown { throw FTPClientError.cancelled }
            try Task.checkCancellation()
            while let candidate = idle.popLast() {
                if await candidate.session.isReusable {
                    activeCount += 1
                    return (candidate.session, true)
                }
            }
            if activeCount < maximumSessions {
                activeCount += 1
                let session = FTPSession(configuration: configuration, traits: traits)
                do {
                    try await session.open()
                } catch let error as FTPClientError
                            where error.replyCode == 421 && (activeCount > 1 || !idle.isEmpty) {
                    // 服务器的同地址连接数满了:以后最多开现有这么多条(在用的加闲置的),这次排队
                    // 等别人还回来。登录被拒的路上已经有人还回来了(闲置里有)就直接去用它。
                    activeCount -= 1
                    maximumSessions = max(1, activeCount + idle.count)
                    configuration.log?("FTP \(configuration.host) allows \(maximumSessions) connection(s), queueing")
                    if idle.isEmpty {
                        await withCheckedContinuation { waiters.append($0) }
                    }
                    continue
                } catch {
                    activeCount -= 1
                    wakeOne()
                    throw error
                }
                return (session, false)
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func release(_ session: FTPSession) async {
        activeCount -= 1
        if !isShutDown, await session.isReusable {
            idle.append((session, Date()))
            scheduleReaper()
        } else {
            await session.close()
        }
        wakeOne()
    }

    private func wakeOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    private func scheduleReaper() {
        guard reaper == nil else { return }
        let interval = idleTimeout
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000 / 2))
                guard let self, await self.reapIdle() else { return }
            }
        }
    }

    /// 关掉闲置太久的会话;没有闲置会话了返回 false,收割任务就此结束。
    private func reapIdle() async -> Bool {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        let expired = idle.filter { $0.since < cutoff }.map(\.session)
        idle.removeAll { $0.since < cutoff }
        for session in expired { await session.close() }
        if idle.isEmpty {
            reaper = nil
            return false
        }
        return true
    }

    private static func isStaleConnection(_ error: Error) -> Bool {
        guard let error = error as? FTPClientError else { return false }
        switch error {
        case .connectionClosed, .connectionFailed: return true
        case .replyFailure(_, let code, _): return code == 421
        case .timedOut(let stage): return stage.hasPrefix("reply")
        default: return false
        }
    }
}
#endif
