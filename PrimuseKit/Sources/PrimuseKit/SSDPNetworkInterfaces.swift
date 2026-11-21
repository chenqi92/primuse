import Darwin
import Foundation

public struct SSDPIPv4Interface: Hashable, Sendable {
    public let name: String
    public let address: UInt32
    public let addressString: String

    public init(name: String, address: UInt32, addressString: String) {
        self.name = name
        self.address = address
        self.addressString = addressString
    }

    public static let defaultRoute = SSDPIPv4Interface(
        name: "default",
        address: INADDR_ANY,
        addressString: "0.0.0.0"
    )
}

public enum SSDPNetworkInterfaces {
    public static func activeIPv4MulticastInterfaces() -> [SSDPIPv4Interface] {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else {
            return []
        }
        defer { freeifaddrs(interfaceList) }

        var candidates: [SSDPIPv4InterfaceCandidate] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let node = current {
            defer { current = node.pointee.ifa_next }
            guard let socketAddress = node.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let ipv4Address = UnsafeRawPointer(socketAddress)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee
                .sin_addr
            let addressString = string(from: ipv4Address)
            guard addressString.isEmpty == false else {
                continue
            }

            candidates.append(
                SSDPIPv4InterfaceCandidate(
                    interface: SSDPIPv4Interface(
                        name: String(cString: node.pointee.ifa_name),
                        address: ipv4Address.s_addr,
                        addressString: addressString
                    ),
                    flags: UInt32(node.pointee.ifa_flags)
                )
            )
        }

        return SSDPIPv4InterfacePolicy.selectUsableInterfaces(from: candidates)
    }

    public static func discoveryCandidates() -> [SSDPIPv4Interface] {
        SSDPIPv4InterfacePolicy.discoveryCandidates(
            from: activeIPv4MulticastInterfaces()
        )
    }

    fileprivate static func string(from address: in_addr) -> String {
        var copy = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(buffer.count)) != nil else {
            return ""
        }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return "" }
            return String(cString: baseAddress)
        }
    }
}

public final class DLNASSDPReadSource: @unchecked Sendable {
    public var fileDescriptor: Int32 { socket.fileDescriptor }
    private let socket: FileHandle
    private let source: DispatchSourceRead
    private let onPacket: @Sendable (String, String, UInt16) -> Void
    private let onFailure: @Sendable (String) -> Void

    // The source's serial queue owns the receive buffer and the failure streak.
    private var buffer = [UInt8](repeating: 0, count: 65_536)
    private var firstUnproductiveRead: ContinuousClock.Instant?
    private var unproductiveReads = 0

    public init(
        owning fd: Int32,
        onPacket: @escaping @Sendable (String, String, UInt16) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        let socket = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.socket = socket
        self.onPacket = onPacket
        self.onFailure = onFailure
        source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: DispatchQueue(label: "com.welape.primuse.dlna.ssdp", qos: .utility)
        )
        source.setEventHandler { [weak self] in self?.readDatagram() }
        // The main actor can still be sending until it releases this receiver.
        // The read queue also needs the descriptor until cancellation completes.
        source.setCancelHandler { withExtendedLifetime(socket) {} }
    }

    public func activate() { source.activate() }
    public func cancel() { source.cancel() }
    var isCancelled: Bool { source.isCancelled }

    deinit {
        source.cancel()
        source.activate()
    }

    private func readDatagram() {
        while !source.isCancelled {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &peer) { sender in
                    sender.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fileDescriptor, bytes.baseAddress, bytes.count, MSG_DONTWAIT, $0, &length)
                    }
                }
            }
            let errorCode = count < 0 ? errno : 0
            let hasPeer = length >= socklen_t(MemoryLayout<sockaddr_in>.size)
                && peer.sin_family == sa_family_t(AF_INET)
            switch handleReadResult(count: count, errorCode: errorCode, hasPeer: hasPeer) {
            case .retry:
                continue
            case .packet:
                if hasPeer, let message = String(bytes: buffer.prefix(count), encoding: .utf8) {
                    let host = SSDPNetworkInterfaces.string(from: peer.sin_addr)
                    onPacket(message, host, UInt16(bigEndian: peer.sin_port))
                }
            case .done:
                break
            }
            return
        }
    }

    enum ReadAction: Equatable { case packet, retry, done }

    func handleReadResult(
        count: Int, errorCode: Int32, hasPeer: Bool, now: ContinuousClock.Instant? = nil
    ) -> ReadAction {
        guard !source.isCancelled else { return .done }
        // A zero-length UDP datagram still carries its sender's address.
        if count > 0 || (count == 0 && hasPeer) {
            firstUnproductiveRead = nil
            return count > 0 ? .packet : .done
        }
        if count < 0 && (errorCode == EINTR || errorCode == EAGAIN || errorCode == EWOULDBLOCK) {
            let now = now ?? .now
            if let firstUnproductiveRead, firstUnproductiveRead.duration(to: now) < .seconds(1) {
                unproductiveReads += 1
            } else {
                firstUnproductiveRead = now
                unproductiveReads = 1
            }
            // A healthy source waits for the next readiness notification after EAGAIN.
            if unproductiveReads < 8 { return errorCode == EINTR ? .retry : .done }
        }
        source.cancel()
        onFailure(count == 0 ? "zero-byte read without IPv4 peer" : "recvfrom errno=\(errorCode)")
        return .done
    }
}

public enum SSDPLocationPolicy {
    public static func isUsable(
        location: URL,
        responseHost: String,
        localInterfaceHosts: Set<String> = []
    ) -> Bool {
        guard let locationHost = location.host?.lowercased(),
              locationHost.isEmpty == false,
              isUnspecified(locationHost) == false else {
            return false
        }
        guard isLoopback(locationHost) else { return true }

        let normalizedResponseHost = responseHost.lowercased()
        return isLoopback(normalizedResponseHost)
            || localInterfaceHosts.map { $0.lowercased() }.contains(normalizedResponseHost)
    }

    private static func isUnspecified(_ host: String) -> Bool {
        host == "0.0.0.0" || host == "::" || host == "[::]"
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost"
            || host == "localhost."
            || host == "::1"
            || host == "[::1]"
            || host.hasPrefix("127.")
    }
}

public enum SSDPRemoteRendererDiscoveryMode: Sendable {
    case sharedReceiverSocket
    case standalone
}

public enum SSDPRemoteRendererDiscoveryPolicy {
    public static func mode(
        receiverSocketAvailable: Bool
    ) -> SSDPRemoteRendererDiscoveryMode {
        receiverSocketAvailable ? .sharedReceiverSocket : .standalone
    }
}

struct SSDPIPv4InterfaceCandidate: Sendable {
    let interface: SSDPIPv4Interface
    let flags: UInt32
}

enum SSDPIPv4InterfacePolicy {
    static func selectUsableInterfaces(
        from candidates: [SSDPIPv4InterfaceCandidate]
    ) -> [SSDPIPv4Interface] {
        let requiredFlags = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
        let rejectedFlags = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)

        var interfacesByAddress: [UInt32: SSDPIPv4Interface] = [:]
        for candidate in candidates {
            guard candidate.flags & requiredFlags == requiredFlags,
                  candidate.flags & rejectedFlags == 0,
                  candidate.interface.address != INADDR_ANY else {
                continue
            }

            if let existing = interfacesByAddress[candidate.interface.address] {
                if sortKey(for: candidate.interface) < sortKey(for: existing) {
                    interfacesByAddress[candidate.interface.address] = candidate.interface
                }
            } else {
                interfacesByAddress[candidate.interface.address] = candidate.interface
            }
        }

        return interfacesByAddress.values.sorted {
            sortKey(for: $0) < sortKey(for: $1)
        }
    }

    static func discoveryCandidates(
        from interfaces: [SSDPIPv4Interface]
    ) -> [SSDPIPv4Interface] {
        interfaces.isEmpty ? [.defaultRoute] : interfaces
    }

    private static func sortKey(for interface: SSDPIPv4Interface) -> String {
        let priority: Int
        switch interface.name {
        case "en0": priority = 0
        case "en1": priority = 1
        default:
            if interface.name.hasPrefix("en") {
                priority = 2
            } else if interface.name.hasPrefix("bridge") {
                priority = 3
            } else {
                priority = 4
            }
        }
        return String(format: "%02d-%@-%08x", priority, interface.name, interface.address)
    }
}
