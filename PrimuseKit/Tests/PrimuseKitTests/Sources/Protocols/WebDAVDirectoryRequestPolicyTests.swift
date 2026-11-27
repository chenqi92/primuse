import Foundation
import Testing
@testable import PrimuseKit

@Suite("WebDAV directory quota contract")
struct WebDAVDirectoryRequestPolicyTests {
    @Test func secondsAndHTTPDateKeepTheirCompleteDeadline() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for status in [429, 503] {
            for header in ["3600", "Tue, 14 Nov 2023 23:13:20 GMT"] {
                let response = try #require(HTTPURLResponse(url: URL(string: "https://fixture.invalid/")!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": header]))
                let failure = WebDAVDirectoryRequestPolicy.failure(statusCode: status,
                    retryAfter: HTTPResponseFailure.retryDelay(from: response, now: date), completedWaits: 0)
                #expect(failure.statusCode == status)
                #expect(failure.retryAfter == 3600)
                #expect(failure.isRateLimited)
                #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 0, retryAfter: failure.retryAfter) == nil)
            }
        }
    }

    @Test func missingHeadersKeepTheBoundedLadderAndFinalCooldown() {
        for (waits, expected) in [(0, 2.0), (1, 5), (2, 10), (3, 10)] {
            let failure = WebDAVDirectoryRequestPolicy.failure(statusCode: 429, retryAfter: nil, completedWaits: waits)
            #expect(failure.retryAfter == expected)
            #expect(failure.isRateLimited)
        }
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 3, retryAfter: 10) == nil)
    }

    @Test func onlyExplicitServiceUnavailableStartsAnAccountCooldown() {
        for delay: TimeInterval? in [nil, -1, .infinity, .nan] {
            let failure = WebDAVDirectoryRequestPolicy.failure(statusCode: 503, retryAfter: delay, completedWaits: 0)
            #expect(!failure.isRateLimited)
            #expect(failure.retryAfter == nil)
        }
        for status in [401, 403, 404, 500] {
            let failure = WebDAVDirectoryRequestPolicy.failure(statusCode: status, retryAfter: 30, completedWaits: 0)
            #expect(!failure.isRateLimited)
            #expect(failure.retryAfter == nil)
        }
        let immediate = WebDAVDirectoryRequestPolicy.failure(statusCode: 503, retryAfter: 0, completedWaits: 0)
        #expect(immediate.isRateLimited)
        #expect(immediate.retryAfter == 2)
    }

    @Test func theSameAccountSharesAcrossRootsButNotOtherAccountsOrMedia() async throws {
        let registry = RequestQuotaRegistry()
        let first = WebDAVDirectoryRequestPolicy.quota(url: URL(string: "https://EXAMPLE.invalid:443/Music/")!, username: "reader")!
        do {
            _ = try await registry.execute(for: first, operation: { () -> Int in
                throw WebDAVDirectoryRequestPolicy.failure(statusCode: 503, retryAfter: 3600, completedWaits: 0)
            })
        } catch let failure as HTTPResponseFailure { #expect(failure.statusCode == 503) }
        let same = WebDAVDirectoryRequestPolicy.quota(url: URL(string: "https://example.invalid/Other/")!, username: "reader")!
        do { _ = try await registry.execute(for: same, operation: { 0 }); Issue.record("Another root bypassed the quota") }
        catch let failure as HTTPResponseFailure { #expect((failure.retryAfter ?? 0) > 3590) }
        let other = WebDAVDirectoryRequestPolicy.quota(url: URL(string: "https://example.invalid/")!, username: "other")!
        #expect(try await registry.execute(for: other, operation: { 1 }) == 1)
        let media = RequestQuota(service: .init(id: "webdav.media", policy: .init()), url: URL(string: "https://example.invalid/song.flac")!, account: .init(stableID: "reader"))!
        #expect(try await registry.execute(for: media, operation: { 2 }) == 2)
    }
}
