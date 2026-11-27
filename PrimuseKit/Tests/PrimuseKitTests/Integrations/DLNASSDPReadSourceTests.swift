import Darwin
import Foundation
import Synchronization
import Testing
@testable import PrimuseKit

@Suite("SSDP receive socket")
struct DLNASSDPReadSourceTests {
    private func receiver(
        onPacket: @escaping @Sendable (String, String, UInt16) -> Void = { _, _, _ in },
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> DLNASSDPReadSource {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        try #require(fd >= 0)
        return DLNASSDPReadSource(owning: fd, onPacket: onPacket, onFailure: onFailure)
    }

    @Test func readsNextIPv4DatagramAfterEmptyDatagram() throws {
        let received = DispatchSemaphore(value: 0)
        let messages = Mutex([String]())
        let reader = try receiver { message, host, port in
            messages.withLock { $0.append("\(message)@\(host):\(port)") }
            received.signal()
        }
        defer { reader.cancel() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = reader.fileDescriptor
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { endpoint in
                try #require(Darwin.bind(fd, endpoint, length) == 0)
                let result = Darwin.getsockname(fd, endpoint, &length)
                try #require(result == 0)
                try #require(Darwin.connect(fd, endpoint, length) == 0)
            }
        }
        var byte: UInt8 = 65
        let empty = Darwin.send(fd, &byte, 0, 0)
        let packet = Darwin.send(fd, &byte, 1, 0)
        try #require(empty == 0 && packet == 1)
        reader.activate()
        try #require(received.wait(timeout: .now() + 2) == .success)
        #expect(messages.withLock { $0 } == ["A@127.0.0.1:\(UInt16(bigEndian: address.sin_port))"])
        #expect(!reader.isCancelled)
    }

    @Test func retiresTerminalSocketImmediatelyAndReportsOnlyOnce() throws {
        for result in [(count: -1, error: ENETDOWN), (count: 0, error: 0)] {
            let failures = Mutex(0)
            let reader = try receiver(onFailure: { _ in failures.withLock { $0 += 1 } })
            _ = reader.handleReadResult(count: result.count, errorCode: result.error, hasPeer: false)
            #expect(reader.isCancelled)
            _ = reader.handleReadResult(count: -1, errorCode: EBADF, hasPeer: false)
            #expect(failures.withLock { $0 } == 1)
        }
    }

    @Test func retiresRapidUnproductiveReadsWhilePreservingIsolatedTransients() throws {
        let start = ContinuousClock.now
        let reader = try receiver()
        for index in 0..<12 {
            let instant = start.advanced(by: .seconds(index * 2))
            #expect(reader.handleReadResult(count: -1, errorCode: EINTR, hasPeer: false, now: instant) == .retry)
            #expect(reader.handleReadResult(count: -1, errorCode: EAGAIN, hasPeer: false, now: instant) == .done)
        }
        let burst = start.advanced(by: .seconds(30))
        for _ in 0..<7 {
            _ = reader.handleReadResult(count: -1, errorCode: EAGAIN, hasPeer: false, now: burst)
        }
        #expect(!reader.isCancelled)
        _ = reader.handleReadResult(count: 0, errorCode: 0, hasPeer: true, now: burst)
        for _ in 0..<7 {
            _ = reader.handleReadResult(count: -1, errorCode: EAGAIN, hasPeer: false, now: burst)
        }
        #expect(!reader.isCancelled)
        _ = reader.handleReadResult(count: -1, errorCode: EAGAIN, hasPeer: false, now: burst)
        #expect(reader.isCancelled)
    }

    @Test func stopKeepsDescriptorLeasedUntilOwnerReleasesReader() throws {
        var sockets: [Int32] = [-1, -1]
        let result = Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
        try #require(result == 0)
        defer { Darwin.close(sockets[1]) }
        var reader: DLNASSDPReadSource? = DLNASSDPReadSource(
            owning: sockets[0], onPacket: { _, _, _ in }, onFailure: { _ in }
        )
        reader?.activate()
        reader?.cancel()
        var peer = pollfd(fd: sockets[1], events: Int16(POLLIN), revents: 0)
        let beforeRelease = Darwin.poll(&peer, 1, 0)
        #expect(beforeRelease == 0)
        reader = nil
        let afterRelease = Darwin.poll(&peer, 1, 2000)
        #expect(afterRelease == 1)
        var byte: UInt8 = 0
        let endOfStream = Darwin.recv(sockets[1], &byte, 1, MSG_DONTWAIT)
        #expect(endOfStream == 0)
    }
}
