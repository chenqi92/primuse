import Foundation
import Testing
@testable import PrimuseKit

@Suite("iCloud key-value settings reconciliation")
struct CloudKVSReconciliationPolicyTests {
    typealias Policy = CloudKVSReconciliationPolicy
    typealias Version = CloudKVSReconciliationPolicy.Version

    @Test("A device that never wrote a key pulls the cloud copy and never pushes its defaults")
    func freshInstallPullsAndNeverPushes() {
        let remote = Version(revision: 1_000, writer: "mac")
        #expect(Policy.catchUpAction(local: .unset, hasLocalValue: true, remote: remote) == .pull)
        #expect(Policy.catchUpAction(local: .unset, hasLocalValue: false, remote: remote) == .pull)
        #expect(Policy.catchUpAction(local: .unset, hasLocalValue: true, remote: .unset) == .keep)
        #expect(Policy.catchUpAction(local: .unset, hasLocalValue: false, remote: .unset) == .keep)
    }

    @Test("An edit recorded while sync was off is pushed once the cloud copy is older")
    func offlineEditWinsOverOlderCloudCopy() {
        let local = Version(revision: 2_000, writer: "phone")
        let remote = Version(revision: 1_000, writer: "mac")
        #expect(Policy.catchUpAction(local: local, hasLocalValue: true, remote: remote) == .pushValue)
        #expect(Policy.catchUpAction(local: local, hasLocalValue: false, remote: remote) == .pushDeletion)
        #expect(Policy.catchUpAction(local: local, hasLocalValue: true, remote: .unset) == .pushValue)
    }

    @Test("A newer cloud copy replaces a stale local edit, including a cloud-side deletion")
    func newerCloudCopyIsPulled() {
        let local = Version(revision: 1_000, writer: "phone")
        let remote = Version(revision: 2_000, writer: "mac")
        #expect(Policy.catchUpAction(local: local, hasLocalValue: true, remote: remote) == .pull)
    }

    @Test("Equal revisions are a tie broken by writer id, and a device never pushes over itself")
    func tiesBreakByWriter() {
        let local = Version(revision: 1_000, writer: "a")
        let remote = Version(revision: 1_000, writer: "b")
        #expect(Policy.catchUpAction(local: local, hasLocalValue: true, remote: remote) == .pull)
        #expect(Policy.catchUpAction(local: remote, hasLocalValue: true, remote: local) == .pushValue)
        #expect(Policy.catchUpAction(local: local, hasLocalValue: true, remote: local) == .keep)
    }

    @Test("The next revision passes both sides and never falls behind the wall clock")
    func nextRevisionAdvances() {
        #expect(Policy.nextRevision(now: 100, local: 0, remote: 0) == 101)
        #expect(Policy.nextRevision(now: 100, local: 500, remote: 0) == 501)
        #expect(Policy.nextRevision(now: 100, local: 0, remote: 900) == 901)
    }

    @Test("Initial sync and account change take the cloud copy regardless of revisions")
    func reasonsThatOverrideRevisions() {
        #expect(Policy.appliesRemoteUnconditionally(.initialSync))
        #expect(Policy.appliesRemoteUnconditionally(.accountChange))
        #expect(!Policy.appliesRemoteUnconditionally(.serverChange))
        #expect(Policy.resetsLocalRevisions(.accountChange))
        #expect(!Policy.resetsLocalRevisions(.initialSync))
        #expect(!Policy.carriesRemoteValues(.quotaViolation))
        #expect(Policy.carriesRemoteValues(.serverChange))
    }

    @Test("Change reasons map from the store's raw values")
    func reasonMapping() {
        #expect(Policy.ExternalChangeReason(rawChangeReason: 0) == .serverChange)
        #expect(Policy.ExternalChangeReason(rawChangeReason: 1) == .initialSync)
        #expect(Policy.ExternalChangeReason(rawChangeReason: 2) == .quotaViolation)
        #expect(Policy.ExternalChangeReason(rawChangeReason: 3) == .accountChange)
        #expect(Policy.ExternalChangeReason(rawChangeReason: nil) == .unknown)
    }
}

@Suite("Device-local fields inside a whole-blob KVS setting")
struct CloudKVSDeviceLocalFieldsTests {
    /// 缩小版的整包设置: 两个跟着账号走的偏好, 两个只属于本机的硬件/存储决定。
    struct Settings: Equatable {
        var crossfadeEnabled = false
        var crossfadeDuration = 5.0
        var cacheEnabled = true
        var cacheLimitBytes: Int64 = 1_000
    }

    static let deviceLocal = CloudKVSDeviceLocalFields<Settings>([
        .init("cacheEnabled", \.cacheEnabled),
        .init("cacheLimitBytes", \.cacheLimitBytes),
    ])

    @Test("A remote blob updates synced fields and leaves this device's hardware decisions alone")
    func remoteBlobKeepsDeviceLocalValues() {
        let local = Settings(crossfadeEnabled: false, crossfadeDuration: 5, cacheEnabled: false, cacheLimitBytes: 2_000)
        let remote = Settings(crossfadeEnabled: true, crossfadeDuration: 8, cacheEnabled: true, cacheLimitBytes: 50_000)
        let result = Self.deviceLocal.merge(remote: remote, local: local)
        #expect(result.settings == Settings(crossfadeEnabled: true, crossfadeDuration: 8, cacheEnabled: false, cacheLimitBytes: 2_000))
        #expect(result.keptFields == ["cacheEnabled", "cacheLimitBytes"])
    }

    @Test("A fresh install keeps its defaults for device-local fields and takes the rest from the cloud")
    func freshInstallKeepsDefaults() {
        let remote = Settings(crossfadeEnabled: true, crossfadeDuration: 8, cacheEnabled: false, cacheLimitBytes: 50_000)
        let result = Self.deviceLocal.merge(remote: remote, local: Settings())
        #expect(result.settings == Settings(crossfadeEnabled: true, crossfadeDuration: 8, cacheEnabled: true, cacheLimitBytes: 1_000))
        #expect(result.keptFields == ["cacheEnabled", "cacheLimitBytes"])
    }

    @Test("Only fields whose local value differs are reported, so an identical blob needs no write-back")
    func identicalDeviceLocalValuesReportNothing() {
        let local = Settings(crossfadeEnabled: false, crossfadeDuration: 5, cacheEnabled: true, cacheLimitBytes: 1_000)
        let remote = Settings(crossfadeEnabled: true, crossfadeDuration: 8, cacheEnabled: true, cacheLimitBytes: 1_000)
        let result = Self.deviceLocal.merge(remote: remote, local: local)
        #expect(result.settings == remote)
        #expect(result.keptFields.isEmpty)

        let partial = Self.deviceLocal.merge(remote: remote, local: Settings(cacheLimitBytes: 3_000))
        #expect(partial.keptFields == ["cacheLimitBytes"])
        #expect(partial.settings.cacheLimitBytes == 3_000)
        #expect(partial.settings.cacheEnabled == true)
    }

    @Test("Merging is idempotent: applying the same blob twice changes nothing")
    func mergeIsIdempotent() {
        let local = Settings(crossfadeEnabled: false, crossfadeDuration: 5, cacheEnabled: false, cacheLimitBytes: 2_000)
        let remote = Settings(crossfadeEnabled: true, crossfadeDuration: 8, cacheEnabled: true, cacheLimitBytes: 50_000)
        let once = Self.deviceLocal.merge(remote: remote, local: local).settings
        let twice = Self.deviceLocal.merge(remote: remote, local: once)
        #expect(twice.settings == once)
        #expect(twice.keptFields == ["cacheEnabled", "cacheLimitBytes"])
        #expect(Self.deviceLocal.names == ["cacheEnabled", "cacheLimitBytes"])
    }
}
