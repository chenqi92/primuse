import Foundation
import Testing
@testable import PrimuseKit

/// 音乐源按设备启用、按源关闭 iCloud 同步的纯规则。
struct MusicSourceDeviceSettingsTests {
    private func source(
        _ id: String,
        enabled: Bool = true,
        modifiedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        deleted: Bool = false
    ) -> MusicSource {
        var row = MusicSource(id: id, name: id, type: .webdav, isEnabled: enabled, modifiedAt: modifiedAt)
        if deleted {
            row.isDeleted = true
            row.deletedAt = modifiedAt
        }
        return row
    }

    @Test func upgradeSeedKeepsEveryCurrentChoiceAndRecordsItAsTheSyncedValue() {
        var settings = MusicSourceDeviceSettings()
        let rows = [source("on", enabled: true), source("off", enabled: false)]

        let changed = settings.seed(from: rows)
        #expect(changed)
        #expect(settings.entries["on"]?.syncedIsEnabled == true)
        #expect(settings.entries["off"]?.syncedIsEnabled == false)
        #expect(settings.syncsViaICloud("on"))
        #expect(settings.syncsViaICloud("off"))
        // 往外写的那份与升级前完全一样,不会翻转任何设备。
        #expect(settings.outgoing(rows[0]) == rows[0])
        #expect(settings.outgoing(rows[1]) == rows[1])

        let seededAgain = settings.seed(from: rows)
        #expect(!seededAgain)
    }

    @Test func outgoingPayloadCarriesTheSyncedValueNotThisDevicesChoice() {
        var settings = MusicSourceDeviceSettings()
        settings.seed(from: [source("nas", enabled: true)])
        let locallyDisabled = source("nas", enabled: false)

        #expect(settings.outgoing(locallyDisabled).isEnabled)
        // 只有启用状态被换掉。
        var expected = locallyDisabled
        expected.isEnabled = true
        #expect(settings.outgoing(locallyDisabled) == expected)

        // 没有记录的行(别的设备的新源还没落地)原样写出。
        let unknown = source("unknown", enabled: false)
        #expect(settings.outgoing(unknown) == unknown)

        // 远端那份落地后,同步值跟着它走。
        let changed = settings.noteSyncedIsEnabled(false, for: "nas")
        #expect(changed)
        #expect(!settings.outgoing(source("nas", enabled: true)).isEnabled)
        let unchanged = settings.noteSyncedIsEnabled(false, for: "nas")
        #expect(!unchanged)
    }

    @Test func incomingRowKeepsThisDevicesEnableChoice() {
        let local = source("nas", enabled: false)
        var remote = source("nas", enabled: true, modifiedAt: Date(timeIntervalSinceReferenceDate: 2_000))
        remote.name = "Renamed elsewhere"

        let merged = MusicSourceDeviceSettings.applyingLocalEnablement(to: remote, local: local)
        #expect(!merged.isEnabled)
        #expect(merged.name == "Renamed elsewhere")
        #expect(merged.modifiedAt == remote.modifiedAt)

        // 第一次见到的源用同步来的值。
        let fresh = MusicSourceDeviceSettings.applyingLocalEnablement(to: remote, local: nil)
        #expect(fresh.isEnabled)
    }

    @Test func snapshotSourcesLeaveOptedOutRowsAsTheServerHadThem() {
        var settings = MusicSourceDeviceSettings()
        let shared = source("shared", enabled: false)
        let privateRow = source("private", enabled: true, modifiedAt: Date(timeIntervalSinceReferenceDate: 5_000))
        settings.seed(from: [source("shared", enabled: true), privateRow])
        settings.setSyncsViaICloud(false, for: "private", localRow: privateRow)

        let serverCopy = source("private", enabled: true, modifiedAt: Date(timeIntervalSinceReferenceDate: 3_000))
        let outgoing = settings.outgoingSnapshotSources(
            [shared, privateRow],
            carryingRemote: [serverCopy, source("other-device", enabled: true)]
        )
        let ids = outgoing.map(\.id)
        #expect(ids == ["shared", "private"])
        // 跟同步的源换成同步值;关了同步的源用服务器上那份,不是本机这行。
        #expect(outgoing[0].isEnabled)
        #expect(outgoing[1] == serverCopy)

        // 服务器上也没有它时就不写。
        let withoutRemote = settings.outgoingSnapshotSources([shared, privateRow])
        let remainingIDs = withoutRemote.map(\.id)
        #expect(remainingIDs == ["shared"])
    }

    @Test func parkingKeepsOnlyTheNewestRemoteAndDeletionsWin() {
        var settings = MusicSourceDeviceSettings()
        let local = source("nas")
        settings.setSyncsViaICloud(false, for: "nas", localRow: local)

        let older = source("nas", modifiedAt: Date(timeIntervalSinceReferenceDate: 2_000))
        let newer = source("nas", modifiedAt: Date(timeIntervalSinceReferenceDate: 3_000))
        let parkedNewer = settings.park(newer)
        let parkedOlder = settings.park(older)
        #expect(parkedNewer)
        #expect(!parkedOlder)
        #expect(settings.entries["nas"]?.parkedRemote == newer)

        let tombstone = source("nas", modifiedAt: Date(timeIntervalSinceReferenceDate: 2_500), deleted: true)
        let parkedTombstone = settings.park(tombstone)
        #expect(parkedTombstone)
        // 删除之后再来一份没有明确恢复的修改,删除仍然算数。
        let laterEdit = source("nas", modifiedAt: Date(timeIntervalSinceReferenceDate: 4_000))
        let parkedLaterEdit = settings.park(laterEdit)
        #expect(!parkedLaterEdit)
        #expect(settings.entries["nas"]?.parkedRemote?.isDeleted == true)
    }

    @Test func turningSyncOffRecordsTheClockAndTurningItOnPlansTheMerge() throws {
        var settings = MusicSourceDeviceSettings()
        let local = source("nas", modifiedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        settings.seed(from: [local])

        let off = settings.setSyncsViaICloud(false, for: "nas", localRow: local)
        #expect(off == MusicSourceSyncRejoinPlan(remoteToMerge: nil, uploadsLocal: false))
        #expect(settings.optedOutSourceIDs == ["nas"])
        #expect(settings.entries["nas"]?.localClockAtOptOut == local.modifiedAt)
        let repeatedOff = settings.setSyncsViaICloud(false, for: "nas", localRow: local)
        #expect(repeatedOff == nil)

        // 关着期间什么都没发生:重新打开不传、不合并。
        let on = settings.setSyncsViaICloud(true, for: "nas", localRow: local)
        let quiet = try #require(on)
        #expect(quiet == MusicSourceSyncRejoinPlan(remoteToMerge: nil, uploadsLocal: false))
        #expect(settings.syncsViaICloud("nas"))
        #expect(settings.entries["nas"]?.parkedRemote == nil)
        #expect(settings.entries["nas"]?.localClockAtOptOut == nil)
    }

    @Test func rejoinUploadsOnlyWhatIsNewerThanTheCloud() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let unchangedLocal = source("nas", modifiedAt: base)
        let editedLocal = source("nas", modifiedAt: base.addingTimeInterval(60))
        let setting = MusicSourceDeviceSetting(
            syncedIsEnabled: true,
            syncsViaICloud: false,
            localClockAtOptOut: base
        )

        // 关着期间本机改过 → 传上去。
        #expect(MusicSourceSyncRejoinPolicy.plan(local: editedLocal, setting: setting).uploadsLocal)
        #expect(!MusicSourceSyncRejoinPolicy.plan(local: unchangedLocal, setting: setting).uploadsLocal)

        // 从没传上去过(没有关掉时的时钟)→ 传上去。
        let neverSynced = MusicSourceDeviceSetting(syncedIsEnabled: true, syncsViaICloud: false)
        #expect(MusicSourceSyncRejoinPolicy.plan(local: unchangedLocal, setting: neverSynced).uploadsLocal)

        // 收到过更新的远端配置 → 合并远端、不传。
        var withNewerRemote = setting
        let remote = source("nas", modifiedAt: base.addingTimeInterval(120))
        withNewerRemote.parkedRemote = remote
        let mergeRemote = MusicSourceSyncRejoinPolicy.plan(local: editedLocal, setting: withNewerRemote)
        #expect(mergeRemote == MusicSourceSyncRejoinPlan(remoteToMerge: remote, uploadsLocal: false))

        // 收到的远端比本机旧 → 也交给合并(原有规则会留本机),并把本机传上去。
        var withOlderRemote = setting
        withOlderRemote.parkedRemote = source("nas", modifiedAt: base.addingTimeInterval(30))
        #expect(MusicSourceSyncRejoinPolicy.plan(local: editedLocal, setting: withOlderRemote).uploadsLocal)

        // 别的设备删掉了它:删除照原有规则落到本机,本机不把这行再传回去。
        var withRemoteDeletion = setting
        withRemoteDeletion.parkedRemote = source("nas", modifiedAt: base.addingTimeInterval(30), deleted: true)
        let deletion = MusicSourceSyncRejoinPolicy.plan(local: editedLocal, setting: withRemoteDeletion)
        #expect(deletion.remoteToMerge?.isDeleted == true)
        #expect(!deletion.uploadsLocal)

        // 只在这台设备上删掉的源:重新打开也不把删除传出去。
        let locallyDeleted = source("nas", modifiedAt: base.addingTimeInterval(90), deleted: true)
        #expect(!MusicSourceSyncRejoinPolicy.plan(local: locallyDeleted, setting: setting).uploadsLocal)
    }

    @Test func settingsRoundTripAndToleratePartialEntries() throws {
        var settings = MusicSourceDeviceSettings()
        let local = source("nas", enabled: false)
        settings.seed(from: [local])
        settings.setSyncsViaICloud(false, for: "nas", localRow: local)
        settings.park(source("nas", modifiedAt: Date(timeIntervalSinceReferenceDate: 9_000)))

        let data = try settings.encoded()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MusicSourceDeviceSettings.self, from: data)
        #expect(decoded == settings)

        let legacy = Data(#"{"entries":{"old":{"syncedIsEnabled":false}}}"#.utf8)
        let partial = try decoder.decode(MusicSourceDeviceSettings.self, from: legacy)
        #expect(partial.entries["old"]?.syncedIsEnabled == false)
        #expect(partial.syncsViaICloud("old"))
        #expect(partial.entries["old"]?.parkedRemote == nil)
    }
}
