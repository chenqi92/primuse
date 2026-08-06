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

    @Test("旧版本没有兼容指纹时执行一次全量拉取")
    func missingFingerprintRequiresFullRefetch() {
        #expect(CloudSourceTypeCompatibilityPolicy.action(
            storedFingerprint: nil
        ) == .resetAndRefetch)
        #expect(CloudSourceTypeCompatibilityPolicy.currentFingerprint.contains("drime"))
    }
}
