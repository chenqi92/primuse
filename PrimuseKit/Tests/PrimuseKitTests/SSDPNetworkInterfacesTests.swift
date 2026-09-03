import Darwin
import Foundation
import Testing
@testable import PrimuseKit

@Suite("SSDP network interface selection")
struct SSDPNetworkInterfacesTests {
    @Test func filtersUnavailableLoopbackAndTunnelInterfaces() {
        let usableFlags = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
        let candidates = [
            candidate("en0", "192.168.1.20", flags: usableFlags),
            candidate("en2", "10.0.0.20", flags: UInt32(IFF_UP | IFF_MULTICAST)),
            candidate("lo0", "127.0.0.1", flags: usableFlags | UInt32(IFF_LOOPBACK)),
            candidate("utun8", "198.18.0.1", flags: usableFlags | UInt32(IFF_POINTOPOINT)),
        ]

        let selected = SSDPIPv4InterfacePolicy.selectUsableInterfaces(from: candidates)

        #expect(selected.map(\.name) == ["en0"])
    }

    @Test func keepsEveryUsableLANInterfaceInStablePriorityOrder() {
        let flags = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
        let candidates = [
            candidate("bridge0", "172.16.0.2", flags: flags),
            candidate("en7", "10.0.0.2", flags: flags),
            candidate("en1", "192.168.2.2", flags: flags),
            candidate("en0", "192.168.1.2", flags: flags),
        ]

        let selected = SSDPIPv4InterfacePolicy.selectUsableInterfaces(from: candidates)

        #expect(selected.map(\.name) == ["en0", "en1", "en7", "bridge0"])
    }

    @Test func deduplicatesAddressesAndPrefersHigherPriorityInterface() {
        let flags = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
        let candidates = [
            candidate("bridge0", "192.168.1.2", flags: flags),
            candidate("en0", "192.168.1.2", flags: flags),
        ]

        let selected = SSDPIPv4InterfacePolicy.selectUsableInterfaces(from: candidates)

        #expect(selected.count == 1)
        #expect(selected.first?.name == "en0")
    }

    @Test func fallsBackToExistingDefaultRouteBehaviorWithoutLANInterfaces() {
        let selected = SSDPIPv4InterfacePolicy.discoveryCandidates(from: [])

        #expect(selected == [.defaultRoute])
    }

    @Test func rejectsRemoteLoopbackAndUnspecifiedLocations() throws {
        let loopback = try #require(URL(string: "http://127.0.0.1:8096/device.xml"))
        let unspecified = try #require(URL(string: "http://0.0.0.0:8096/device.xml"))

        #expect(!SSDPLocationPolicy.isUsable(location: loopback, responseHost: "192.168.1.20"))
        #expect(!SSDPLocationPolicy.isUsable(location: unspecified, responseHost: "192.168.1.20"))
    }

    @Test func preservesLoopbackLocationsAdvertisedByThisHost() throws {
        let loopback = try #require(URL(string: "http://localhost:8096/device.xml"))

        #expect(SSDPLocationPolicy.isUsable(location: loopback, responseHost: "127.0.0.1"))
        #expect(
            SSDPLocationPolicy.isUsable(
                location: loopback,
                responseHost: "192.168.1.2",
                localInterfaceHosts: ["192.168.1.2"]
            )
        )
    }

    @Test func acceptsReachableLANLocations() throws {
        let location = try #require(URL(string: "http://192.168.1.20:8096/device.xml"))

        #expect(SSDPLocationPolicy.isUsable(location: location, responseHost: "192.168.1.20"))
    }

    private func candidate(
        _ name: String,
        _ address: String,
        flags: UInt32
    ) -> SSDPIPv4InterfaceCandidate {
        SSDPIPv4InterfaceCandidate(
            interface: SSDPIPv4Interface(
                name: name,
                address: inet_addr(address),
                addressString: address
            ),
            flags: flags
        )
    }
}
