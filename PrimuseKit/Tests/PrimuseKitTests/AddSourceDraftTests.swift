import Foundation
import Testing
@testable import PrimuseKit

struct AddSourceDraftTests {
    private func draft(
        name: String = "WebDAV",
        address: String = "",
        username: String = ""
    ) -> AddSourceDraft {
        AddSourceDraft(
            sourceType: "webdav",
            editingSourceID: nil,
            name: name,
            host: "",
            port: "443",
            useSsl: true,
            publicHost: "",
            publicPort: "443",
            publicUseSsl: true,
            localPathPrefix: "",
            publicBasePath: "",
            vendorIdentifier: "",
            synologyConnectionMode: "quickConnect",
            fnMusicConnectionMode: "fnConnect",
            username: username,
            basePath: "",
            shareName: "",
            exportPath: "",
            authType: "password",
            ftpEncryption: "none",
            nfsVersion: "auto",
            autoConnect: false,
            rememberDevice: false,
            addressRows: [
                .init(
                    address: address,
                    portText: "",
                    transport: "automatic",
                    showsAdvancedOptions: false,
                    treatDotlessTokenAsHostname: false
                ),
            ]
        )
    }

    @Test func untouchedFormIsNotKept() {
        #expect(!AddSourceDraftPolicy.shouldPersist(
            current: draft(),
            currentSecrets: .init(),
            pristine: draft(),
            pristineSecrets: .init()
        ))
    }

    @Test func anyFieldOrSecretChangeIsKept() {
        #expect(AddSourceDraftPolicy.shouldPersist(
            current: draft(address: "https://dav.example.com"),
            currentSecrets: .init(),
            pristine: draft(),
            pristineSecrets: .init()
        ))
        #expect(AddSourceDraftPolicy.shouldPersist(
            current: draft(),
            currentSecrets: .init(password: "secret"),
            pristine: draft(),
            pristineSecrets: .init()
        ))
    }

    @Test func roundTripsWithinTheWindow() throws {
        let savedAt = Date(timeIntervalSince1970: 1_000_000)
        let original = draft(name: "家里 NAS", address: "nas.local", username: "me")
        let data = try #require(AddSourceDraftPolicy.encode(original, savedAt: savedAt))
        let restored = AddSourceDraftPolicy.restorableDraft(
            from: data,
            now: savedAt.addingTimeInterval(AddSourceDraftPolicy.restoreWindow - 1)
        )
        #expect(restored == original)
    }

    @Test func staleOrFutureOrForeignRecordsAreDropped() throws {
        let savedAt = Date(timeIntervalSince1970: 1_000_000)
        let data = try #require(AddSourceDraftPolicy.encode(draft(), savedAt: savedAt))
        #expect(AddSourceDraftPolicy.restorableDraft(
            from: data,
            now: savedAt.addingTimeInterval(AddSourceDraftPolicy.restoreWindow + 1)
        ) == nil)
        #expect(AddSourceDraftPolicy.restorableDraft(
            from: data,
            now: savedAt.addingTimeInterval(-AddSourceDraftPolicy.clockSkewAllowance - 1)
        ) == nil)
        #expect(AddSourceDraftPolicy.restorableDraft(from: Data("{}".utf8), now: savedAt) == nil)

        var record = try JSONDecoder().decode(AddSourceDraftPolicy.StoredRecord.self, from: data)
        record.version += 1
        let newer = try JSONEncoder().encode(record)
        #expect(AddSourceDraftPolicy.restorableDraft(from: newer, now: savedAt) == nil)
    }

    @Test func secretsAreNeverPartOfTheStoredRecord() throws {
        let data = try #require(AddSourceDraftPolicy.encode(
            draft(username: "me"),
            savedAt: Date(timeIntervalSince1970: 0)
        ))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("password\":"))
        #expect(!json.contains("sshKey"))
        #expect(!json.contains("AccessCode"))
    }
}
