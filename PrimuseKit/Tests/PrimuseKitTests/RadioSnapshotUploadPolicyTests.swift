import Foundation
import Testing
@testable import PrimuseKit

@Suite("Debounced radio snapshot upload")
struct RadioSnapshotUploadPolicyTests {
    @Test("A running service with the sources channel on arms the debounce")
    func schedulesWhileRunning() {
        #expect(RadioSnapshotUploadPolicy.shouldSchedule(isStarted: true, isChannelEnabled: true))
    }

    @Test("A stopped service or a disabled channel arms nothing")
    func refusesToScheduleWhenInactive() {
        #expect(RadioSnapshotUploadPolicy.shouldSchedule(isStarted: false, isChannelEnabled: true) == false)
        #expect(RadioSnapshotUploadPolicy.shouldSchedule(isStarted: true, isChannelEnabled: false) == false)
        #expect(RadioSnapshotUploadPolicy.shouldSchedule(isStarted: false, isChannelEnabled: false) == false)
    }

    @Test("The change that armed the debounce uploads once the window elapses")
    func armedUploadRuns() {
        let token = UUID()
        #expect(
            RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: true, isCancelled: false, currentToken: token, taskToken: token
            )
        )
    }

    @Test("A service stopped during the debounce window uploads nothing")
    func stoppedDuringDebounce() {
        let token = UUID()
        #expect(
            RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: false, isCancelled: true, currentToken: nil, taskToken: token
            ) == false
        )
        #expect(
            RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: false, isCancelled: false, currentToken: token, taskToken: token
            ) == false
        )
    }

    @Test("A burst keeps only its last change — earlier tasks are superseded")
    func burstCollapsesToLastChange() {
        let first = UUID()
        let last = UUID()
        #expect(
            RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: true, isCancelled: true, currentToken: last, taskToken: first
            ) == false
        )
        #expect(
            RadioSnapshotUploadPolicy.shouldUpload(
                isStarted: true, isCancelled: false, currentToken: last, taskToken: last
            )
        )
    }

    @Test("The debounce window is short enough to stay interactive")
    func debounceWindowIsBounded() {
        #expect(RadioSnapshotUploadPolicy.debounce > .zero)
        #expect(RadioSnapshotUploadPolicy.debounce <= .seconds(5))
    }

    @Test("A long editing session cannot postpone the snapshot past the maximum delay")
    func boundedByMaximumDelay() {
        #expect(RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: nil) == RadioSnapshotUploadPolicy.debounce)
        #expect(RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: .seconds(0)) == RadioSnapshotUploadPolicy.debounce)
        let nearCap = RadioSnapshotUploadPolicy.maximumDelay - .seconds(1)
        #expect(RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: nearCap) == .seconds(1))
        #expect(RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: RadioSnapshotUploadPolicy.maximumDelay) == .zero)
        #expect(RadioSnapshotUploadPolicy.delay(sinceFirstPendingChange: .seconds(600)) == .zero)
    }
}

@Suite("外部改写电台文件后放回待上传的本机改动")
struct RadioPendingCloudUploadPolicyTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func station(
        _ id: String,
        name: String? = nil,
        at offset: TimeInterval = 0,
        isDeleted: Bool = false
    ) -> RadioStation {
        RadioStation(
            id: id,
            name: name ?? "Station \(id)",
            streamURL: "https://radio.example/\(id)",
            createdAt: base,
            modifiedAt: base.addingTimeInterval(offset),
            isDeleted: isDeleted,
            deletedAt: isDeleted ? base.addingTimeInterval(offset) : nil
        )
    }

    private func reapply(
        _ pending: [RadioStation],
        onto disk: [RadioStation]
    ) -> (rows: [RadioStation], restoredIDs: [String], supersededIDs: [String]) {
        RadioPendingCloudUploadPolicy.reapply(
            pendingLocal: pending,
            onto: disk,
            id: \.id,
            modifiedAt: \.modifiedAt
        )
    }

    @Test("本机新增、文件里没有的台追加到末尾")
    func restoresLocalAddition() {
        let added = station("new", at: 10)
        let result = reapply([added], onto: [station("a"), station("b")])
        #expect(result.rows.map(\.id) == ["a", "b", "new"])
        #expect(result.rows.last == added)
        #expect(result.restoredIDs == ["new"])
        #expect(result.supersededIDs.isEmpty)
    }

    @Test("本机改名比文件里的新，换回本机的版本")
    func restoresNewerLocalRename() {
        let renamed = station("a", name: "Renamed", at: 20)
        let result = reapply([renamed], onto: [station("a", at: 5), station("b")])
        #expect(result.rows.map(\.id) == ["a", "b"])
        #expect(result.rows[0].name == "Renamed")
        #expect(result.restoredIDs == ["a"])
        #expect(result.supersededIDs.isEmpty)
    }

    @Test("文件里的版本更新时保留文件里的，本机这次改动判为已被盖过")
    func newerDiskRowSupersedesLocal() {
        let local = station("a", name: "Local", at: 5)
        let remote = station("a", name: "Remote", at: 30)
        let result = reapply([local], onto: [remote])
        #expect(result.rows == [remote])
        #expect(result.restoredIDs.isEmpty)
        #expect(result.supersededIDs == ["a"])
    }

    @Test("修改时间相同但内容不同，仍以本机为准")
    func tieKeepsLocal() {
        let local = station("a", name: "Local", at: 5)
        let result = reapply([local], onto: [station("a", name: "Remote", at: 5)])
        #expect(result.rows == [local])
        #expect(result.restoredIDs == ["a"])
        #expect(result.supersededIDs.isEmpty)
    }

    @Test("本机删掉的台（墓碑）盖过文件里还活着的那一行")
    func localTombstoneWinsOverLiveRow() {
        let tombstone = station("a", at: 40, isDeleted: true)
        let result = reapply([tombstone], onto: [station("a", at: 10), station("b")])
        #expect(result.rows.map(\.id) == ["a", "b"])
        #expect(result.rows[0].isDeleted)
        #expect(result.restoredIDs == ["a"])
    }

    @Test("订阅的排除标记被放回，文件里没有时也追加")
    func restoresSubscriptionExclusionMarker() {
        var marker = station("sub-1", at: 50, isDeleted: true)
        marker.subscriptionID = "list"
        marker.subscriptionEntryKey = "radio.example/sub-1"
        marker.isSubscriptionExclusion = true
        #expect(marker.isSubscriptionExclusionMarker)

        var active = station("sub-1", at: 10)
        active.subscriptionID = "list"
        active.subscriptionEntryKey = "radio.example/sub-1"

        let replaced = reapply([marker], onto: [active])
        #expect(replaced.rows == [marker])
        #expect(replaced.restoredIDs == ["sub-1"])

        let appended = reapply([marker], onto: [station("other")])
        #expect(appended.rows.map(\.id) == ["other", "sub-1"])
        #expect(appended.rows[1].isSubscriptionExclusionMarker)
        #expect(appended.restoredIDs == ["sub-1"])
    }

    @Test("两行完全相同时什么都不做")
    func identicalRowsAreLeftAlone() {
        let row = station("a", at: 5)
        let disk = [row, station("b")]
        let result = reapply([row], onto: disk)
        #expect(result.rows == disk)
        #expect(result.restoredIDs.isEmpty)
        #expect(result.supersededIDs.isEmpty)
    }

    @Test("文件里原有的顺序不变，替换就地发生，新增依次排在末尾")
    func preservesDiskOrder() {
        let disk = [station("c"), station("a"), station("b")]
        let pending = [
            station("x", at: 1),
            station("a", name: "A2", at: 9),
            station("y", at: 2),
            station("a", name: "A3", at: 12)
        ]
        let result = reapply(pending, onto: disk)
        #expect(result.rows.map(\.id) == ["c", "a", "b", "x", "y"])
        #expect(result.rows[1].name == "A2")
        #expect(result.restoredIDs == ["x", "a", "y"])
    }

    @Test("没有待上传的行时原样返回")
    func emptyPendingIsNoOp() {
        let disk = [station("a"), station("b")]
        let result = reapply([], onto: disk)
        #expect(result.rows == disk)
        #expect(result.restoredIDs.isEmpty)
        #expect(result.supersededIDs.isEmpty)
    }
}

@Suite("远端删除的电台留墓碑")
struct RadioRemoteDeletionPolicyTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func live(_ id: String, at offset: TimeInterval) -> RadioStation {
        RadioStation(
            id: id,
            name: "Station \(id)",
            streamURL: "https://radio.example/\(id)",
            createdAt: base,
            modifiedAt: base.addingTimeInterval(offset),
            sortOrder: 2_048,
            folderName: "News",
            tagNames: ["Talk"]
        )
    }

    /// 写盘再读回：日期只留到秒。
    private func roundTripped(_ station: RadioStation) throws -> RadioStation {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RadioStation.self, from: encoder.encode(station))
    }

    @Test("活着的台变成墓碑，其余字段原样保留")
    func tombstonesLiveRow() throws {
        let row = live("a", at: 0)
        let now = base.addingTimeInterval(600)
        let tombstone = try #require(RadioRemoteDeletionPolicy.tombstone(row, at: now))
        #expect(tombstone.isDeleted)
        #expect(tombstone.deletedAt == now)
        #expect(tombstone.modifiedAt == now)
        #expect(tombstone.name == row.name)
        #expect(tombstone.streamURL == row.streamURL)
        #expect(tombstone.sortOrder == row.sortOrder)
        #expect(tombstone.folderName == "News")
        #expect(tombstone.tagNames == ["Talk"])
        #expect(!tombstone.isSubscriptionExclusionMarker)
    }

    @Test("已经是普通墓碑时不再改动")
    func ignoresExistingTombstone() {
        var row = live("a", at: 0)
        row.isDeleted = true
        row.deletedAt = base
        #expect(RadioRemoteDeletionPolicy.tombstone(row, at: base.addingTimeInterval(60)) == nil)
    }

    @Test("订阅的排除标记被远端删除后变成普通墓碑，保留原删除时间")
    func exclusionMarkerBecomesPlainTombstone() throws {
        var marker = live("radiosub.x.y", at: 0)
        marker.subscriptionID = "radiosub.x"
        marker.subscriptionEntryKey = "radio.example/radiosub.x.y"
        marker.isDeleted = true
        marker.deletedAt = base
        marker.isSubscriptionExclusion = true
        #expect(marker.isSubscriptionExclusionMarker)

        let now = base.addingTimeInterval(300)
        let tombstone = try #require(RadioRemoteDeletionPolicy.tombstone(marker, at: now))
        #expect(tombstone.isDeleted)
        #expect(!tombstone.isSubscriptionExclusionMarker)
        #expect(tombstone.isSubscriptionExclusion == nil)
        #expect(tombstone.deletedAt == base)
        #expect(tombstone.modifiedAt == now)
    }

    @Test("被删的那一版来自时钟走快的设备时，墓碑仍比它新一整秒")
    func tombstoneOutranksFutureDatedRow() throws {
        let row = live("a", at: 30)
        let now = base
        let tombstone = try #require(RadioRemoteDeletionPolicy.tombstone(row, at: now))
        #expect(tombstone.modifiedAt == row.modifiedAt.addingTimeInterval(1))
        #expect(tombstone.deletedAt == now)
    }

    @Test("过期快照里同一秒的那一版写盘读回后也盖不过墓碑")
    func staleSnapshotRowLosesAfterRoundTrip() throws {
        // 删除在那一版之后不到一秒就到了。
        let row = live("a", at: 0.2)
        let tombstone = try #require(RadioRemoteDeletionPolicy.tombstone(row, at: base.addingTimeInterval(0.7)))
        let storedTombstone = try roundTripped(tombstone)
        let staleSnapshotRow = try roundTripped(row)
        // 快照逐条合并的规则：本机的修改时间不晚于快照那一行就换成快照的。
        let snapshotWins = storedTombstone.modifiedAt <= staleSnapshotRow.modifiedAt
        #expect(!snapshotWins)
        #expect(storedTombstone.isDeleted)
    }
}
