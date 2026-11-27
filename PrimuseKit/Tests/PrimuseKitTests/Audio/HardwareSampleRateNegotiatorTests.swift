import Foundation
import Testing
@testable import PrimuseKit

@Suite("Hardware sample rate negotiation")
@MainActor
struct HardwareSampleRateNegotiatorTests {
    @MainActor private final class Device {
        var snapshot: HardwareSampleRateNegotiator.Snapshot? = .init(deviceID: 1, sampleRate: 48_000)
        var listener: (@Sendable (HardwareSampleRateNegotiator.Event) -> Void)?
        var requests = 0
        var removals = 0
        var acceptsRequest = true
        var onRequest: (() -> Void)?

        func observe(_ listener: @escaping @Sendable (HardwareSampleRateNegotiator.Event) -> Void) throws -> @MainActor () -> Void {
            self.listener = listener
            return { self.listener = nil; self.removals += 1 }
        }

        func request() -> Bool {
            requests += 1
            #expect(listener != nil, "The listener must be installed before the HAL write")
            onRequest?()
            return acceptsRequest
        }

        func change(to rate: Double) {
            snapshot = .init(deviceID: 1, sampleRate: rate)
            listener?(.sampleRateChanged)
        }
    }

    private func negotiate(
        _ device: Device, using negotiator: HardwareSampleRateNegotiator = .init(),
        timeout: Duration = .seconds(1)
    ) async throws -> HardwareSampleRateNegotiator.Result {
        try await negotiator.prepare(
            targetSampleRate: 44_100, deviceID: 1, timeout: timeout,
            readSnapshot: { device.snapshot },
            observe: { try device.observe($0) },
            requestChange: { device.request() }
        )
    }

    @Test("A delayed HAL notification prevents a graph from using the old format")
    func waitsForDelayedNotification() async throws {
        let device = Device()
        var returned = false
        let request = Task {
            let result = try await negotiate(device)
            returned = true
            return result
        }
        while device.requests == 0 { await Task.yield() }
        #expect(!returned)
        // An unrelated notification must not complete the rate change.
        device.listener?(.deviceChanged)
        await Task.yield()
        #expect(!returned)
        device.change(to: 44_100)
        let result = try await request.value
        #expect(result.reason == .confirmed)
        #expect(result.snapshot?.sampleRate == 44_100)
        #expect(device.removals == 1)
    }

    @Test("A notification delivered inside the property setter is not lost")
    func synchronousNotification() async throws {
        let device = Device()
        device.onRequest = { device.change(to: 44_100) }
        let result = try await negotiate(device)
        #expect(result.reason == .confirmed)
        #expect(device.removals == 1)
    }

    @Test("An intermediate rate notification keeps waiting for the requested rate")
    func intermediateRate() async throws {
        let device = Device()
        let request = Task { try await negotiate(device) }
        while device.requests == 0 { await Task.yield() }
        device.change(to: 96_000)
        await Task.yield()
        device.change(to: 44_100)
        #expect(try await request.value.snapshot?.sampleRate == 44_100)
    }

    @Test("Rejected writes return the actual format and remove the listener")
    func rejected() async throws {
        let device = Device()
        device.acceptsRequest = false
        let result = try await negotiate(device)
        #expect(result.reason == .rejected)
        #expect(result.snapshot?.sampleRate == 48_000)
        #expect(device.removals == 1)
    }

    @Test("Missing notifications have a bounded timeout, even if a read shows the target")
    func timeout() async throws {
        let device = Device()
        device.onRequest = { device.snapshot = .init(deviceID: 1, sampleRate: 44_100) }
        let result = try await negotiate(device, timeout: .milliseconds(10))
        #expect(result.reason == .timedOut)
        #expect(result.snapshot?.sampleRate == 44_100)
        #expect(device.removals == 1)
    }

    @Test("Route replacement and device removal wake the waiter")
    func deviceChanges() async throws {
        for replacement in [HardwareSampleRateNegotiator.Snapshot(deviceID: 2, sampleRate: 96_000), nil] {
            let device = Device()
            let request = Task { try await negotiate(device) }
            while device.requests == 0 { await Task.yield() }
            device.snapshot = replacement
            device.listener?(.deviceChanged)
            let result = try await request.value
            #expect(result.reason == (replacement == nil ? .deviceUnavailable : .deviceChanged))
            #expect(result.snapshot == replacement)
            #expect(device.removals == 1)
        }
    }

    @Test("Cancellation cleans up immediately without waiting for the timeout")
    func cancellation() async throws {
        let device = Device()
        let request = Task { try await negotiate(device) }
        while device.requests == 0 { await Task.yield() }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(device.removals == 1)
    }

    @Test("A newer request supersedes the old one; stale cleanup cannot cancel the new request")
    func superseded() async throws {
        let negotiator = HardwareSampleRateNegotiator()
        let oldDevice = Device()
        let newDevice = Device()
        let old = Task { try await negotiate(oldDevice, using: negotiator) }
        while oldDevice.requests == 0 { await Task.yield() }
        let new = Task { try await negotiate(newDevice, using: negotiator) }
        while newDevice.requests == 0 { await Task.yield() }
        await #expect(throws: CancellationError.self) { try await old.value }
        newDevice.change(to: 44_100)
        #expect(try await new.value.reason == .confirmed)
        #expect(oldDevice.removals == 1)
        #expect(newDevice.removals == 1)
    }

    @Test("Pause explicitly cancels the active negotiation")
    func explicitCancellation() async throws {
        let negotiator = HardwareSampleRateNegotiator()
        let device = Device()
        let request = Task { try await negotiate(device, using: negotiator) }
        while device.requests == 0 { await Task.yield() }
        negotiator.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(device.removals == 1)
    }

    @Test("Failure to register an observer must not send an unobservable write")
    func observerFailure() async throws {
        struct ObserverError: Error {}
        let device = Device()
        let result = try await HardwareSampleRateNegotiator().prepare(
            targetSampleRate: 44_100, deviceID: 1,
            readSnapshot: { device.snapshot },
            observe: { _ in throw ObserverError() },
            requestChange: { device.request() }
        )
        #expect(result.reason == .observationUnavailable)
        #expect(device.requests == 0)
    }

    @Test("An already cancelled request cannot touch the hardware")
    func cancelledBeforeRequest() async throws {
        let device = Device()
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await negotiate(device)
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(device.requests == 0)
        #expect(device.listener == nil)
    }

    @Test("An already matching device needs no write or notification")
    func alreadyMatches() async throws {
        let device = Device()
        device.snapshot = .init(deviceID: 1, sampleRate: 44_100)
        #expect(try await negotiate(device).reason == .unchanged)
        #expect(device.requests == 0)
        #expect(device.removals == 1)
    }

    @Test("A route replaced before the request must not receive the old rate request")
    func replacedBeforeRequest() async throws {
        let device = Device()
        device.snapshot = .init(deviceID: 2, sampleRate: 96_000)
        #expect(try await negotiate(device).reason == .deviceChanged)
        #expect(device.requests == 0)
        #expect(device.removals == 1)
    }
}
