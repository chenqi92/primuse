import Foundation

/// Keeps discovery URLs tied to a listener that has actually become ready.
public struct DLNARendererAdvertisement: Sendable {
    public private(set) var requestedPort: UInt16?
    public private(set) var listeningPort: UInt16?

    public init(preferredPort: UInt16 = 49152) {
        requestedPort = preferredPort
    }

    public mutating func listenerReady(port: UInt16) {
        listeningPort = port == 0 ? nil : port
    }

    public mutating func listenerUnavailable(addressInUse: Bool = false) {
        listeningPort = nil
        if addressInUse { requestedPort = nil }
    }

    public func location(host: String) -> String? {
        guard let listeningPort, !host.isEmpty else { return nil }
        return "http://\(host):\(listeningPort)/device.xml"
    }

    public static func deviceTypes(uuid: String) -> [String] {
        [
            "upnp:rootdevice",
            "uuid:\(uuid)",
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            "urn:schemas-upnp-org:service:AVTransport:1",
            "urn:schemas-upnp-org:service:RenderingControl:1",
            "urn:schemas-upnp-org:service:ConnectionManager:1",
        ]
    }

    public static func responseTypes(searchTarget: String, uuid: String) -> [String] {
        let target = searchTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let types = deviceTypes(uuid: uuid)
        if target.caseInsensitiveCompare("ssdp:all") == .orderedSame { return types }
        return types.filter { $0.caseInsensitiveCompare(target) == .orderedSame }
    }

    public static func normalizedName(_ value: String, fallback: String) -> String {
        let name = value.components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? fallback : name).prefix(63))
    }
}
