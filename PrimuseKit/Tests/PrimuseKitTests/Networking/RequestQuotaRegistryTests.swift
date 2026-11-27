import Foundation
import Testing
@testable import PrimuseKit

@Suite("Shared service quota ownership")
struct RequestQuotaRegistryTests {
    @Test func capacityRetainsCooldownUntilTheOriginalDeadline() async throws {
        let clock = ControlledClock()
        let registry = RequestQuotaRegistry(maximumQuotas: 1, timing: clock.timing)
        let service = RequestQuota.Service(id: "catalog", policy: .init())
        let limited = RequestQuota(service: service, url: URL(string: "https://first.invalid/search")!)!
        let other = RequestQuota(service: service, url: URL(string: "https://second.invalid/search")!)!
        do {
            _ = try await registry.execute(for: limited, operation: { () -> Int in
                throw HTTPResponseFailure(statusCode: 429, retryAfter: 3600)
            })
            Issue.record("Expected the server cooldown")
        } catch let failure as HTTPResponseFailure { #expect(failure.retryAfter == 3600) }
        do {
            _ = try await registry.execute(for: other, operation: { 2 })
            Issue.record("An active cooldown must not be evicted to admit another host")
        } catch RequestExecutor.AdmissionError.queueFull { }
        clock.advance(to: 3599)
        let admitted = Task {
            try await registry.execute(for: limited, operation: { clock.recordStart(); return 3 })
        }
        defer { admitted.cancel() }
        try await clock.waitForSleep(at: 3600)
        #expect(clock.starts.isEmpty, "Admission must preserve the original quota deadline")
        clock.advance(to: 3600)
        #expect(try await admitted.value == 3)
        #expect(clock.starts == [3600])
        #expect(try await registry.execute(for: other, operation: { 4 }) == 4,
                "An expired idle entry must make room for another endpoint")
    }

    @Test func aServiceCannotSilentlyChangeItsPolicyAcrossFeatures() async throws {
        let registry = RequestQuotaRegistry()
        let url = URL(string: "https://catalog.invalid/search")!
        let first = RequestQuota(service: .init(id: "catalog", policy: .init()), url: url)!
        let conflicting = RequestQuota(service: .init(id: "catalog", policy: .init(rateLimitStatusCodes: [403])), url: url)!
        _ = try await registry.execute(for: first, operation: { 1 })
        do {
            _ = try await registry.execute(for: conflicting, operation: {
                Issue.record("Conflicting policy reached the transport")
                return 2
            })
            Issue.record("Expected a policy ownership error")
        } catch RequestQuotaRegistry.ConfigurationError.conflictingPolicy { }
    }

    @Test func stableAccountsAndCanonicalEndpointsShareOnlyTheirOwnServiceQuota() async throws {
        let registry = RequestQuotaRegistry()
        let service = RequestQuota.Service(id: "provider", policy: .init())
        let url = URL(string: "https://EXAMPLE.invalid:443/search?credential=discarded")!
        let first = RequestQuota(service: service, url: url, account: .init(stableID: "alice"))!
        do {
            _ = try await registry.execute(for: first, operation: { () -> Int in
                throw HTTPResponseFailure(statusCode: 429, retryAfter: 3600)
            })
        } catch let failure as HTTPResponseFailure { #expect(failure.statusCode == 429) }
        let same = RequestQuota(service: service, url: URL(string: "https://example.invalid/lookup?credential=changed")!, account: .init(stableID: "alice"))!
        do { _ = try await registry.execute(for: same, operation: { 0 }); Issue.record("Stable account lost cooldown") }
        catch let failure as HTTPResponseFailure { #expect((failure.retryAfter ?? 0) > 3590) }
        let independent = [
            RequestQuota(service: service, url: url, account: .init(stableID: "bob"))!,
            RequestQuota(service: service, url: URL(string: "https://other.invalid/search")!, account: .init(stableID: "alice"))!,
            RequestQuota(service: service, url: URL(string: "https://example.invalid:8443/search")!, account: .init(stableID: "alice"))!,
            RequestQuota(service: service, url: URL(string: "http://example.invalid/search")!, account: .init(stableID: "alice"))!,
            RequestQuota(service: .init(id: "artwork", policy: .init()), url: url, account: .init(stableID: "alice"))!
        ]
        for quota in independent { #expect(try await registry.execute(for: quota, operation: { 1 }) == 1) }
    }

    @Test func activeAndQueuedRequestsCannotBeEvictedAndCancellationReleasesThem() async throws {
        let clock = ControlledClock()
        let registry = RequestQuotaRegistry(maximumQuotas: 1, timing: clock.timing)
        let service = RequestQuota.Service(id: "provider", policy: .init(maximumConcurrentRequests: 1))
        let active = RequestQuota(service: service, url: URL(string: "https://first.invalid/")!)!
        let other = RequestQuota(service: service, url: URL(string: "https://other.invalid/")!)!
        let gate = HeldResponse()
        let first = Task { try await registry.execute(for: active) { try await gate.read() } }
        defer { first.cancel() }
        try await gate.waitUntilStarted()
        let queued = Task { try await registry.execute(for: active, operation: { Issue.record("Queued work escaped its permit"); return 2 }) }
        defer { queued.cancel() }
        try await clock.waitForSleep(at: 30, count: 2)
        do { _ = try await registry.execute(for: other, operation: { 3 }); Issue.record("Active quota was evicted") }
        catch RequestExecutor.AdmissionError.queueFull { }
        queued.cancel()
        do { _ = try await queued.value; Issue.record("Expected queued cancellation") } catch is CancellationError { }
        first.cancel()
        do { _ = try await first.value; Issue.record("Expected active cancellation") } catch is CancellationError { }
        #expect(try await registry.execute(for: other, operation: { 4 }) == 4)
    }

    @Test func successfulRequestsRetainTheirPacingReservationDuringEviction() async throws {
        let clock = ControlledClock()
        let registry = RequestQuotaRegistry(maximumQuotas: 1, timing: clock.timing)
        let service = RequestQuota.Service(id: "paced", policy: .init(minimumInterval: 3))
        let first = RequestQuota(service: service, url: URL(string: "https://first.invalid/")!)!
        let other = RequestQuota(service: service, url: URL(string: "https://other.invalid/")!)!
        _ = try await registry.execute(for: first, operation: { clock.recordStart(); return 1 })
        do { _ = try await registry.execute(for: other, operation: { 2 }); Issue.record("Unexpired pacing was evicted") }
        catch RequestExecutor.AdmissionError.queueFull { }
        let next = Task { try await registry.execute(for: first, operation: { clock.recordStart(); return 3 }) }
        defer { next.cancel() }
        try await clock.waitForSleep(at: 3)
        clock.advance(to: 3)
        #expect(try await next.value == 3)
        #expect(clock.starts == [0, 3])
        clock.advance(to: 6)
        #expect(try await registry.execute(for: other, operation: { 4 }) == 4)
    }

    @Test func callerDeadlineCoversTheDataTransportWithoutDiscardingAnotherLease() async throws {
        let clock = ControlledClock()
        let registry = RequestQuotaRegistry(timing: clock.timing)
        let quota = RequestQuota(service: .init(id: "provider", policy: .init(timeout: 90)), url: URL(string: "https://fixture.invalid/")!)!
        let gate = HeldResponse()
        let task = Task { try await registry.execute(for: quota, timeout: 3) { try await gate.read() } }
        defer { task.cancel() }
        try await gate.waitUntilStarted()
        try await clock.waitForSleep(at: 3)
        clock.advance(to: 3)
        do { _ = try await task.value; Issue.record("Caller deadline was replaced by the service default") }
        catch let error as URLError { #expect(error.code == .timedOut) }
        #expect(try await registry.execute(for: quota, operation: { 1 }) == 1)
    }

    @Test func onlyPublicAppleCatalogEndpointsReceiveApplesStatusPolicy() {
        #expect(RequestQuota.appleCatalog(for: URL(string: "https://ITUNES.apple.com:443/search?term=test")!) != nil)
        for value in ["https://is1-ssl.mzstatic.com/search", "https://itunes.apple.com:8443/search", "https://itunes.apple.com.evil.invalid/search", "https://itunes.apple.com/artwork", "http://itunes.apple.com/search"] {
            #expect(RequestQuota.appleCatalog(for: URL(string: value)!) == nil)
        }
    }
}
