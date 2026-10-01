import Foundation
import Testing
@testable import PrimuseKit

@Suite("Server rating import")
struct ServerRatingImportPolicyTests {
    @Test("A rating changed in another client is adopted once a baseline exists")
    func adoptsServerChangesAgainstBaseline() {
        #expect(ServerRatingImportPolicy.decision(observed: 5, baseline: 3, local: 3, hasPendingLocalEdit: false) == .adopt)
        #expect(ServerRatingImportPolicy.decision(observed: 0, baseline: 4, local: 4, hasPendingLocalEdit: false) == .adopt)
    }

    @Test("Unchanged server values and pending local edits keep the local rating")
    func keepsLocalWhenServerUnchanged() {
        #expect(ServerRatingImportPolicy.decision(observed: 3, baseline: 3, local: 5, hasPendingLocalEdit: false) == .keep)
        #expect(ServerRatingImportPolicy.decision(observed: 2, baseline: 3, local: 5, hasPendingLocalEdit: true) == .keep)
        #expect(ServerRatingImportPolicy.decision(observed: 4, baseline: 4, local: 4, hasPendingLocalEdit: false) == .keep)
    }

    @Test("Without a baseline only unrated local songs take the server value")
    func firstSyncFillsOnlyUnrated() {
        #expect(ServerRatingImportPolicy.decision(observed: 4, baseline: nil, local: 0, hasPendingLocalEdit: false) == .adopt)
        #expect(ServerRatingImportPolicy.decision(observed: 4, baseline: nil, local: 2, hasPendingLocalEdit: false) == .keep)
        #expect(ServerRatingImportPolicy.decision(observed: 0, baseline: nil, local: 2, hasPendingLocalEdit: false) == .keep)
        #expect(ServerRatingImportPolicy.decision(observed: 3, baseline: nil, local: 3, hasPendingLocalEdit: false) == .recordBaseline)
        #expect(ServerRatingImportPolicy.decision(observed: 0, baseline: nil, local: 0, hasPendingLocalEdit: false) == .recordBaseline)
    }
}
