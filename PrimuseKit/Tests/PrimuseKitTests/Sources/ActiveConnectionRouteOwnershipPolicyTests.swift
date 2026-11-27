import Foundation
import Testing
@testable import PrimuseKit

@Suite("Active connection route ownership policy")
struct ActiveConnectionRouteOwnershipPolicyTests {
    @Test("A connector built without routing identity still publishes")
    func legacyUpdateIsAccepted() {
        #expect(ActiveConnectionRouteOwnershipPolicy.acceptsRouteUpdate(
            updateOwner: nil,
            currentOwner: nil
        ))
        #expect(ActiveConnectionRouteOwnershipPolicy.acceptsRouteUpdate(
            updateOwner: nil,
            currentOwner: UUID()
        ))
    }

    @Test("The owning connector publishes its route")
    func matchingOwnerIsAccepted() {
        let owner = UUID()
        #expect(ActiveConnectionRouteOwnershipPolicy.acceptsRouteUpdate(
            updateOwner: owner,
            currentOwner: owner
        ))
    }

    @Test("A retired connector cannot erase the live route")
    func retiredOwnerIsRejected() {
        #expect(ActiveConnectionRouteOwnershipPolicy.acceptsRouteUpdate(
            updateOwner: UUID(),
            currentOwner: UUID()
        ) == false)
    }

    @Test("An uncached build never claims the source slot")
    func uncachedBuildIsRejected() {
        #expect(ActiveConnectionRouteOwnershipPolicy.acceptsRouteUpdate(
            updateOwner: UUID(),
            currentOwner: nil
        ) == false)
    }
}
