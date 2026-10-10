#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import PrimuseKit

// 真实的 FTPSession / FTPSessionPool 走本机回环,对面是本文件里的脚本化 FTP 服务器:
// POSIX socket,每条控制连接一条线程,文件放在内存里。服务器声明哪些扩展、EPSV / MLSD /
// PORT 支不支持、PASV 报什么地址、连接数上限、文件名用不用 GB18030、主动模式连不连得进来,
// 都由各个测试自己定。

@Suite("FTP client over loopback", .serialized, .timeLimit(.minutes(2)))
struct FTPClientIntegrationTests {
    // MARK: Listing and passive modes

    @Test("Automatic mode logs in, lists with MLSD over EPSV and keeps double spaces in names")
    func automaticModeListsWithMLSD() async throws {
        try await LoopbackFTP.deadline(30) {
            let spaced = LoopbackFTP.bytes(count: 1234, seed: 1)
            let unicode = LoopbackFTP.bytes(count: 4321, seed: 2)
            let server = try LoopbackFTPServer.start(files: [
                "/Music/Two  Spaces.flac": spaced,
                "/Music/歌 曲.mp3": unicode,
                "/Music/Albums/inner.flac": LoopbackFTP.bytes(count: 10, seed: 3),
                "/readme.txt": Data("hello".utf8),
            ])
            defer { server.stop() }
            let session = FTPSession(configuration: server.configuration(mode: .automatic))
            try await session.open()

            let root = try await session.list("/")
            #expect(Set(root.map(\.name)) == ["Music", "readme.txt"])
            #expect(root.first { $0.name == "Music" }?.isDirectory == true)
            #expect(root.first { $0.name == "readme.txt" }?.size == 5)

            let entries = try await session.list("/Music")
            #expect(entries.map(\.name).sorted() == ["Albums", "Two  Spaces.flac", "歌 曲.mp3"].sorted())
            let spacedEntry = try #require(entries.first { $0.name == "Two  Spaces.flac" })
            #expect(spacedEntry.size == 1234)
            #expect(!spacedEntry.isDirectory)
            let albums = try #require(entries.first { $0.name == "Albums" })
            #expect(albums.isDirectory)
            #expect(albums.size == -1)

            #expect(try await session.size("/Music/Two  Spaces.flac") == 1234)
            let downloaded = try await session.retrieve("/Music/歌 曲.mp3", offset: 0, length: 1 << 20)
            #expect(downloaded == unicode)
            await session.close()

            let commands = server.commands
            #expect(commands.contains("EPSV"))
            #expect(commands.contains("MLSD"))
            #expect(commands.contains("OPTS"))
            #expect(!commands.contains("PASV"))
            #expect(!commands.contains("LIST"))
            #expect(server.logins == 1)
        }
    }

    @Test("Automatic mode falls back to PASV and LIST and redirects a private PASV address to the configured host")
    func automaticModeFallsBackToPASVAndLIST() async throws {
        try await LoopbackFTP.deadline(30) {
            var options = LoopbackFTPServer.Options()
            options.advertisesEPSV = false
            options.supportsEPSV = false
            options.advertisesMLST = false
            options.supportsMLSD = false
            // 服务器在 NAT 后面:PASV 报自己的内网地址。
            options.passiveReplyAddress = "10.0.0.5"
            let song = LoopbackFTP.bytes(count: 50_000, seed: 4)
            let server = try LoopbackFTPServer.start(options: options, files: [
                "/Music/Two  Spaces.flac": song,
                "/Music/Albums/inner.flac": LoopbackFTP.bytes(count: 10, seed: 3),
            ])
            defer { server.stop() }
            // 填的是主机名(不是内网 IPv4 字面量):PASV 报的 10.0.0.5 要换成它去连。
            let session = FTPSession(configuration: server.configuration(host: "localhost", mode: .automatic))
            try await session.open()

            let entries = try await session.list("/Music")
            #expect(entries.map(\.name).sorted() == ["Albums", "Two  Spaces.flac"])
            let spacedEntry = try #require(entries.first { $0.name == "Two  Spaces.flac" })
            #expect(spacedEntry.size == 50_000)
            #expect(!spacedEntry.isDirectory)
            #expect(entries.first { $0.name == "Albums" }?.isDirectory == true)

            // 第二次直接 PASV + LIST:不支持 EPSV / MLSD 记住了。
            let again = try await session.list("/Music")
            #expect(again == entries)
            let data = try await session.retrieve("/Music/Two  Spaces.flac", offset: 0, length: 1 << 20)
            #expect(data == song)
            await session.close()

            let commands = server.commands
            #expect(commands.filter { $0 == "EPSV" }.count == 1)
            #expect(commands.filter { $0 == "MLSD" }.count == 1)
            #expect(commands.filter { $0 == "LIST" }.count == 2)
            #expect(commands.filter { $0 == "PASV" }.count == 4)
            #expect(server.logins == 1)
        }
    }

    @Test(
        "Explicit passive modes use only the requested command",
        arguments: [FTPDataConnectionMode.passive, .extendedPassive]
    )
    func explicitPassiveModes(mode: FTPDataConnectionMode) async throws {
        try await LoopbackFTP.deadline(30) {
            let song = LoopbackFTP.bytes(count: 200_000, seed: 5)
            let server = try LoopbackFTPServer.start(files: ["/Music/song.flac": song])
            defer { server.stop() }
            let session = FTPSession(configuration: server.configuration(mode: mode))
            try await session.open()

            let entries = try await session.list("/Music")
            #expect(entries.map(\.name) == ["song.flac"])
            #expect(entries.first?.size == 200_000)

            let url = LoopbackFTP.temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try await session.retrieve("/Music/song.flac", to: url) == 200_000)
            #expect(try Data(contentsOf: url) == song)
            await session.close()

            let commands = server.commands
            if mode == .passive {
                #expect(commands.contains("PASV"))
                #expect(!commands.contains("EPSV"))
            } else {
                #expect(commands.contains("EPSV"))
                #expect(!commands.contains("PASV"))
            }
        }
    }

    @Test("Active mode lists and downloads through a connection the server opens back", arguments: [true, false])
    func activeMode(serverSupportsPORT: Bool) async throws {
        try await LoopbackFTP.deadline(30) {
            var options = LoopbackFTPServer.Options()
            options.supportsPORT = serverSupportsPORT
            let song = LoopbackFTP.bytes(count: 200_000, seed: 11)
            let server = try LoopbackFTPServer.start(options: options, files: [
                "/Music/song.flac": song,
                "/Music/Two  Spaces.mp3": LoopbackFTP.bytes(count: 77, seed: 12),
            ])
            defer { server.stop() }
            let session = FTPSession(configuration: server.configuration(mode: .active))
            try await session.open()

            let entries = try await session.list("/Music")
            #expect(entries.map(\.name).sorted() == ["Two  Spaces.mp3", "song.flac"])
            let data = try await session.retrieve("/Music/song.flac", offset: 0, length: 1 << 20)
            #expect(data == song)
            let url = LoopbackFTP.temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try await session.retrieve("/Music/song.flac", to: url) == 200_000)
            #expect(try Data(contentsOf: url) == song)
            await session.close()

            let commands = server.commands
            #expect(commands.contains(serverSupportsPORT ? "PORT" : "EPRT"))
            #expect(!commands.contains("PASV"))
            #expect(!commands.contains("EPSV"))
        }
    }

    // MARK: Range reads and file operations

    @Test("Range reads abort the data connection early and keep reusing one logged-in control connection")
    func rangeReadsReuseOneControlConnection() async throws {
        try await LoopbackFTP.deadline(40) {
            var options = LoopbackFTPServer.Options()
            // 慢一点发,保证客户端读够断开时服务器还没发完。
            options.retrieveChunkSize = 32 * 1024
            options.retrieveChunkDelay = 0.002
            let size = 3 * 1024 * 1024
            let content = LoopbackFTP.bytes(count: size, seed: 6)
            let server = try LoopbackFTPServer.start(options: options, files: ["/Music/big.flac": content])
            defer { server.stop() }
            let pool = FTPSessionPool(configuration: server.configuration(mode: .automatic))

            let first = try await pool.withSession {
                try await $0.retrieve("/Music/big.flac", offset: 1_000_000, length: 100_000)
            }
            #expect(first == content.subdata(in: 1_000_000..<1_100_000))
            let second = try await pool.withSession {
                try await $0.retrieve("/Music/big.flac", offset: 2_500_000, length: 65_537)
            }
            #expect(second == content.subdata(in: 2_500_000..<2_565_537))
            // 要的比剩下的多:读到文件尾为止,正常收尾。
            let tail = try await pool.withSession {
                try await $0.retrieve("/Music/big.flac", offset: Int64(size - 1000), length: 5000)
            }
            #expect(tail == content.subdata(in: (size - 1000)..<size))
            let reportedSize = try await pool.withSession { try await $0.size("/Music/big.flac") }
            #expect(reportedSize == Int64(size))
            await pool.shutdown()

            #expect(server.retrieveOffsets == [1_000_000, 2_500_000, size - 1000])
            #expect(server.abortedTransfers == 2)
            #expect(server.logins == 1)
            #expect(server.acceptedConnections == 1)
        }
    }

    @Test("Full download, uploads, rename and delete change the server's files")
    func downloadUploadRenameDelete() async throws {
        try await LoopbackFTP.deadline(40) {
            let big = LoopbackFTP.bytes(count: 1_500_000, seed: 7)
            let server = try LoopbackFTPServer.start(files: [
                "/Music/big.flac": big,
                "/Music/old.mp3": Data(count: 10),
            ])
            defer { server.stop() }
            let session = FTPSession(configuration: server.configuration(mode: .automatic))
            try await session.open()

            let url = LoopbackFTP.temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try await session.retrieve("/Music/big.flac", to: url) == Int64(big.count))
            #expect(try Data(contentsOf: url) == big)
            // 从中间续传:本地文件只有 offset 之后的字节。
            #expect(try await session.retrieve("/Music/big.flac", offset: 1000, to: url) == Int64(big.count - 1000))
            #expect(try Data(contentsOf: url) == big.subdata(in: 1000..<big.count))

            let upload = LoopbackFTP.bytes(count: 300_000, seed: 8)
            try await session.store("/Music/upload.bin", data: upload)
            #expect(server.file(at: "/Music/upload.bin") == upload)

            let local = LoopbackFTP.bytes(count: 700_001, seed: 9)
            let localURL = LoopbackFTP.temporaryURL()
            defer { try? FileManager.default.removeItem(at: localURL) }
            try local.write(to: localURL)
            try await session.store("/Music/from-file.bin", fileURL: localURL)
            #expect(server.file(at: "/Music/from-file.bin") == local)

            try await session.store("/Music/empty.bin", data: Data())
            #expect(server.file(at: "/Music/empty.bin") == Data())

            try await session.rename("/Music/upload.bin", to: "/Music/renamed.bin")
            #expect(server.file(at: "/Music/upload.bin") == nil)
            #expect(server.file(at: "/Music/renamed.bin") == upload)

            try await session.delete("/Music/old.mp3")
            #expect(server.file(at: "/Music/old.mp3") == nil)

            // 路径错误照实报出来,控制连接照常能用。
            do {
                _ = try await session.retrieve("/Music/missing.flac", offset: 0, length: 10)
                Issue.record("downloading a missing file succeeded")
            } catch let error as FTPClientError {
                #expect(error.isPathFailure, "\(error)")
            }
            do {
                try await session.delete("/Music/missing.flac")
                Issue.record("deleting a missing file succeeded")
            } catch let error as FTPClientError {
                #expect(error.isPathFailure, "\(error)")
            }
            #expect(await session.isReusable)
            let names = try await session.list("/Music").map(\.name).sorted()
            #expect(names == ["big.flac", "empty.bin", "from-file.bin", "renamed.bin"])
            await session.close()
            #expect(server.logins == 1)
        }
    }

    // MARK: Failures

    @Test("A wrong password is reported as an authentication failure")
    func wrongPasswordIsAuthenticationFailure() async throws {
        try await LoopbackFTP.deadline(20) {
            let server = try LoopbackFTPServer.start(files: ["/Music/a.mp3": Data(count: 10)])
            defer { server.stop() }

            let session = FTPSession(configuration: server.configuration(mode: .automatic, password: "wrong"))
            do {
                try await session.open()
                Issue.record("login with a wrong password succeeded")
            } catch let error as FTPClientError {
                #expect(error.isAuthenticationFailure, "\(error)")
                #expect(error.replyCode == 530)
            }
            #expect(await session.isReusable == false)

            let pool = FTPSessionPool(configuration: server.configuration(mode: .automatic, password: "wrong"))
            do {
                _ = try await pool.withSession { try await $0.list("/Music") }
                Issue.record("pool login with a wrong password succeeded")
            } catch let error as FTPClientError {
                #expect(error.isAuthenticationFailure, "\(error)")
            }
            await pool.shutdown()
            #expect(server.failedLogins == 2)
            #expect(server.logins == 0)
        }
    }

    @Test("A passive data port nobody listens on fails fast and leaves the control connection usable")
    func refusedPassiveDataConnection() async throws {
        try await LoopbackFTP.deadline(20) {
            var options = LoopbackFTPServer.Options()
            options.passiveReplyPort = try LoopbackFTPServer.closedLoopbackPort()
            let server = try LoopbackFTPServer.start(options: options, files: ["/Music/a.mp3": Data(count: 10)])
            defer { server.stop() }
            let session = FTPSession(configuration: server.configuration(mode: .passive, timeout: 2))
            try await session.open()

            let clock = ContinuousClock()
            let started = clock.now
            do {
                _ = try await session.list("/Music")
                Issue.record("listing succeeded without a data connection")
            } catch let error as FTPClientError {
                #expect(error.isDataConnectionFailure, "\(error)")
            }
            #expect(clock.now - started < .seconds(6))
            #expect(try await session.size("/Music/a.mp3") == 10)
            await session.close()
        }
    }

    @Test("A data connection a middlebox swallows fails as a data connection failure and keeps the session")
    func swallowedPassiveDataConnection() async throws {
        try await LoopbackFTP.deadline(20) {
            // 透明代理、防火墙常这样:客户端的数据连接一连就通、随即被关,服务器那头始终等不到,
            // 过一会儿回 425。(编译机走 TUN 代理,连 192.0.2.1 这类地址也是这个表现。)
            let sink = try LoopbackSink.start()
            defer { sink.stop() }
            var options = LoopbackFTPServer.Options()
            options.passiveReplyPort = sink.port
            options.passiveAcceptTimeout = 1
            let server = try LoopbackFTPServer.start(options: options, files: ["/Music/a.mp3": Data(count: 10)])
            defer { server.stop() }
            let session = FTPSession(configuration: server.configuration(mode: .passive, timeout: 3))
            try await session.open()

            let clock = ContinuousClock()
            let started = clock.now
            do {
                let data = try await session.retrieve("/Music/a.mp3", offset: 0, length: 10)
                Issue.record("download succeeded through a swallowed data connection: \(data.count) bytes")
            } catch let error as FTPClientError {
                #expect(error.isDataConnectionFailure, "\(error)")
            }
            #expect(clock.now - started < .seconds(6))
            #expect(await session.isReusable)
            #expect(try await session.size("/Music/a.mp3") == 10)
            await session.close()
        }
    }

    @Test("Active mode where the server never connects back times out as a data connection failure")
    func activeModeServerNeverConnects() async throws {
        try await LoopbackFTP.deadline(20) {
            var options = LoopbackFTPServer.Options()
            options.activeModeNeverConnects = true
            let server = try LoopbackFTPServer.start(options: options, files: ["/Music/a.mp3": Data(count: 10)])
            defer { server.stop() }
            let session = FTPSession(configuration: server.configuration(mode: .active, timeout: 2))
            try await session.open()

            let clock = ContinuousClock()
            let started = clock.now
            do {
                _ = try await session.retrieve("/Music/a.mp3", offset: 0, length: 10)
                Issue.record("download succeeded although the server never connected")
            } catch let error as FTPClientError {
                #expect(error.isDataConnectionFailure, "\(error)")
            }
            #expect(clock.now - started < .seconds(8))
            await session.close()
        }
    }

    // MARK: Pool

    @Test("The pool queues instead of failing when the server allows only one connection")
    func poolQueuesOnConnectionLimit() async throws {
        try await LoopbackFTP.deadline(30) {
            var options = LoopbackFTPServer.Options()
            options.maximumConnections = 1
            let server = try LoopbackFTPServer.start(options: options, files: ["/Music/a.mp3": Data(count: 10)])
            defer { server.stop() }
            let pool = FTPSessionPool(configuration: server.configuration(mode: .automatic))

            let work: @Sendable (FTPSession) async throws -> [String] = { session in
                let names = try await session.list("/Music").map(\.name)
                // 占着会话,直到另一个请求的登录被服务器 421 拒掉并进了排队。
                _ = try await LoopbackFTP.waitUntil { server.rejectedConnections >= 1 }
                try await Task.sleep(nanoseconds: 300_000_000)
                return names
            }
            async let first = pool.withSession(work)
            async let second = pool.withSession(work)
            let (a, b) = try await (first, second)
            #expect(a == ["a.mp3"])
            #expect(b == ["a.mp3"])
            await pool.shutdown()
            #expect(server.logins == 1)
            #expect(server.rejectedConnections == 1)
        }
    }

    @Test("A session released while a rejected login is still in flight is reused instead of failing with 421")
    func poolReusesSessionReleasedDuringRejectedLogin() async throws {
        try await LoopbackFTP.deadline(30) {
            var options = LoopbackFTPServer.Options()
            options.maximumConnections = 1
            // 421 来得比一条 SIZE 的来回晚(远端服务器、慢网络下本来如此)。
            options.rejectionDelay = 0.5
            let server = try LoopbackFTPServer.start(options: options, files: [
                "/Music/a.mp3": Data(count: 10),
                "/Music/b.mp3": Data(count: 20),
            ])
            defer { server.stop() }
            let pool = FTPSessionPool(configuration: server.configuration(mode: .automatic))
            // 先留下一个闲置会话。
            _ = try await pool.withSession { try await $0.list("/Music") }

            async let first = pool.withSession { try await $0.size("/Music/a.mp3") }
            async let second = pool.withSession { try await $0.size("/Music/b.mp3") }
            let (a, b) = try await (first, second)
            #expect(a == 10)
            #expect(b == 20)
            await pool.shutdown()
            #expect(server.logins == 1)
            #expect(server.rejectedConnections == 1)
        }
    }

    @Test("Idle sessions the server dropped or shut down are replaced transparently for reads")
    func staleIdleSessionsAreReplaced() async throws {
        try await LoopbackFTP.deadline(30) {
            let server = try LoopbackFTPServer.start(files: ["/Music/a.mp3": Data(count: 10)])
            defer { server.stop() }
            let pool = FTPSessionPool(configuration: server.configuration(mode: .automatic))
            let warmUp = try await pool.withSession { try await $0.list("/Music") }
            #expect(warmUp.map(\.name) == ["a.mp3"])

            // 服务器闲置超时:发 421 后断开。
            server.dropControlConnections()
            #expect(try await LoopbackFTP.waitUntil { server.liveConnections == 0 })
            let listed = try await pool.withSession { try await $0.list("/Music") }
            #expect(listed.map(\.name) == ["a.mp3"])
            #expect(server.logins == 2)

            // 服务器要关了:下一条命令(不论是什么)回 421 并断开(RFC 959)。
            server.failNextCommandWithServiceUnavailable()
            let size = try await pool.withSession { try await $0.size("/Music/a.mp3") }
            #expect(size == 10)
            #expect(server.logins == 3)
            await pool.shutdown()
        }
    }

    // MARK: Encodings

    @Test("GBK names from a server without UTF8 are decoded and sent back in GB18030")
    func gb18030Names() async throws {
        try await LoopbackFTP.deadline(30) {
            var options = LoopbackFTPServer.Options()
            options.advertisesUTF8 = false
            options.usesGB18030Names = true
            let name = "周杰伦 - 晴天.flac"
            let path = "/音乐/" + name
            let encodedPath = try #require(path.data(using: LoopbackFTPServer.gb18030))
            #expect(String(data: encodedPath, encoding: .utf8) == nil, "the fixture must not be valid UTF-8")
            let song = LoopbackFTP.bytes(count: 80_000, seed: 10)
            let server = try LoopbackFTPServer.start(options: options, files: [path: song])
            defer { server.stop() }
            let session = FTPSession(configuration: server.configuration(mode: .automatic))
            try await session.open()

            let root = try await session.list("/")
            #expect(root.map(\.name) == ["音乐"])
            #expect(root.first?.isDirectory == true)
            let entries = try await session.list("/音乐")
            #expect(entries.map(\.name) == [name])
            #expect(entries.first?.size == 80_000)
            let data = try await session.retrieve(path, offset: 0, length: 1 << 20)
            #expect(data == song)
            await session.close()

            #expect(server.retrievedRawPaths == [encodedPath])
            #expect(!server.commands.contains("OPTS"))
        }
    }
}

// MARK: - Test helpers

private enum LoopbackFTP {
    struct DeadlineExceeded: Error, CustomStringConvertible {
        let seconds: Double
        var description: String { "operation did not finish within \(seconds) s" }
    }

    final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        @discardableResult
        func finish(_ result: Result<T, Error>) -> Bool {
            let pending: CheckedContinuation<T, Error>? = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            guard let pending else { return false }
            pending.resume(with: result)
            return true
        }
    }

    /// 跑 `operation`,超过 `seconds` 秒就让测试失败返回,哪怕操作本身卡住不响应取消。
    static func deadline<T: Sendable>(
        _ seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once(continuation)
            let work = Task {
                do {
                    once.finish(.success(try await operation()))
                } catch {
                    once.finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.finish(.failure(DeadlineExceeded(seconds: seconds))) {
                    work.cancel()
                }
            }
        }
    }

    static func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// 伪随机字节:偏移读错一个字节都比得出来。
    static func bytes(count: Int, seed: UInt64) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ (seed &* 0xBF58_476D_1CE4_E5B9)
        if state == 0 { state = 1 }
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        return data
    }

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("primuse-ftp-test-\(UUID().uuidString)")
    }
}

// MARK: - Scripted server

private final class LoopbackFTPServer: @unchecked Sendable {
    struct Options: Sendable {
        var username = "user"
        var password = "secret"
        var advertisesMLST = true
        var advertisesEPSV = true
        var advertisesUTF8 = true
        var supportsEPSV = true
        var supportsMLSD = true
        var supportsPORT = true
        /// PASV 回复里报的地址。
        var passiveReplyAddress = "127.0.0.1"
        /// PASV 回复里报的端口;nil 报真实的监听端口。
        var passiveReplyPort: Int?
        /// 被动模式下等客户端连进数据端口的时间,等不到回 425。
        var passiveAcceptTimeout: TimeInterval = 5
        /// 文件名(列表、命令参数)用 GB18030:没声明 UTF8 的中文 Windows 服务器。
        var usesGB18030Names = false
        /// 同时最多几条控制连接,多出来的回 421 后断开。
        var maximumConnections: Int?
        /// 回 421 之前先等这么久。
        var rejectionDelay: TimeInterval = 0
        var retrieveChunkSize = 64 * 1024
        var retrieveChunkDelay: TimeInterval = 0
        /// 主动模式:回了 150 却始终不连客户端(客户端在防火墙后面)。
        var activeModeNeverConnects = false
        /// RFC 3659 §5:REST 必须是传输命令前的最后一条命令,中间夹了别的命令续传位置作废。
        var restartMustPrecedeTransfer = true
    }

    struct Listener {
        let sockets: [Int32]
        let port: Int
    }

    typealias SocketAddress = (storage: sockaddr_storage, length: socklen_t)

    struct SocketError: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call) failed: errno \(code)" }
    }

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    ))

    let options: Options
    let port: Int
    private let listener: Listener
    private let lock = NSLock()
    private var files: [String: Data]
    private var directories: Set<String>
    private var controlSockets: Set<Int32> = []
    private var isStopped = false
    private var failsNextCommand = false
    private var accepted = 0
    private var rejected = 0
    private var successfulLogins = 0
    private var rejectedLogins = 0
    private var aborted = 0
    private var commandLog: [String] = []
    private var retrieveOffsetLog: [Int] = []
    private var retrieveRawPathLog: [Data] = []

    private init(options: Options, files: [String: Data]) throws {
        self.options = options
        self.files = files
        var directories: Set<String> = ["/"]
        for path in files.keys {
            directories.formUnion(LoopbackFTPServer.ancestors(of: path))
        }
        self.directories = directories
        let listener = try LoopbackFTPServer.listenOnLoopback()
        self.listener = listener
        port = listener.port
    }

    static func start(options: Options = Options(), files: [String: Data]) throws -> LoopbackFTPServer {
        let server = try LoopbackFTPServer(options: options, files: files)
        let sockets = server.listener.sockets
        Thread { [server] in
            server.acceptLoop(sockets)
        }.start()
        return server
    }

    func configuration(
        host: String = "127.0.0.1",
        mode: FTPDataConnectionMode,
        password: String? = nil,
        timeout: TimeInterval = 5
    ) -> FTPSessionConfiguration {
        FTPSessionConfiguration(
            host: host,
            port: port,
            username: options.username,
            password: password ?? options.password,
            encryption: .none,
            dataConnectionMode: mode,
            connectTimeout: timeout,
            replyTimeout: timeout,
            dataTimeout: timeout
        )
    }

    /// 停止接受连接并断开所有控制连接。
    func stop() {
        lock.withLock {
            isStopped = true
            // 持锁关:连接线程先从集合里摘掉才会 close,描述符号不会被别的 socket 复用。
            for socket in controlSockets { _ = Darwin.shutdown(socket, SHUT_RDWR) }
        }
    }

    /// 模拟服务器闲置超时:给每条控制连接发 421 后断开。
    func dropControlConnections() {
        lock.withLock {
            for socket in controlSockets {
                Self.sendAll(socket, Data("421 Timeout.\r\n".utf8))
                _ = Darwin.shutdown(socket, SHUT_RDWR)
            }
        }
    }

    /// 下一条命令(不论哪条连接、什么命令)回 421 并断开。
    func failNextCommandWithServiceUnavailable() {
        lock.withLock { failsNextCommand = true }
    }

    var commands: [String] { lock.withLock { commandLog } }
    var logins: Int { lock.withLock { successfulLogins } }
    var failedLogins: Int { lock.withLock { rejectedLogins } }
    var acceptedConnections: Int { lock.withLock { accepted } }
    var rejectedConnections: Int { lock.withLock { rejected } }
    var abortedTransfers: Int { lock.withLock { aborted } }
    var liveConnections: Int { lock.withLock { controlSockets.count } }
    var retrieveOffsets: [Int] { lock.withLock { retrieveOffsetLog } }
    var retrievedRawPaths: [Data] { lock.withLock { retrieveRawPathLog } }
    var stopped: Bool { lock.withLock { isStopped } }

    func file(at path: String) -> Data? {
        lock.withLock { files[path] }
    }

    // MARK: Accepting

    private func acceptLoop(_ sockets: [Int32]) {
        defer { sockets.forEach { _ = Darwin.close($0) } }
        while !stopped {
            var descriptors = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&descriptors, nfds_t(descriptors.count), 50) > 0 else { continue }
            for descriptor in descriptors where descriptor.revents & Int16(POLLIN) != 0 {
                let client = Darwin.accept(descriptor.fd, nil, nil)
                guard client >= 0 else { continue }
                Self.disableSIGPIPE(client)
                Thread { [self] in
                    self.serve(client)
                }.start()
            }
        }
    }

    private func serve(_ socket: Int32) {
        let admitted: Bool = lock.withLock {
            if let maximum = options.maximumConnections, controlSockets.count >= maximum {
                rejected += 1
                return false
            }
            controlSockets.insert(socket)
            accepted += 1
            return true
        }
        guard admitted else {
            if options.rejectionDelay > 0 { Thread.sleep(forTimeInterval: options.rejectionDelay) }
            Self.sendAll(socket, Data("421 Too many connections from your IP address.\r\n".utf8))
            _ = Darwin.close(socket)
            return
        }
        LoopbackFTPControlConnection(server: self, socket: socket).run()
        lock.withLock { _ = controlSockets.remove(socket) }
        _ = Darwin.close(socket)
    }

    // MARK: State used by connections

    func record(command verb: String) {
        lock.withLock { commandLog.append(verb) }
    }

    func recordLogin(succeeded: Bool) {
        lock.withLock {
            if succeeded {
                successfulLogins += 1
            } else {
                rejectedLogins += 1
            }
        }
    }

    func recordAbort() {
        lock.withLock { aborted += 1 }
    }

    func recordRetrieve(offset: Int, rawPath: Data) {
        lock.withLock {
            retrieveOffsetLog.append(offset)
            retrieveRawPathLog.append(rawPath)
        }
    }

    func consumeFailNextCommand() -> Bool {
        lock.withLock {
            let fails = failsNextCommand
            failsNextCommand = false
            return fails
        }
    }

    func isDirectory(_ path: String) -> Bool {
        lock.withLock { directories.contains(path) }
    }

    func exists(_ path: String) -> Bool {
        lock.withLock { files[path] != nil || directories.contains(path) }
    }

    func store(_ data: Data, at path: String) {
        lock.withLock { files[path] = data }
    }

    func removeFile(_ path: String) -> Bool {
        lock.withLock { files.removeValue(forKey: path) != nil }
    }

    func moveFile(_ source: String, to destination: String) -> Bool {
        lock.withLock { () -> Bool in
            guard let data = files.removeValue(forKey: source) else { return false }
            files[destination] = data
            return true
        }
    }

    /// `ls -l` 或 MLSD 格式的目录列表;目录不存在返回 nil。
    func listing(of directory: String, machine: Bool) -> String? {
        lock.withLock { () -> String? in
            guard directories.contains(directory) else { return nil }
            var lines: [String] = []
            if machine {
                lines.append("type=cdir;modify=20260102030405; \(directory)")
                lines.append("type=pdir;modify=20260102030405; ..")
            }
            for path in directories.sorted() where path != "/" && Self.parent(of: path) == directory {
                let name = Self.name(of: path)
                lines.append(machine
                    ? "type=dir;modify=20260102030405; \(name)"
                    : "drwxr-xr-x    2 ftp      ftp          4096 Mar 14  2024 \(name)")
            }
            for (path, data) in files.sorted(by: { $0.key < $1.key }) where Self.parent(of: path) == directory {
                let name = Self.name(of: path)
                lines.append(machine
                    ? "type=file;size=\(data.count);modify=20260102030405; \(name)"
                    : "-rw-r--r--    1 ftp      ftp      \(data.count) Mar 14  2024 \(name)")
            }
            return lines.map { $0 + "\r\n" }.joined()
        }
    }

    func encodeNames(_ text: String) -> Data {
        if options.usesGB18030Names, let data = text.data(using: Self.gb18030) { return data }
        return Data(text.utf8)
    }

    func decodeCommand(_ bytes: [UInt8]) -> String {
        let data = Data(bytes)
        if options.usesGB18030Names, let text = String(data: data, encoding: Self.gb18030) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Paths

    static func normalize(_ argument: String) -> String {
        var path = argument.isEmpty ? "/" : argument
        if !path.hasPrefix("/") { path = "/" + path }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = parent(of: path)
        while true {
            result.append(current)
            if current == "/" { return result }
            current = parent(of: current)
        }
    }

    // MARK: Sockets

    /// 127.0.0.1 与 ::1 的同一个端口各开一个监听:主机名 localhost 可能先解析成 ::1。
    static func listenOnLoopback() throws -> Listener {
        var lastError: Error?
        for _ in 0..<10 {
            let v4 = try makeListener(host: "127.0.0.1", port: 0)
            let port = boundPort(v4)
            do {
                let v6 = try makeListener(host: "::1", port: port)
                return Listener(sockets: [v4, v6], port: port)
            } catch let error as SocketError where error.code == EADDRINUSE {
                lastError = error
                _ = Darwin.close(v4)
            } catch {
                // 本机没有 IPv6 回环:只开 IPv4。
                return Listener(sockets: [v4], port: port)
            }
        }
        throw lastError ?? SocketError(call: "listen", code: 0)
    }

    /// 一个刚刚还在、现在没人监听的本机端口。
    static func closedLoopbackPort() throws -> Int {
        let socket = try makeListener(host: "127.0.0.1", port: 0)
        let port = boundPort(socket)
        _ = Darwin.close(socket)
        return port
    }

    static func makeListener(host: String, port: Int) throws -> Int32 {
        guard let address = socketAddress(host: host, port: port) else {
            throw SocketError(call: "address \(host)", code: 0)
        }
        let family = Int32(address.storage.ss_family)
        let socket = Darwin.socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else { throw SocketError(call: "socket", code: errno) }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET6 {
            setsockopt(socket, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let length = address.length
        let bound = withUnsafePointer(to: address.storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) }
        }
        guard bound == 0, Darwin.listen(socket, 16) == 0 else {
            let code = errno
            _ = Darwin.close(socket)
            throw SocketError(call: "bind/listen \(host):\(port)", code: code)
        }
        return socket
    }

    static func boundPort(_ socket: Int32) -> Int {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        if storage.ss_family == sa_family_t(AF_INET6) {
            return withUnsafePointer(to: storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
            }
        }
        return withUnsafePointer(to: storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
        }
    }

    static func socketAddress(host: String, port: Int) -> SocketAddress? {
        guard (0...65_535).contains(port) else { return nil }
        var storage = sockaddr_storage()
        if host.contains(":") {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else { return nil }
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee = address }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee = address }
        }
        return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
    }

    static func disableSIGPIPE(_ socket: Int32) {
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func configureDataSocket(_ socket: Int32) {
        disableSIGPIPE(socket)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    @discardableResult
    static func sendAll(_ socket: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(socket, base + offset, raw.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// 读到对方关闭为止;出错返回 nil。
    static func receiveAll(_ socket: Int32) -> Data? {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.recv(socket, &chunk, chunk.count, 0)
            if count > 0 {
                received.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                return received
            } else if errno != EINTR {
                return nil
            }
        }
    }

    /// 下载用的数据连接上客户端从不发东西:读得到东西(多半是 EOF 或 RST)就是它关了。
    static func peerHasClosed(_ socket: Int32) -> Bool {
        var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        var byte: UInt8 = 0
        let count = Darwin.recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count == 0 { return true }
        if count < 0 { return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR }
        return false
    }
}

/// 连进来就关:模拟吞掉数据连接的中间设备。
private final class LoopbackSink: @unchecked Sendable {
    let port: Int
    private let socket: Int32
    private let lock = NSLock()
    private var isStopped = false

    private init(socket: Int32, port: Int) {
        self.socket = socket
        self.port = port
    }

    static func start() throws -> LoopbackSink {
        let socket = try LoopbackFTPServer.makeListener(host: "127.0.0.1", port: 0)
        let sink = LoopbackSink(socket: socket, port: LoopbackFTPServer.boundPort(socket))
        Thread { [sink] in
            sink.run()
        }.start()
        return sink
    }

    func stop() {
        lock.withLock { isStopped = true }
    }

    private var stopped: Bool { lock.withLock { isStopped } }

    private func run() {
        defer { _ = Darwin.close(socket) }
        while !stopped {
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            let client = Darwin.accept(socket, nil, nil)
            if client >= 0 { _ = Darwin.close(client) }
        }
    }
}

/// 一条控制连接:只在自己的线程上用。
private final class LoopbackFTPControlConnection {
    private let server: LoopbackFTPServer
    private let socket: Int32
    private var buffer: [UInt8] = []
    private var pendingUser: String?
    private var isLoggedIn = false
    private var restartOffset = 0
    private var renameSource: String?
    private var passive: LoopbackFTPServer.Listener?
    private var activeTarget: LoopbackFTPServer.SocketAddress?

    init(server: LoopbackFTPServer, socket: Int32) {
        self.server = server
        self.socket = socket
    }

    func run() {
        reply("220 Primuse loopback FTP ready.")
        while let line = readLine() {
            guard handle(line) else { break }
        }
        closePassive()
    }

    // MARK: Commands

    /// 返回 false 表示这条连接该断了。
    private func handle(_ raw: [UInt8]) -> Bool {
        let text = server.decodeCommand(raw)
        let verb: String
        let argument: String
        if let space = text.firstIndex(of: " ") {
            verb = text[..<space].uppercased()
            argument = String(text[text.index(after: space)...])
        } else {
            verb = text.uppercased()
            argument = ""
        }
        let rawArgument = raw.firstIndex(of: 0x20).map { Data(raw[($0 + 1)...]) } ?? Data()
        server.record(command: verb)

        if server.consumeFailNextCommand() {
            reply("421 Service not available, closing control connection.")
            return false
        }

        let restart = restartOffset
        if verb != "REST", server.options.restartMustPrecedeTransfer || ["RETR", "STOR", "APPE"].contains(verb) {
            restartOffset = 0
        }

        switch verb {
        case "USER":
            pendingUser = argument
            isLoggedIn = false
            reply("331 Please specify the password.")
        case "PASS":
            guard let user = pendingUser else {
                reply("503 Login with USER first.")
                return true
            }
            if user == server.options.username, argument == server.options.password {
                isLoggedIn = true
                server.recordLogin(succeeded: true)
                reply("230 Login successful.")
            } else {
                server.recordLogin(succeeded: false)
                reply("530 Login incorrect.")
            }
        case "QUIT":
            reply("221 Goodbye.")
            return false
        case "SYST":
            reply("215 UNIX Type: L8")
        case "FEAT":
            replyFeatures()
        default:
            guard isLoggedIn else {
                reply("530 Please login with USER and PASS.")
                return true
            }
            handleCommand(verb, argument: argument, rawArgument: rawArgument, restart: restart)
        }
        return true
    }

    private func replyFeatures() {
        let options = server.options
        var lines = ["211-Features:"]
        if options.advertisesMLST { lines.append(" MLST type*;size*;modify*;") }
        if options.advertisesEPSV { lines.append(" EPSV") }
        if options.advertisesUTF8 { lines.append(" UTF8") }
        lines.append(" SIZE")
        lines.append(" REST STREAM")
        lines.append("211 End")
        reply(lines.joined(separator: "\r\n"))
    }

    private func handleCommand(_ verb: String, argument: String, rawArgument: Data, restart: Int) {
        let options = server.options
        let path = LoopbackFTPServer.normalize(argument)
        switch verb {
        case "OPTS":
            reply(options.advertisesUTF8 && argument.uppercased().hasPrefix("UTF8")
                ? "200 Always in UTF8 mode."
                : "501 Option not understood.")
        case "TYPE":
            reply("200 Switching to Binary mode.")
        case "PWD":
            reply("257 \"/\" is the current directory")
        case "CWD":
            reply(server.isDirectory(path) ? "250 Directory successfully changed." : "550 Failed to change directory.")
        case "NOOP":
            reply("200 NOOP ok.")
        case "PASV":
            openPassive(extended: false)
        case "EPSV":
            guard options.supportsEPSV else {
                reply("500 Unknown command.")
                return
            }
            openPassive(extended: true)
        case "PORT":
            guard options.supportsPORT else {
                reply("500 Unknown command.")
                return
            }
            setActiveTarget(Self.parsePORT(argument))
        case "EPRT":
            setActiveTarget(Self.parseEPRT(argument))
        case "REST":
            guard let offset = Int(argument), offset >= 0 else {
                reply("501 Bad REST argument.")
                return
            }
            restartOffset = offset
            reply("350 Restart position accepted (\(offset)).")
        case "SIZE":
            if let data = server.file(at: path) {
                reply("213 \(data.count)")
            } else {
                reply("550 Could not get file size.")
            }
        case "MLSD", "LIST":
            if verb == "MLSD", !options.supportsMLSD {
                reply("500 Unknown command.")
                return
            }
            guard let text = server.listing(of: path, machine: verb == "MLSD") else {
                reply("550 Failed to open directory.")
                return
            }
            let payload = server.encodeNames(text)
            transfer { socket in
                LoopbackFTPServer.sendAll(socket, payload)
                    ? "226 Directory send OK."
                    : "426 Connection closed; transfer aborted."
            }
        case "RETR":
            guard let content = server.file(at: path) else {
                reply("550 Failed to open file.")
                return
            }
            let start = min(restart, content.count)
            server.recordRetrieve(offset: start, rawPath: rawArgument)
            transfer { socket in send(content, from: start, over: socket) }
        case "STOR":
            transfer { socket in
                guard let received = LoopbackFTPServer.receiveAll(socket) else {
                    return "426 Connection closed; transfer aborted."
                }
                server.store(received, at: path)
                return "226 Transfer complete."
            }
        case "DELE":
            reply(server.removeFile(path) ? "250 Delete operation successful." : "550 Delete operation failed.")
        case "RNFR":
            guard server.exists(path) else {
                reply("550 RNFR command failed.")
                return
            }
            renameSource = path
            reply("350 Ready for RNTO.")
        case "RNTO":
            guard let source = renameSource else {
                reply("503 RNFR required first.")
                return
            }
            renameSource = nil
            reply(server.moveFile(source, to: path) ? "250 Rename successful." : "550 Rename failed.")
        default:
            reply("502 Command not implemented.")
        }
    }

    // MARK: Data connections

    /// 150 → 建数据连接 → `body` 收发 → 关数据连接 → 回 `body` 给的结果。
    private func transfer(_ body: (Int32) -> String) {
        reply("150 Opening BINARY mode data connection.")
        if activeTarget != nil, server.options.activeModeNeverConnects {
            activeTarget = nil
            return
        }
        guard let socket = openDataConnection() else {
            reply("425 Can't open data connection.")
            return
        }
        let result = body(socket)
        _ = Darwin.close(socket)
        reply(result)
    }

    private func send(_ content: Data, from start: Int, over socket: Int32) -> String {
        let options = server.options
        var position = start
        while position < content.count {
            if LoopbackFTPServer.peerHasClosed(socket) {
                server.recordAbort()
                return "426 Connection closed; transfer aborted."
            }
            let end = min(content.count, position + options.retrieveChunkSize)
            guard LoopbackFTPServer.sendAll(socket, content.subdata(in: position..<end)) else {
                server.recordAbort()
                return "426 Connection closed; transfer aborted."
            }
            position = end
            if options.retrieveChunkDelay > 0 { Thread.sleep(forTimeInterval: options.retrieveChunkDelay) }
        }
        return "226 Transfer complete."
    }

    private func openPassive(extended: Bool) {
        closePassive()
        activeTarget = nil
        guard let listener = try? LoopbackFTPServer.listenOnLoopback() else {
            reply("425 Can't open passive connection.")
            return
        }
        passive = listener
        if extended {
            reply("229 Entering Extended Passive Mode (|||\(listener.port)|)")
        } else {
            let options = server.options
            let port = options.passiveReplyPort ?? listener.port
            let host = options.passiveReplyAddress.replacingOccurrences(of: ".", with: ",")
            reply("227 Entering Passive Mode (\(host),\(port / 256),\(port % 256)).")
        }
    }

    private func closePassive() {
        passive?.sockets.forEach { _ = Darwin.close($0) }
        passive = nil
    }

    private func setActiveTarget(_ target: LoopbackFTPServer.SocketAddress?) {
        guard let target else {
            reply("501 Illegal PORT command.")
            return
        }
        closePassive()
        activeTarget = target
        reply("200 PORT command successful.")
    }

    private func openDataConnection() -> Int32? {
        if let listener = passive {
            passive = nil
            defer { listener.sockets.forEach { _ = Darwin.close($0) } }
            var descriptors = listener.sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let timeout = Int32(server.options.passiveAcceptTimeout * 1000)
            guard poll(&descriptors, nfds_t(descriptors.count), timeout) > 0,
                  let ready = descriptors.first(where: { $0.revents & Int16(POLLIN) != 0 }) else { return nil }
            let socket = Darwin.accept(ready.fd, nil, nil)
            guard socket >= 0 else { return nil }
            LoopbackFTPServer.configureDataSocket(socket)
            return socket
        }
        if let target = activeTarget {
            activeTarget = nil
            let socket = Darwin.socket(Int32(target.storage.ss_family), SOCK_STREAM, IPPROTO_TCP)
            guard socket >= 0 else { return nil }
            let length = target.length
            let connected = withUnsafePointer(to: target.storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, length) }
            }
            guard connected == 0 else {
                _ = Darwin.close(socket)
                return nil
            }
            LoopbackFTPServer.configureDataSocket(socket)
            return socket
        }
        return nil
    }

    static func parsePORT(_ argument: String) -> LoopbackFTPServer.SocketAddress? {
        let numbers = argument.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let host = numbers[0...3].map(String.init).joined(separator: ".")
        return LoopbackFTPServer.socketAddress(host: host, port: numbers[4] * 256 + numbers[5])
    }

    /// `EPRT |1|127.0.0.1|5282|` / `EPRT |2|::1|5282|`。
    static func parseEPRT(_ argument: String) -> LoopbackFTPServer.SocketAddress? {
        guard let delimiter = argument.first else { return nil }
        let fields = argument.split(separator: delimiter, omittingEmptySubsequences: false)
        guard fields.count >= 4, let port = Int(fields[3]), port > 0 else { return nil }
        return LoopbackFTPServer.socketAddress(host: String(fields[2]), port: port)
    }

    // MARK: Control channel

    private func reply(_ text: String) {
        LoopbackFTPServer.sendAll(socket, Data((text + "\r\n").utf8))
    }

    private func readLine() -> [UInt8]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = Array(buffer[..<newline])
                buffer.removeFirst(newline + 1)
                if line.last == 0x0D { line.removeLast() }
                return line
            }
            if server.stopped { return nil }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.recv(socket, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
#endif
