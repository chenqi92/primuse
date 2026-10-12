import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class PlexSignInQuotaTests: XCTestCase {
    func testCreationAndLocallyBlockedRetryShowTheRemainingCooldown() async throws {
        for status in [429, 503, 403] {
            let counter = PlexSignInCounter()
            let client = PlexAccountClient(
                clientIdentifier: UUID().uuidString, platform: "test", deviceName: "fixture", version: "1",
                loader: { request in
                    counter.increment()
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                    headerFields: ["Retry-After": "3600"])!)
                }, quotaRegistry: RequestQuotaRegistry(timing: .init(now: { 0 }))
            )
            let model = PlexAccountSignInModel(client: client)
            defer { model.cancel() }
            for _ in 0..<2 {
                model.signIn()
                let deadline = Date().addingTimeInterval(5)
                while model.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                guard case .failed(let message) = model.phase else {
                    XCTFail("A rejected PIN request must leave the waiting screen")
                    continue
                }
                XCTAssertEqual(message, HTTPResponseFailure(statusCode: status, retryAfter: 3600).localizedDescription)
            }
            XCTAssertEqual(counter.value, 1, "Retrying inside the cooldown cannot send another PIN creation")
        }
    }
}

private final class PlexSignInCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
