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
        ) == nil)
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
