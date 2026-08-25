import Testing
@testable import PrimuseKit

@Suite("Source directory selection")
struct SourceDirectorySelectionPolicyTests {
    @Test("Creation continues only for directory-scoped sources")
    func creationDirectorySelectionPolicy() {
        let expected: Set<MusicSourceType> = [
            .synology, .qnap, .ugreen, .fnos,
            .webdav, .smb, .ftp, .sftp, .nfs, .upnp, .s3,
            .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox,
            .drime, .pan115, .pan123,
        ]
        let actual = Set(MusicSourceType.allCases.filter(\.continuesToDirectorySelectionAfterCreation))

        #expect(actual == expected)
    }

    @Test("SMB and WebDAV creation waits for validated directory selection")
    func filesystemCreationWaitsForValidatedDirectorySelection() {
        #expect(SourceCreationPersistencePolicy.defersUntilValidatedDirectorySelection(for: .smb))
        #expect(SourceCreationPersistencePolicy.defersUntilValidatedDirectorySelection(for: .webdav))

        #expect(!SourceCreationPersistencePolicy.canCommitDeferredCreation(
            for: .smb,
            connectionValidated: false,
            selectedDirectories: ["/Music"]
        ))
        #expect(!SourceCreationPersistencePolicy.canCommitDeferredCreation(
            for: .smb,
            connectionValidated: true,
            selectedDirectories: []
        ))
        #expect(SourceCreationPersistencePolicy.canCommitDeferredCreation(
            for: .smb,
            connectionValidated: true,
            selectedDirectories: ["/Music"]
        ))
    }

    @Test("Cancelling the WebDAV HTTP risk prompt discards the new draft")
    func webDAVRiskPromptCancellationDiscardsDraft() {
        #expect(!SourceCreationPersistencePolicy.canCommitDeferredCreation(
            for: .webdav,
            connectionValidated: false,
            selectedDirectories: []
        ))
        #expect(SourceCreationPersistencePolicy.cancellationDisposition(
            wasPersistedBeforeFlow: false,
            wasCommittedDuringFlow: false
        ) == .discardUncommittedDraft)
    }

    @Test("Cancelling after WebDAV authentication failure discards the new draft")
    func webDAVAuthenticationFailureCancellationDiscardsDraft() {
        #expect(!SourceCreationPersistencePolicy.canCommitDeferredCreation(
            for: .webdav,
            connectionValidated: false,
            selectedDirectories: ["/Music"]
        ))
        #expect(SourceCreationPersistencePolicy.cancellationDisposition(
            wasPersistedBeforeFlow: false,
            wasCommittedDuringFlow: false
        ) == .discardUncommittedDraft)
    }

    @Test("Cancelling after SMB connection failure discards the new draft")
    func smbConnectionFailureCancellationDiscardsDraft() {
        #expect(!SourceCreationPersistencePolicy.canCommitDeferredCreation(
            for: .smb,
            connectionValidated: false,
            selectedDirectories: []
        ))
        #expect(SourceCreationPersistencePolicy.cancellationDisposition(
            wasPersistedBeforeFlow: false,
            wasCommittedDuringFlow: false
        ) == .discardUncommittedDraft)
    }

    @Test("A validated WebDAV source remains after successful save")
    func successfulWebDAVCreationRemainsPersisted() {
        #expect(SourceCreationPersistencePolicy.canCommitDeferredCreation(
            for: .webdav,
            connectionValidated: true,
            selectedDirectories: ["/"]
        ))
        #expect(SourceCreationPersistencePolicy.cancellationDisposition(
            wasPersistedBeforeFlow: false,
            wasCommittedDuringFlow: true
        ) == .preservePersistedSource)
    }

    @Test("Cancelling an existing WebDAV edit preserves the source")
    func existingWebDAVEditCancellationPreservesSource() {
        #expect(SourceCreationPersistencePolicy.cancellationDisposition(
            wasPersistedBeforeFlow: true,
            wasCommittedDuringFlow: false
        ) == .preservePersistedSource)
    }

    @Test("Cancelling an existing SMB edit preserves the source")
    func existingSMBEditCancellationPreservesSource() {
        #expect(SourceCreationPersistencePolicy.cancellationDisposition(
            wasPersistedBeforeFlow: true,
            wasCommittedDuringFlow: false
        ) == .preservePersistedSource)
    }

    @Test("S3 browser root maps to the bucket prefix")
    func mapsS3RootToEmptyPrefix() {
        #expect(SourceDirectorySelectionPolicy.connectorPath(
            for: .s3,
            browserPath: "/"
        ) == "")
        #expect(SourceDirectorySelectionPolicy.selectableRootPath(
            for: .s3,
            browserPath: "/"
        ) == "")
    }

    @Test("S3 child selections keep their object prefixes")
    func preservesS3ChildPaths() {
        let children = ["Music", "Albums/Live"]

        #expect(SourceDirectorySelectionPolicy.connectorPath(
            for: .s3,
            browserPath: "Music"
        ) == "Music")
        #expect(SourceDirectorySelectionPolicy.selectableRootPath(
            for: .s3,
            browserPath: "Music"
        ) == nil)
        #expect(SourceDirectorySelectionPolicy.normalizedSelections(
            children,
            for: .s3
        ) == children)
    }

    @Test("Selecting the S3 root removes redundant child scopes")
    func rootSelectionCoversChildren() {
        #expect(SourceDirectorySelectionPolicy.normalizedSelections(
            ["Music", ""],
            for: .s3
        ) == [""])
    }

    @Test("Drime root is a selectable scan scope")
    func selectsDrimeRoot() {
        #expect(SourceDirectorySelectionPolicy.connectorPath(
            for: .drime,
            browserPath: "/"
        ) == "/")
        #expect(SourceDirectorySelectionPolicy.selectableRootPath(
            for: .drime,
            browserPath: "/"
        ) == "/")
        #expect(SourceDirectorySelectionPolicy.normalizedSelections(
            ["4815", "/"],
            for: .drime
        ) == ["/"])
    }

    @Test("WebDAV root is selectable when files are mounted without subdirectories")
    func selectsWebDAVRoot() {
        #expect(SourceDirectorySelectionPolicy.connectorPath(
            for: .webdav,
            browserPath: "/"
        ) == "/")
        #expect(SourceDirectorySelectionPolicy.selectableRootPath(
            for: .webdav,
            browserPath: "/"
        ) == "/")
        #expect(SourceDirectorySelectionPolicy.normalizedSelections(
            ["/Albums", "/"],
            for: .webdav
        ) == ["/"])
    }

    @Test("SMB share root is selectable and covers child scopes")
    func selectsSMBRoot() {
        #expect(SourceDirectorySelectionPolicy.selectableCurrentPath(
            for: .smb,
            browserPath: "/"
        ) == "/")
        #expect(SourceDirectorySelectionPolicy.normalizedSelections(
            ["/Albums", "/"],
            for: .smb
        ) == ["/"])
    }

    @Test("Empty and file-only SMB leaf directories remain selectable")
    func selectsSMBLeafDirectoriesWithoutChildren() {
        let emptyDirectory = SourceDirectorySelectionPolicy.browserPresentation(
            for: .smb,
            browserPath: "/Music/Empty",
            itemDirectoryFlags: []
        )
        let fileOnlyDirectory = SourceDirectorySelectionPolicy.browserPresentation(
            for: .smb,
            browserPath: "/Music/Leaf",
            itemDirectoryFlags: [false, false]
        )

        #expect(emptyDirectory.selectableCurrentPath == "/Music/Empty")
        #expect(emptyDirectory.showsNoSubdirectories)
        #expect(fileOnlyDirectory.selectableCurrentPath == "/Music/Leaf")
        #expect(fileOnlyDirectory.showsNoSubdirectories)
    }

    @Test("Directories with children remain selectable for SMB and WebDAV")
    func selectsCurrentDirectoryAlongsideChildren() {
        let smbDirectory = SourceDirectorySelectionPolicy.browserPresentation(
            for: .smb,
            browserPath: "/Music",
            itemDirectoryFlags: [false, true]
        )
        let webDAVDirectory = SourceDirectorySelectionPolicy.browserPresentation(
            for: .webdav,
            browserPath: "/Library",
            itemDirectoryFlags: [true]
        )

        #expect(smbDirectory.selectableCurrentPath == "/Music")
        #expect(!smbDirectory.showsNoSubdirectories)
        #expect(webDAVDirectory.selectableCurrentPath == "/Library")
        #expect(!webDAVDirectory.showsNoSubdirectories)
    }

    @Test("Adjacent filesystem browsers preserve child path semantics")
    func preservesAdjacentFilesystemChildPaths() {
        #expect(SourceDirectorySelectionPolicy.selectableCurrentPath(
            for: .ftp,
            browserPath: "/Audio/Leaf"
        ) == "/Audio/Leaf")
        #expect(SourceDirectorySelectionPolicy.selectableCurrentPath(
            for: .sftp,
            browserPath: "/Archive"
        ) == "/Archive")
    }

    @Test("Other protocols keep root and selected paths unchanged")
    func preservesOtherProtocols() {
        let selected = ["/Music", "/Archive"]

        #expect(SourceDirectorySelectionPolicy.connectorPath(
            for: .smb,
            browserPath: "/"
        ) == "/")
        #expect(SourceDirectorySelectionPolicy.selectableRootPath(
            for: .smb,
            browserPath: "/"
        ) == "/")
        #expect(SourceDirectorySelectionPolicy.normalizedSelections(
            selected,
            for: .smb
        ) == selected)
    }

    @Test("S3 root selection persists with its region")
    func persistsS3RootSelection() {
        let regionConfig = MusicSource.encodeS3Region("us-east-1", into: nil)
        let encoded = MusicSource.encodeScannedDirectories(
            [""],
            into: regionConfig,
            type: .s3
        )

        #expect(MusicSource.decodeScannedDirectories(encoded, type: .s3) == [""])
        let source = MusicSource(name: "MinIO", type: .s3, extraConfig: encoded)
        #expect(source.s3Region == "us-east-1")
    }
}
