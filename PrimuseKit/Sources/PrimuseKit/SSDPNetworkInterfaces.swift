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

    private static func string(from address: in_addr) -> String {
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
