import Foundation
import Testing
@testable import PrimuseKit

@Suite("Offline mode policy")
struct OfflineModePolicyTests {
    private func source(_ id: String, _ type: MusicSourceType, isDeleted: Bool = false) -> MusicSource {
        var item = MusicSource(id: id, name: id, type: type)
        item.isDeleted = isDeleted
        return item
    }

    @Test("Only remote sources participate in manual offline mode")
    func remoteSourceEligibility() {
        #expect(OfflineModeState.supportsOfflineMode(for: .navidrome))
        #expect(OfflineModeState.supportsOfflineMode(for: .subsonic))
        #expect(OfflineModeState.supportsOfflineMode(for: .jellyfin))
        #expect(OfflineModeState.supportsOfflineMode(for: .smb))
        #expect(OfflineModeState.supportsOfflineMode(for: .aliyunDrive))
        #expect(!OfflineModeState.supportsOfflineMode(for: .local))
        #expect(!OfflineModeState.supportsOfflineMode(for: .appleMusic))
        #expect(!OfflineModeState.supportsOfflineMode(for: .appleMusicLibrary))
    }

    @Test("Global and per-source flags resolve active offline source IDs")
    func globalAndPerSourceResolution() {
        let sources = [
            source("nav", .navidrome),
            source("jf", .jellyfin),
            source("local", .local),
            source("am", .appleMusic),
            source("deleted", .subsonic, isDeleted: true),
        ]

        var state = OfflineModeState.inactive
        #expect(state.activeOfflineSourceIDs(in: sources).isEmpty)
        #expect(!state.hasActiveRestriction(validRemoteSourceIDs: ["nav", "jf"]))

        state.setSourceOffline(true, sourceID: "nav")
        #expect(state.isSourceOffline("nav", type: .navidrome))
        #expect(!state.isSourceOffline("jf", type: .jellyfin))
        #expect(!state.isSourceOffline("local", type: .local))
        #expect(state.activeOfflineSourceIDs(in: sources) == ["nav"])
        #expect(state.activeManualOfflineCount(validRemoteSourceIDs: ["nav", "jf"]) == 1)
        #expect(state.hasActiveRestriction(validRemoteSourceIDs: ["nav", "jf"]))

        state.isGlobalOffline = true
        #expect(state.activeOfflineSourceIDs(in: sources) == ["nav", "jf"])
        #expect(!state.isSourceOffline("local", type: .local))
        #expect(!state.isSourceOffline("am", type: .appleMusic))
    }

    @Test("Pruning drops removed source IDs while preserving global flag")
    func pruningAndPersistenceRoundTrip() {
        let state = OfflineModeState(isGlobalOffline: true, offlineSourceIDs: ["nav", "gone"])
        let pruned = state.pruned(keeping: ["nav", "jf"])
        #expect(pruned.isGlobalOffline)
        #expect(pruned.offlineSourceIDs == ["nav"])

        let encoded = pruned.encoded()
        #expect(encoded != nil)
        #expect(OfflineModeState.decode(encoded) == pruned)
        #expect(OfflineModeState.decode(nil) == .inactive)
    }
}
