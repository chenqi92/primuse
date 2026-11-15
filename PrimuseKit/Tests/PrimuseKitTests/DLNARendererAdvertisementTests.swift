import Foundation
import Network
import os
import Testing
@testable import PrimuseKit

@Suite("DLNA receiver discovery")
struct DLNARendererAdvertisementTests {
    @Test func publishesOnlyAReadyListenerAndWithdrawsStaleURLs() {
        var receiver = DLNARendererAdvertisement()
        #expect(receiver.location(host: "192.168.1.2") == nil)
        receiver.listenerReady(port: 49152)
        #expect(receiver.location(host: "192.168.1.2") == "http://192.168.1.2:49152/device.xml")
        receiver.listenerUnavailable(addressInUse: true)
        #expect(receiver.requestedPort == nil)
        #expect(receiver.location(host: "192.168.1.2") == nil)
        receiver.listenerReady(port: 52345)
        #expect(receiver.location(host: "192.168.1.2") == "http://192.168.1.2:52345/device.xml")
        receiver.listenerUnavailable()
        #expect(receiver.location(host: "192.168.1.2") == nil)
    }

    @Test func otherFailuresKeepPreferredPortAndZeroIsNeverAdvertised() {
        var receiver = DLNARendererAdvertisement()
        receiver.listenerUnavailable()
        #expect(receiver.requestedPort == 49152)
        receiver.listenerReady(port: 0)
        #expect(receiver.location(host: "192.168.1.2") == nil)
    }

    @Test func targetedSearchDoesNotReturnUnrelatedServices() {
        let type = "urn:schemas-upnp-org:device:MediaRenderer:1"
        #expect(DLNARendererAdvertisement.responseTypes(searchTarget: type, uuid: "receiver") == [type])
        #expect(DLNARendererAdvertisement.responseTypes(searchTarget: "uuid:receiver", uuid: "receiver") == ["uuid:receiver"])
        #expect(DLNARendererAdvertisement.responseTypes(searchTarget: "ssdp:all", uuid: "receiver").count == 6)
    }

    @Test(arguments: ["", "urn:schemas-upnp-org:device:MediaRenderer:2", "prefix-ssdp:all", "uuid:another"])
    func unrelatedSearchIsIgnored(target: String) {
        #expect(DLNARendererAdvertisement.responseTypes(searchTarget: target, uuid: "receiver").isEmpty)
    }

    @Test func receiverNamesPreserveUnicodeAndBoundUntrustedInput() {
        #expect(DLNARendererAdvertisement.normalizedName("  客厅 · 音乐 🎵  ", fallback: "Primuse") == "客厅 · 音乐 🎵")
        #expect(DLNARendererAdvertisement.normalizedName(" \n\t ", fallback: "Primuse") == "Primuse")
        #expect(DLNARendererAdvertisement.normalizedName("Living\nRoom", fallback: "Primuse") == "Living Room")
        #expect(DLNARendererAdvertisement.normalizedName(String(repeating: "乐", count: 100), fallback: "Primuse").count == 63)
    }

    @Test func occupiedTCPPortFallsBackToAReachableSystemAssignedPort() throws {
        let occupant = try NWListener(using: .tcp, on: .any)
        defer { occupant.cancel() }
        guard case .ready = try start(occupant) else {
            Issue.record("Could not establish the occupying TCP listener")
            return
        }
        let occupiedPort = try #require(occupant.port)
        var receiver = DLNARendererAdvertisement(preferredPort: occupiedPort.rawValue)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let blocked = try NWListener(using: parameters, on: occupiedPort)
        defer { blocked.cancel() }
        guard case .failed(.posix(.EADDRINUSE)) = try start(blocked) else {
            Issue.record("Expected an actual address-in-use failure")
            return
        }
        receiver.listenerUnavailable(addressInUse: true)
        #expect(receiver.location(host: "127.0.0.1") == nil)
        let fallback = try NWListener(
            using: .tcp,
            on: receiver.requestedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        )
        defer { fallback.cancel() }
        guard case .ready = try start(fallback) else {
            Issue.record("System-assigned listener failed to start")
            return
        }
        let port = try #require(fallback.port)
        #expect(port != occupiedPort)
        receiver.listenerReady(port: port.rawValue)
        let location = try #require(receiver.location(host: "127.0.0.1"))
        #expect(URL(string: location)?.port == Int(port.rawValue))

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { connection.cancel() }
        let connected = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state { connected.signal() }
        }
        connection.start(queue: .global())
        #expect(connected.wait(timeout: .now() + 5) == .success)
    }

    private enum ListenerTestError: Error { case timeout }

    private func start(_ listener: NWListener) throws -> NWListener.State {
        let result = OSAllocatedUnfairLock<NWListener.State?>(initialState: nil)
        let completed = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                result.withLock { $0 = state }
                completed.signal()
            default: break
            }
        }
        listener.start(queue: .global())
        guard completed.wait(timeout: .now() + 5) == .success,
              let state = result.withLock({ $0 }) else { throw ListenerTestError.timeout }
        return state
    }
}
