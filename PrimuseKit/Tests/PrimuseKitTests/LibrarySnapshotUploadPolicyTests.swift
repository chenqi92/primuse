import Foundation
import Testing
@testable import PrimuseKit

@Suite("Automatic library snapshot upload guard")
struct LibrarySnapshotUploadPolicyTests {
    @Test("A fresh device that already synced cloud sources refuses to overwrite the account snapshot with an empty library")
    func refusesEmptyOverwrite() {
        #expect(
            LibrarySnapshotUploadPolicy.automaticUploadAllowed(
                eligibleSongCount: 0,
                hasCloudEligibleSources: true,
                serverHasLibraryPayload: true
            ) == false
        )
    }

    @Test("A library made only of device-local sources keeps uploading — its eligible count is always zero")
    func allowsLocalOnlyLibrary() {
        #expect(
            LibrarySnapshotUploadPolicy.automaticUploadAllowed(
                eligibleSongCount: 0,
                hasCloudEligibleSources: false,
                serverHasLibraryPayload: true
            )
        )
        #expect(
            LibrarySnapshotUploadPolicy.automaticUploadAllowed(
                eligibleSongCount: 0,
                hasCloudEligibleSources: false,
                serverHasLibraryPayload: false
            )
        )
    }

    @Test("The first upload for an account may be empty — there is nothing to lose")
    func allowsFirstEmptyUpload() {
        #expect(
            LibrarySnapshotUploadPolicy.automaticUploadAllowed(
                eligibleSongCount: 0,
                hasCloudEligibleSources: true,
                serverHasLibraryPayload: false
            )
        )
    }

    @Test("A non-empty library is always allowed to replace the cloud snapshot")
    func allowsNonEmptyUpload() {
        #expect(
            LibrarySnapshotUploadPolicy.automaticUploadAllowed(
                eligibleSongCount: 1,
                hasCloudEligibleSources: true,
                serverHasLibraryPayload: true
            )
        )
        #expect(
            LibrarySnapshotUploadPolicy.automaticUploadAllowed(
                eligibleSongCount: 42_000,
                hasCloudEligibleSources: true,
                serverHasLibraryPayload: false
            )
        )
    }

    @Test("A negative count cannot be read as a non-empty library")
    func treatsNegativeCountAsEmpty() {
        #expect(
            LibrarySnapshotUploadPolicy.automaticUploadAllowed(
                eligibleSongCount: -1,
                hasCloudEligibleSources: true,
                serverHasLibraryPayload: true
            ) == false
        )
        #expect(
            LibrarySnapshotUploadPolicy.automaticUploadAllowed(
                eligibleSongCount: -1,
                hasCloudEligibleSources: false,
                serverHasLibraryPayload: true
            )
        )
    }
}
