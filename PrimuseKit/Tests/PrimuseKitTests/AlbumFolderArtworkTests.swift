import Foundation
import Testing
@testable import PrimuseKit

@Suite("Folder cover revisions")
struct SidecarCoverRevisionTrackerTests {
    private let path = "/Music/Album/cover.jpg"

    private func signature(size: Int64, modified: TimeInterval?) -> String {
        SidecarCoverRevisionTracker.signature(
            providerID: nil,
            revision: nil,
            size: size,
            modifiedDate: modified.map(Date.init(timeIntervalSinceReferenceDate:))
        )
    }

    @Test("A path seen for the first time is recorded and left to the time check")
    func firstSightingIsRecorded() {
        var tracker = SidecarCoverRevisionTracker()
        #expect(tracker.observe(coverPath: path, signature: signature(size: 10, modified: 100)) == .firstSeen)
        #expect(tracker.hasChanges)
        #expect(tracker.signatures[path] == signature(size: 10, modified: 100))
    }

    @Test("An unchanged signature asks for nothing and leaves the ledger clean")
    func unchangedSignature() {
        var tracker = SidecarCoverRevisionTracker(signatures: [path: signature(size: 10, modified: 100)])
        #expect(tracker.observe(coverPath: path, signature: signature(size: 10, modified: 100)) == .unchanged)
        #expect(!tracker.hasChanges)
    }

    @Test("A replaced picture reads as changed for every song sharing it in the same pass")
    func replacementReachesEverySong() {
        var tracker = SidecarCoverRevisionTracker(signatures: [path: signature(size: 10, modified: 100)])
        let replaced = signature(size: 12, modified: 200)
        #expect(tracker.observe(coverPath: path, signature: replaced) == .changed)
        #expect(tracker.observe(coverPath: path, signature: replaced) == .changed)
        #expect(tracker.signatures[path] == replaced)

        var nextPass = SidecarCoverRevisionTracker(signatures: tracker.signatures)
        #expect(nextPass.observe(coverPath: path, signature: replaced) == .unchanged)
    }

    @Test("A first sighting stays first-seen for the later songs of the same pass")
    func firstSightingIsSharedWithinPass() {
        var tracker = SidecarCoverRevisionTracker()
        let current = signature(size: 10, modified: 100)
        #expect(tracker.observe(coverPath: path, signature: current) == .firstSeen)
        #expect(tracker.observe(coverPath: path, signature: current) == .firstSeen)
    }

    @Test("Only a provider revision change still counts as a replacement")
    func revisionOnlyChange() {
        let old = SidecarCoverRevisionTracker.signature(providerID: "id", revision: "a", size: 10, modifiedDate: nil)
        let new = SidecarCoverRevisionTracker.signature(providerID: "id", revision: "b", size: 10, modifiedDate: nil)
        var tracker = SidecarCoverRevisionTracker(signatures: [path: old])
        #expect(tracker.observe(coverPath: path, signature: new) == .changed)
    }

    @Test("A cache written before the file changed is stale; clock jitter is tolerated")
    func staleness() {
        let file = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(SidecarCoverRevisionTracker.cacheIsStale(cachedAt: file.addingTimeInterval(-60), fileModifiedAt: file))
        #expect(!SidecarCoverRevisionTracker.cacheIsStale(cachedAt: file.addingTimeInterval(-1), fileModifiedAt: file))
        #expect(!SidecarCoverRevisionTracker.cacheIsStale(cachedAt: file.addingTimeInterval(60), fileModifiedAt: file))
        #expect(!SidecarCoverRevisionTracker.cacheIsStale(cachedAt: nil, fileModifiedAt: file))
        #expect(!SidecarCoverRevisionTracker.cacheIsStale(cachedAt: file, fileModifiedAt: nil))
    }

    @Test("The stored ledger round-trips and a foreign version is ignored")
    func ledgerRoundTrip() throws {
        let signatures = [path: signature(size: 10, modified: 100)]
        let data = try #require(SidecarCoverRevisionLedger.encode(signatures))
        #expect(SidecarCoverRevisionLedger.decode(data) == signatures)
        let foreign = Data(#"{"version":99,"signatures":{"a":"b"}}"#.utf8)
        #expect(SidecarCoverRevisionLedger.decode(foreign).isEmpty)
        #expect(SidecarCoverRevisionLedger.decode(Data("junk".utf8)).isEmpty)
    }
}

@Suite("Disc folders")
struct DiscFolderPolicyTests {
    @Test("Disc folder names and their numbers", arguments: [
        ("CD1", 1), ("cd 2", 2), ("Disc 02", 2), ("disk-3", 3), ("CD.4", 4), ("Disc_5", 5),
        ("第2张", 2), ("第 3 碟", 3), ("第10盘", 10),
    ])
    func discNumbers(_ name: String, _ number: Int) {
        #expect(DiscFolderPolicy.discNumber(fromFolderName: name) == number)
        #expect(DiscFolderPolicy.isDiscFolderName(name))
    }

    @Test("Ordinary folders are not disc folders", arguments: [
        "CD", "Discography", "第二张", "Disc A", "Album", "CD1 Bonus",
    ])
    func ordinaryFolders(_ name: String) {
        #expect(DiscFolderPolicy.discNumber(fromFolderName: name) == nil)
    }

    @Test("The album folder above a disc folder")
    func parentOfDiscFolder() {
        #expect(DiscFolderPolicy.parentDirectory(ofDiscFolder: "/Music/Album/CD1") == "/Music/Album")
        #expect(DiscFolderPolicy.parentDirectory(ofDiscFolder: "/Music/Album/Disc 2/") == "/Music/Album")
        #expect(DiscFolderPolicy.parentDirectory(ofDiscFolder: "Music/Album/CD1") == "Music/Album")
        #expect(DiscFolderPolicy.parentDirectory(ofDiscFolder: "/CD1") == "/")
        #expect(DiscFolderPolicy.parentDirectory(ofDiscFolder: "/Music/Album") == nil)
        #expect(DiscFolderPolicy.parentDirectory(ofDiscFolder: "CD1") == nil)
        #expect(DiscFolderPolicy.parentDirectory(ofDiscFolder: "0AbCdEf123") == nil)
    }
}

@Suite("Disc face artwork")
struct DiscArtworkPolicyTests {
    @Test("Disc face names", arguments: [
        "disc.jpg", "CD.png", "cdart.png", "Disc Art.jpg", "disc1.png", "CD 2.jpg", "disc-02.jpg", "vinyl.webp", "disk_3.jpeg",
    ])
    func candidates(_ name: String) {
        #expect(DiscArtworkPolicy.isCandidate(name))
    }

    @Test("Other pictures are not disc faces", arguments: [
        "cover.jpg", "folder.png", "back.jpg", "Discography.jpg", "disc1 front.jpg", "disc.txt", "cd1.cue",
    ])
    func nonCandidates(_ name: String) {
        #expect(!DiscArtworkPolicy.isCandidate(name))
    }

    @Test("A disc subfolder prefers its own picture, then the album folder's numbered one")
    func discSubfolder() {
        #expect(DiscArtworkPolicy.choose(
            songFolderNames: ["01.flac", "disc.jpg"],
            albumFolderNames: ["cover.jpg", "disc2.png"],
            songFolderName: "CD2",
            discNumber: 2
        ) == .songFolder(1))
        #expect(DiscArtworkPolicy.choose(
            songFolderNames: ["01.flac"],
            albumFolderNames: ["cover.jpg", "disc1.png", "disc2.png", "disc.png"],
            songFolderName: "CD2",
            discNumber: 2
        ) == .albumFolder(2))
        #expect(DiscArtworkPolicy.choose(
            songFolderNames: ["01.flac"],
            albumFolderNames: ["cover.jpg", "disc1.png", "disc.png"],
            songFolderName: "CD2",
            discNumber: 2
        ) == .albumFolder(2))
    }

    @Test("Another disc's numbered picture is never used")
    func otherDiscIsSkipped() {
        #expect(DiscArtworkPolicy.choose(
            songFolderNames: ["01.flac", "disc1.jpg"],
            albumFolderNames: nil,
            songFolderName: "Album",
            discNumber: 2
        ) == nil)
        #expect(DiscArtworkPolicy.choose(
            songFolderNames: ["01.flac", "disc1.jpg", "disc2.jpg"],
            albumFolderNames: nil,
            songFolderName: "Album",
            discNumber: 2
        ) == .songFolder(2))
    }

    @Test("A picture named after its disc folder is that disc's cover, not its face")
    func folderNamedPictureIsTheCover() {
        #expect(DiscArtworkPolicy.choose(
            songFolderNames: ["01.flac", "CD1.jpg"],
            albumFolderNames: [],
            songFolderName: "CD1",
            discNumber: 1
        ) == nil)
        #expect(DiscArtworkPolicy.choose(
            songFolderNames: ["01.flac"],
            albumFolderNames: ["CD1.jpg"],
            songFolderName: "CD1",
            discNumber: 1
        ) == .albumFolder(0))
    }

    @Test("Unknown disc numbers count as the first disc; name and extension order break ties")
    func tieBreaks() {
        #expect(DiscArtworkPolicy.choose(
            songFolderNames: ["vinyl.jpg", "cd.png", "disc.png", "disc.jpg"],
            albumFolderNames: nil,
            songFolderName: "Album",
            discNumber: nil
        ) == .songFolder(3))
        #expect(DiscArtworkPolicy.choose(
            songFolderNames: ["disc.jpg", "disc1.jpg"],
            albumFolderNames: nil,
            songFolderName: "Album",
            discNumber: nil
        ) == .songFolder(1))
    }
}
