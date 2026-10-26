import Foundation
import Testing
@testable import PrimuseKit

@Suite("Per-device library snapshot manifest")
struct LibrarySnapshotDeviceManifestPolicyTests {
    typealias Policy = LibrarySnapshotDeviceManifestPolicy
    let earlier = Date(timeIntervalSince1970: 1_000)
    let later = Date(timeIntervalSince1970: 2_000)

    @Test("Upserting a device replaces only its own row and keeps every other device")
    func upsertKeepsOtherDevices() {
        let phone = LibrarySnapshotDeviceEntry(deviceID: "phone", deviceName: "iPhone", modifiedAt: earlier, songCount: 10)
        let mac = LibrarySnapshotDeviceEntry(deviceID: "mac", deviceName: "Mac", modifiedAt: later, songCount: 500)
        let updatedPhone = LibrarySnapshotDeviceEntry(deviceID: "phone", deviceName: "iPhone", modifiedAt: later, songCount: 12)
        let merged = Policy.merging(server: [phone, mac], upserting: updatedPhone)
        #expect(merged == [mac, updatedPhone])
        #expect(Policy.removing(deviceID: "mac", from: merged) == [updatedPhone])
        #expect(Policy.removing(deviceID: "unknown", from: merged) == merged)
    }

    @Test("Manifests round-trip through JSON and decode to nothing when absent")
    func manifestRoundTrip() {
        let entries = [
            LibrarySnapshotDeviceEntry(deviceID: "b", deviceName: "B", modifiedAt: earlier, songCount: 1),
            LibrarySnapshotDeviceEntry(deviceID: "a", deviceName: "A", modifiedAt: later, songCount: 2),
        ]
        let data = Policy.encode(entries)
        #expect(data != nil)
        #expect(Policy.decode(data) == entries.sorted { $0.deviceID < $1.deviceID })
        #expect(Policy.decode(nil).isEmpty)
        #expect(Policy.decode(Data("garbage".utf8)).isEmpty)
    }

    @Test("Merge order puts the most recent upload first, ties broken by device id")
    func mergeOrderIsNewestFirst() {
        let a = LibrarySnapshotDeviceEntry(deviceID: "a", deviceName: "A", modifiedAt: earlier, songCount: 1)
        let b = LibrarySnapshotDeviceEntry(deviceID: "b", deviceName: "B", modifiedAt: later, songCount: 1)
        let c = LibrarySnapshotDeviceEntry(deviceID: "c", deviceName: "C", modifiedAt: later, songCount: 1)
        #expect(Policy.mergeOrder([a, c, b]).map(\.deviceID) == ["b", "c", "a"])
    }

    @Test("The composite change tag is stable across dictionary order and includes every record")
    func compositeChangeTag() {
        let one = Policy.compositeChangeTag(manifestRecordTag: "m1", deviceRecordTags: ["b": "t2", "a": "t1"])
        let two = Policy.compositeChangeTag(manifestRecordTag: "m1", deviceRecordTags: ["a": "t1", "b": "t2"])
        #expect(one == two)
        #expect(one == "m1|a=t1|b=t2")
        #expect(Policy.compositeChangeTag(manifestRecordTag: nil, deviceRecordTags: ["a": nil]) == "|a=")
        #expect(Policy.compositeChangeTag(manifestRecordTag: "m2", deviceRecordTags: ["a": "t1", "b": "t2"]) != one)
    }

    @Test("Lyrics blobs merge with the first device winning per file")
    func lyricsBlobsMerge() {
        let merged = Policy.mergingLyricsBlobs([
            ["song-a.json": "new", "song-b.json": "b"],
            ["song-a.json": "old", "song-c.json": "c"],
        ])
        #expect(merged == ["song-a.json": "new", "song-b.json": "b", "song-c.json": "c"])
    }
}

@Suite("Merging device libraries per source")
struct LibrarySnapshotDeviceMergePolicyTests {
    typealias Policy = LibrarySnapshotDeviceManifestPolicy

    @Test("A newer device's whole-catalog source replaces what a stale device still lists")
    func newerWholeCatalogWins() {
        // 手机这次扫到 7930 首, 旧记录里还留着服务端已删的 2083 首。
        #expect(!Policy.admitsOlderDeviceSongs(
            sourceID: "navidrome",
            newerDeviceSongCounts: ["navidrome": 7_930],
            olderDeviceSongCounts: ["navidrome": 10_013],
            wholeCatalogSourceIDs: ["navidrome"]
        ))
    }

    @Test("Older devices still fill in sources the newer devices do not have")
    func missingSourceIsFilledFromOlderDevice() {
        #expect(Policy.admitsOlderDeviceSongs(
            sourceID: "jellyfin",
            newerDeviceSongCounts: ["navidrome": 7_930],
            olderDeviceSongCounts: ["jellyfin": 300],
            wholeCatalogSourceIDs: ["navidrome", "jellyfin"]
        ))
    }

    @Test("File sources keep the union because devices may scan different folders")
    func fileSourcesStayUnion() {
        #expect(Policy.admitsOlderDeviceSongs(
            sourceID: "webdav",
            newerDeviceSongCounts: ["webdav": 500],
            olderDeviceSongCounts: ["webdav": 800],
            wholeCatalogSourceIDs: []
        ))
    }

    @Test("A newer copy under half the older one looks unfinished and is not trusted to drop songs")
    func partialNewerCopyKeepsUnion() {
        #expect(Policy.admitsOlderDeviceSongs(
            sourceID: "navidrome",
            newerDeviceSongCounts: ["navidrome": 400],
            olderDeviceSongCounts: ["navidrome": 10_000],
            wholeCatalogSourceIDs: ["navidrome"]
        ))
        #expect(!Policy.admitsOlderDeviceSongs(
            sourceID: "navidrome",
            newerDeviceSongCounts: ["navidrome": 5_000],
            olderDeviceSongCounts: ["navidrome": 10_000],
            wholeCatalogSourceIDs: ["navidrome"]
        ))
    }
}
