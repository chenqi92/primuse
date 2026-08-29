import Testing
@testable import PrimuseKit

struct PlaylistOperationAvailabilityTests {
    @Test func fileImportMatchesPlatformCapability() {
        #expect(PlaylistOperationAvailability.standard.supportsImport)
        #expect(!PlaylistOperationAvailability.television.supportsImport)
    }
}
