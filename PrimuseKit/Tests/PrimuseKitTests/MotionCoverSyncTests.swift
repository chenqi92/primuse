import Foundation
import Testing
@testable import PrimuseKit

struct MotionCoverSyncTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func asset(_ fill: Character, createdAt: Date? = nil, bytes: Int64 = 4_000_000) -> MotionCoverAsset {
        MotionCoverAsset(
            contentID: String(repeating: String(fill), count: 64),
            aspect: .square,
            pixelWidth: 1_080,
            pixelHeight: 1_080,
            duration: 12,
            byteCount: bytes,
            createdAt: createdAt ?? t0
        )
    }

    @Test func ownerSyncKeyRoundTrips() {
        #expect(MotionCoverOwner.song("abc").syncKey == "s:abc")
        #expect(MotionCoverOwner.album("x:y").syncKey == "a:x:y")
        #expect(MotionCoverOwner(syncKey: "s:abc") == .song("abc"))
        #expect(MotionCoverOwner(syncKey: "a:x:y") == .album("x:y"))
        #expect(MotionCoverOwner(syncKey: "s:") == nil)
        #expect(MotionCoverOwner(syncKey: "p:abc") == nil)
        #expect(MotionCoverOwner(syncKey: "") == nil)
    }

    @Test func recordIDsAreDistinctAndValidated() {
        let song = MotionCoverCloudRecordID.binding(for: .song("song-1"))
        let album = MotionCoverCloudRecordID.binding(for: .album("song-1"))
        #expect(song != album)
        #expect(MotionCoverCloudRecordID.isBinding(song))
        #expect(MotionCoverCloudRecordID.isMotionCover(album))
        #expect(MotionCoverCloudRecordID.videoContentID(song) == nil)

        let contentID = String(repeating: "ab", count: 32)
        let video = MotionCoverCloudRecordID.video(contentID: contentID)
        #expect(MotionCoverCloudRecordID.videoContentID(video) == contentID)
        #expect(!MotionCoverCloudRecordID.isBinding(video))
        #expect(MotionCoverCloudRecordID.isMotionCover(video))
        #expect(MotionCoverCloudRecordID.videoContentID(MotionCoverCloudRecordID.videoPrefix + "../x") == nil)

        // 不和已有的借用前缀、歌单 ID 撞。
        #expect(!MotionCoverCloudRecordID.isMotionCover("__song_cover_asset__:" + contentID))
        #expect(!MotionCoverCloudRecordID.isMotionCover("__artwork_override__:album:x"))
        #expect(!MotionCoverCloudRecordID.isMotionCover(UUID().uuidString))
        #expect(LibraryArtworkOwner.fromCloudRecordID(song) == nil)
    }

    @Test func longOrUnusualOwnerIDsAreHashedButStillMatch() {
        let longID = String(repeating: "长", count: 120)
        let id = MotionCoverCloudRecordID.binding(for: .song(longID))
        #expect(id.utf8.count < 240)
        let entry = MotionCoverSyncEntry(owner: .song(longID), asset: asset("a"), modifiedAt: t0)
        #expect(MotionCoverCloudRecordID.entry(entry, matchesBinding: id))
        let other = MotionCoverSyncEntry(owner: .album(longID), asset: asset("a"), modifiedAt: t0)
        #expect(!MotionCoverCloudRecordID.entry(other, matchesBinding: id))
    }

    @Test func newerModificationWins() {
        let local = MotionCoverSyncEntry(owner: .song("s"), asset: asset("a"), modifiedAt: t0)
        let newer = MotionCoverSyncEntry(owner: .song("s"), asset: asset("b"), modifiedAt: t0 + 5)
        let older = MotionCoverSyncEntry(owner: .song("s"), asset: asset("b"), modifiedAt: t0 - 5)
        #expect(MotionCoverSyncMergePolicy.winner(local: local, remote: newer) == .remote)
        #expect(MotionCoverSyncMergePolicy.winner(local: local, remote: older) == .local)
        #expect(MotionCoverSyncMergePolicy.winner(local: nil, remote: older) == .remote)
        #expect(MotionCoverSyncMergePolicy.winner(local: local, remote: local) == .same)
    }

    @Test func simultaneousDifferentChoicesResolveTheSameWayOnBothDevices() {
        let a = MotionCoverSyncEntry(owner: .album("al"), asset: asset("a"), modifiedAt: t0)
        let b = MotionCoverSyncEntry(owner: .album("al"), asset: asset("b"), modifiedAt: t0)
        let onA = MotionCoverSyncMergePolicy.winner(local: a, remote: b)
        let onB = MotionCoverSyncMergePolicy.winner(local: b, remote: a)
        #expect(onA == .remote)
        #expect(onB == .local)

        // 同一段视频、同一时刻，只是导入时间不同：不算冲突，免得两台设备来回改。
        let a2 = MotionCoverSyncEntry(owner: .album("al"), asset: asset("a", createdAt: t0 - 100), modifiedAt: t0)
        #expect(MotionCoverSyncMergePolicy.winner(local: a, remote: a2) == .same)
        #expect(MotionCoverSyncMergePolicy.winner(local: a2, remote: a) == .same)
    }

    @Test func removalIsATombstoneThatBeatsOlderSettings() {
        var phone = MotionCoverIndex()
        phone.set(asset("a"), for: .song("s"), at: t0)
        phone.set(nil, for: .song("s"), at: t0 + 10)
        #expect(phone.asset(for: .song("s")) == nil)
        let tombstone = phone.syncEntry(for: .song("s"))
        #expect(tombstone?.asset == nil)
        #expect(tombstone?.modifiedAt == t0 + 10)

        // 另一台设备上更早设的不会把它复活。
        let olderSet = MotionCoverSyncEntry(owner: .song("s"), asset: asset("b"), modifiedAt: t0 + 5)
        #expect(phone.applyRemote(olderSet) == .localNewer)
        #expect(phone.asset(for: .song("s")) == nil)

        // 更晚设的照常生效，墓碑随之撤掉。
        let newerSet = MotionCoverSyncEntry(owner: .song("s"), asset: asset("c"), modifiedAt: t0 + 20)
        #expect(phone.applyRemote(newerSet) == .applied(replacedContentID: nil))
        #expect(phone.asset(for: .song("s"))?.contentID == asset("c").contentID)
        #expect(phone.removedAt.isEmpty)
    }

    @Test func remoteReplacementReportsTheVideoItReplaced() {
        var pad = MotionCoverIndex()
        pad.set(asset("a"), for: .album("al"), at: t0)
        let replaced = MotionCoverSyncEntry(owner: .album("al"), asset: asset("b"), modifiedAt: t0 + 1)
        #expect(pad.applyRemote(replaced) == .applied(replacedContentID: asset("a").contentID))
        #expect(pad.referencedContentIDs == [asset("b").contentID])
        #expect(pad.applyRemote(replaced) == .unchanged)

        let removal = MotionCoverSyncEntry(owner: .album("al"), asset: nil, modifiedAt: t0 + 2)
        #expect(pad.applyRemote(removal) == .applied(replacedContentID: asset("b").contentID))
        #expect(pad.isEmpty)
        #expect(pad.syncEntry(for: .album("al")) == removal)
    }

    @Test func entriesWithoutStampUseImportTime() {
        // 升级前的索引没有修改时间。
        var legacy = MotionCoverIndex(songs: ["s": asset("a", createdAt: t0 - 50)])
        #expect(legacy.syncEntry(for: .song("s"))?.modifiedAt == t0 - 50)
        let remote = MotionCoverSyncEntry(owner: .song("s"), asset: asset("b"), modifiedAt: t0)
        #expect(legacy.applyRemote(remote) == .applied(replacedContentID: asset("a").contentID))
    }

    @Test func unacceptableRemoteEntriesAreIgnored() {
        var index = MotionCoverIndex()
        index.set(asset("a"), for: .song("s"), at: t0)
        var future = MotionCoverSyncEntry(owner: .song("s"), asset: asset("b"), modifiedAt: t0 + 10)
        future.schemaVersion = MotionCoverSyncEntry.currentSchemaVersion + 1
        #expect(index.applyRemote(future) == .unchanged)

        let tooLarge = MotionCoverSyncEntry(
            owner: .song("s"),
            asset: asset("b", bytes: MotionCoverImportLimits.maximumSyncedVideoBytes + 1),
            modifiedAt: t0 + 10
        )
        #expect(index.applyRemote(tooLarge) == .unchanged)

        var badOwner = MotionCoverSyncEntry(owner: .song("s"), asset: asset("b"), modifiedAt: t0 + 10)
        badOwner.ownerKey = "x:s"
        #expect(index.applyRemote(badOwner) == .unchanged)
        #expect(index.asset(for: .song("s"))?.contentID == asset("a").contentID)
    }

    @Test func localPruneLeavesNoTombstoneButRemoveAllDoes() {
        var index = MotionCoverIndex()
        index.set(asset("a"), for: .song("s1"), at: t0)
        index.set(asset("b"), for: .album("al"), at: t0)
        index.remove(songIDs: ["s1"], albumIDs: [])
        #expect(index.syncEntry(for: .song("s1")) == nil)
        #expect(index.modifiedAt[MotionCoverOwner.song("s1").syncKey] == nil)

        index.set(asset("c"), for: .song("s2"), at: t0)
        let previous = index.removeAll(at: t0 + 3)
        #expect(previous == [asset("b").contentID, asset("c").contentID])
        #expect(index.isEmpty)
        #expect(index.syncOwners == [.album("al"), .song("s2")])
        #expect(index.syncEntry(for: .song("s2"))?.asset == nil)
    }

    @Test func legacyIndexFilesStillDecode() throws {
        let legacy = """
        {"version":1,"songs":{},"albums":{"al":{"contentID":"\(String(repeating: "a", count: 64))",\
        "aspect":"square","pixelWidth":1080,"pixelHeight":1080,"duration":12,"byteCount":10,"createdAt":0}}}
        """
        let decoded = try JSONDecoder().decode(MotionCoverIndex.self, from: Data(legacy.utf8))
        #expect(decoded.albums["al"] != nil)
        #expect(decoded.modifiedAt.isEmpty && decoded.removedAt.isEmpty)

        var stamped = decoded
        stamped.set(nil, for: .song("gone"), at: t0)
        let roundTrip = try JSONDecoder().decode(MotionCoverIndex.self, from: JSONEncoder().encode(stamped))
        #expect(roundTrip == stamped)
    }

    @Test func entryRoundTripsThroughJSON() throws {
        let entry = MotionCoverSyncEntry(owner: .album("al"), asset: asset("a"), modifiedAt: t0 + 0.123_456)
        let decoded = try JSONDecoder().decode(MotionCoverSyncEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
        let tombstone = MotionCoverSyncEntry(owner: .song("s"), asset: nil, modifiedAt: t0)
        let decodedTombstone = try JSONDecoder().decode(MotionCoverSyncEntry.self, from: JSONEncoder().encode(tombstone))
        #expect(decodedTombstone == tombstone)
        #expect(decodedTombstone.isAcceptable)
    }

    @Test func syncPreferenceDefaultsOff() throws {
        let suite = "MotionCoverSyncTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!MotionCoverSyncPreferences.isEnabled(defaults: defaults))
        defaults.set(true, forKey: MotionCoverSyncPreferences.enabledKey)
        #expect(MotionCoverSyncPreferences.isEnabled(defaults: defaults))
    }

    @Test func uploadSizeLimit() {
        #expect(MotionCoverSyncVideoPolicy.isUploadable(fileSize: 1))
        #expect(MotionCoverSyncVideoPolicy.isUploadable(fileSize: MotionCoverImportLimits.maximumSyncedVideoBytes))
        #expect(!MotionCoverSyncVideoPolicy.isUploadable(fileSize: MotionCoverImportLimits.maximumSyncedVideoBytes + 1))
        #expect(!MotionCoverSyncVideoPolicy.isUploadable(fileSize: 0))
    }
}
