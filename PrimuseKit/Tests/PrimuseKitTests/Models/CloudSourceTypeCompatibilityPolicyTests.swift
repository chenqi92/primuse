import Testing
@testable import PrimuseKit

struct CloudSourceTypeCompatibilityPolicyTests {
    @Test("新增来源类型后必须重置同步游标并重新拉取")
    func addedSourceTypeRequiresFullRefetch() {
        let oldFingerprint = CloudSourceTypeCompatibilityPolicy.fingerprint(
            for: ["dropbox", "googleDrive"]
        )
        let newFingerprint = CloudSourceTypeCompatibilityPolicy.fingerprint(
            for: ["dropbox", "googleDrive", "drime"]
        )

        #expect(CloudSourceTypeCompatibilityPolicy.action(
            storedFingerprint: oldFingerprint,
            currentFingerprint: newFingerprint
        ) == .resetAndRefetch)
    }

    @Test("相同来源集合保留现有同步游标")
    func unchangedSourceTypesPreserveStateRegardlessOfOrdering() {
        let stored = CloudSourceTypeCompatibilityPolicy.fingerprint(
            for: ["drime", "dropbox", "googleDrive"]
        )
        let current = CloudSourceTypeCompatibilityPolicy.fingerprint(
            for: ["googleDrive", "drime", "dropbox", "drime"]
        )

        #expect(CloudSourceTypeCompatibilityPolicy.action(
            storedFingerprint: stored,
            currentFingerprint: current
        ) == .preserve)
    }

    @Test("只移除来源类型时保留同步游标")
    func removedSourceTypesPreserveState() {
        let stored = CloudSourceTypeCompatibilityPolicy.fingerprint(
            for: ["drime", "dropbox", "googleDrive"]
        )
        let current = CloudSourceTypeCompatibilityPolicy.fingerprint(
            for: ["dropbox", "googleDrive"]
        )

        #expect(CloudSourceTypeCompatibilityPolicy.action(
            storedFingerprint: stored,
            currentFingerprint: current
        ) == .preserve)
    }

    @Test("同时增删来源类型时只要有新增就重拉")
    func addedAndRemovedSourceTypesStillRefetch() {
        let stored = CloudSourceTypeCompatibilityPolicy.fingerprint(
            for: ["drime", "dropbox"]
        )
        let current = CloudSourceTypeCompatibilityPolicy.fingerprint(
            for: ["dropbox", "guangya"]
        )

        #expect(CloudSourceTypeCompatibilityPolicy.action(
            storedFingerprint: stored,
            currentFingerprint: current
        ) == .resetAndRefetch)
    }

    @Test("记录的指纹无法识别时按新增处理")
    func unrecognizedFingerprintRefetches() {
        #expect(CloudSourceTypeCompatibilityPolicy.action(
            storedFingerprint: "none",
            currentFingerprint: CloudSourceTypeCompatibilityPolicy.fingerprint(for: ["dropbox"])
        ) == .resetAndRefetch)
    }

    @Test("旧版本没有兼容指纹时执行一次全量拉取")
    func missingFingerprintRequiresFullRefetch() {
        #expect(CloudSourceTypeCompatibilityPolicy.action(
            storedFingerprint: nil
        ) == .resetAndRefetch)
        #expect(CloudSourceTypeCompatibilityPolicy.currentFingerprint.contains("drime"))
    }
}
