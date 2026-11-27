import Foundation
import Testing
@testable import PrimuseKit

@Suite("Google Drive access change notice timing")
struct GoogleDriveAccessChangePolicyTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    @Test func effectiveDateIsLocalMidnightOfTheDay() {
        #expect(GoogleDriveAccessChangePolicy.effectiveDate(in: shanghai) == date("2026-11-19T16:00:00Z"))
        #expect(GoogleDriveAccessChangePolicy.effectiveDate(in: losAngeles) == date("2026-11-20T08:00:00Z"))
    }

    @Test func switchesPhaseAtLocalMidnight() {
        #expect(GoogleDriveAccessChangePolicy.phase(now: date("2026-10-02T12:00:00Z"), timeZone: shanghai) == .upcoming)
        #expect(GoogleDriveAccessChangePolicy.phase(now: date("2026-11-19T15:59:59Z"), timeZone: shanghai) == .upcoming)
        #expect(GoogleDriveAccessChangePolicy.phase(now: date("2026-11-19T16:00:00Z"), timeZone: shanghai) == .inEffect)
        #expect(GoogleDriveAccessChangePolicy.phase(now: date("2026-11-19T16:00:00Z"), timeZone: losAngeles) == .upcoming)
        #expect(GoogleDriveAccessChangePolicy.phase(now: date("2027-01-01T00:00:00Z"), timeZone: losAngeles) == .inEffect)
    }
}

@Suite("Google Drive drive.file Picker policy")
struct GoogleDrivePickerPolicyTests {
    private typealias Policy = GoogleDrivePickerPolicy
    private let fileScopeExtra = [GoogleDrivePickerPolicy.oauthScopeExtraKey: GoogleDrivePickerPolicy.fileScope]
    private let fullDriveExtra = [GoogleDrivePickerPolicy.oauthScopeExtraKey: GoogleDrivePickerPolicy.legacyFullDriveScope]

    @Test("Classifies the granted scope recorded on the token")
    func grantedScopeClassification() {
        #expect(Policy.grantedScope(Policy.fileScope) == .filesOnly)
        #expect(Policy.grantedScope("openid https://www.googleapis.com/auth/drive.file") == .filesOnly)
        #expect(Policy.grantedScope(Policy.legacyFullDriveScope) == .fullDrive)
        #expect(Policy.grantedScope(Policy.legacyReadOnlyDriveScope) == .fullDrive)
        #expect(Policy.grantedScope("https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/drive.file") == .fullDrive)
        #expect(Policy.grantedScope(nil) == .unstated)
        #expect(Policy.grantedScope("  ") == .unstated)
    }

    @Test("The access mode comes from the stored fact, not from the token's picked ids")
    func modeFromStoredFact() {
        // 没存访问方式的源是这一版之前的整盘源,令牌附加字段里有没有已选文件都一样。
        let idsOnly = [Policy.pickedFileIDsExtraKey: "a,b"]
        #expect(Policy.listingDecision(storedMode: nil, tokenExtra: .found(idsOnly), path: "folder") == .legacyFolders)
        #expect(Policy.listingDecision(storedMode: nil, tokenExtra: .found(nil), path: "/") == .legacyFolders)
        #expect(Policy.listingDecision(storedMode: .legacyFullDrive, tokenExtra: .found(fullDriveExtra), path: "folder") == .legacyFolders)
        // 已选文件源的令牌被旧版 App 刷新、丢了附加字段:仍按已选文件列,不退回整盘。
        #expect(Policy.listingDecision(storedMode: .pickedFiles, tokenExtra: .found(nil), path: "/") == .pickedFiles)
        #expect(Policy.listingDecision(storedMode: .pickedFiles, tokenExtra: .found(fileScopeExtra), path: "") == .pickedFiles)
        #expect(Policy.listingDecision(storedMode: .pickedFiles, tokenExtra: .found(fileScopeExtra), path: "root") == .pickedFiles)
        #expect(Policy.listingDecision(storedMode: .pickedFiles, tokenExtra: .found(fileScopeExtra), path: nil) == .pickedFiles)
        #expect(Policy.effectiveMode(stored: nil) == .legacyFullDrive)
    }

    @Test("An unreadable token is 'cannot answer', never a silent legacy listing")
    func unreadableTokenCannotAnswer() {
        #expect(Policy.listingDecision(storedMode: .pickedFiles, tokenExtra: .unreadable, path: "/") == .cannotAnswer)
        #expect(Policy.listingDecision(storedMode: nil, tokenExtra: .unreadable, path: "folder") == .cannotAnswer)
    }

    @Test("Half-migrated states require choosing files again instead of a partial listing")
    func mixedStatesRequireReselection() {
        // drive.file 令牌 + 旧的文件夹根目录(重新授权没改目录、电视代登录后、刷新回来的是 drive.file)。
        #expect(Policy.listingDecision(storedMode: nil, tokenExtra: .found(fileScopeExtra), path: "folderID") == .requiresReselection)
        #expect(Policy.listingDecision(storedMode: .legacyFullDrive, tokenExtra: .found(fileScopeExtra), path: "/") == .requiresReselection)
        #expect(Policy.listingDecision(storedMode: .legacyFullDrive, tokenExtra: .found(fileScopeExtra), path: nil) == .requiresReselection)
        // 已选文件源的配置里还留着文件夹。
        #expect(Policy.listingDecision(storedMode: .pickedFiles, tokenExtra: .found(fileScopeExtra), path: "folderID") == .requiresReselection)
        // 已选文件源拿到能看整盘的令牌:平铺列表只会多出歌,照旧按已选文件列。
        #expect(Policy.listingDecision(storedMode: .pickedFiles, tokenExtra: .found(fullDriveExtra), path: "/") == .pickedFiles)
    }

    @Test("A callback without picked files means nothing was chosen")
    func emptyCallback() throws {
        let missing = try #require(URL(string: "com.googleusercontent.apps.123:/oauth2redirect?code=abc&state=xyz"))
        let empty = try #require(URL(string: "com.googleusercontent.apps.123:/oauth2redirect?code=abc&state=xyz&picked_file_ids="))
        let blanks = try #require(URL(string: "com.googleusercontent.apps.123:/oauth2redirect?code=abc&state=xyz&picked_file_ids=,%20,"))
        let chosen = try #require(URL(string: "com.googleusercontent.apps.123:/oauth2redirect?code=abc&state=xyz&picked_file_ids=id1,%20id2,id1,,id3"))
        #expect(Policy.callbackSelection(from: missing) == .nothingChosen)
        #expect(Policy.callbackSelection(from: empty) == .nothingChosen)
        #expect(Policy.callbackSelection(from: blanks) == .nothingChosen)
        #expect(Policy.callbackSelection(from: chosen) == .chosen(["id1", "id2", "id3"]))
    }

    @Test("Re-authorization keeps the source's account id unless the account is shown to differ")
    func accountIdentityRetention() {
        // 新源:用新标识。
        #expect(Policy.accountLink(existingAccountID: nil, storedEmail: nil, incomingEmail: "a@example.com", isExplicitAccountSwitch: false) == .adoptIncoming)
        #expect(Policy.accountLink(existingAccountID: "  ", storedEmail: nil, incomingEmail: nil, isExplicitAccountSwitch: false) == .adoptIncoming)
        // 旧源没存邮箱:留着原来的(OIDC sub 派生的)标识。
        #expect(Policy.accountLink(existingAccountID: "sub-id", storedEmail: nil, incomingEmail: "a@example.com", isExplicitAccountSwitch: false) == .keepExisting("sub-id"))
        // 同一邮箱(不区分大小写):留着。
        #expect(Policy.accountLink(existingAccountID: "sub-id", storedEmail: "A@Example.com ", incomingEmail: "a@example.COM", isExplicitAccountSwitch: false) == .keepExisting("sub-id"))
        // 读不到新邮箱:证明不了换了账号,留着。
        #expect(Policy.accountLink(existingAccountID: "sub-id", storedEmail: "a@example.com", incomingEmail: nil, isExplicitAccountSwitch: false) == .keepExisting("sub-id"))
        // 邮箱不同,或者用户走了「换账号」:用新标识。
        #expect(Policy.accountLink(existingAccountID: "sub-id", storedEmail: "a@example.com", incomingEmail: "b@example.com", isExplicitAccountSwitch: false) == .adoptIncoming)
        #expect(Policy.accountLink(existingAccountID: "sub-id", storedEmail: nil, incomingEmail: nil, isExplicitAccountSwitch: true) == .adoptIncoming)
        #expect(!Policy.accountDiffers(storedEmail: nil, incomingEmail: "b@example.com"))
    }

    @Test("A TV sign-in payload without a scope comes from an older phone and is legacy")
    func tvPayloadDefault() {
        let existing = [
            Policy.oauthScopeExtraKey: Policy.fileScope,
            Policy.pickedFileIDsExtraKey: "id1",
        ]
        let legacy = Policy.proxyLoginAuthorization(existingExtra: existing, payloadScope: nil, payloadPickedFileIDs: nil)
        #expect(legacy.accessMode == .legacyFullDrive)
        // 旧令牌的 drive.file 范围不能沿用到这枚新令牌上。
        #expect(legacy.tokenExtra?[Policy.oauthScopeExtraKey] == nil)
        #expect(Policy.proxyLoginAuthorization(existingExtra: nil, payloadScope: " ", payloadPickedFileIDs: nil).accessMode == .legacyFullDrive)
        #expect(Policy.proxyLoginAuthorization(existingExtra: nil, payloadScope: Policy.legacyFullDriveScope, payloadPickedFileIDs: nil).accessMode == .legacyFullDrive)

        let picked = Policy.proxyLoginAuthorization(existingExtra: existing, payloadScope: Policy.fileScope, payloadPickedFileIDs: ["id2", "id1"])
        #expect(picked.accessMode == .pickedFiles)
        #expect(picked.tokenExtra?[Policy.oauthScopeExtraKey] == Policy.fileScope)
        #expect(picked.tokenExtra?[Policy.pickedFileIDsExtraKey] == "id1,id2")
    }

    @Test("A remote copy without the stored mode does not erase it")
    func storedModeSurvivesOlderDevices() throws {
        #expect(Policy.mergedStoredAccessMode(local: .pickedFiles, remote: nil) == .pickedFiles)
        #expect(Policy.mergedStoredAccessMode(local: nil, remote: .pickedFiles) == .pickedFiles)
        #expect(Policy.mergedStoredAccessMode(local: .legacyFullDrive, remote: .pickedFiles) == .pickedFiles)
        #expect(Policy.mergedStoredAccessMode(local: nil, remote: nil) == nil)

        var source = MusicSource(id: "gd", name: "GD", type: .googleDrive)
        source.googleDriveAccessMode = .pickedFiles
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(MusicSource.self, from: data)
        #expect(decoded.googleDriveAccessMode == .pickedFiles)
        #expect(decoded.usesGoogleDrivePickedFiles)

        // 旧版本写的源没有这个字段;将来新增的取值旧版本不认识,源照样读得出来。
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "googleDriveAccessMode")
        let older = try JSONDecoder().decode(MusicSource.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.googleDriveAccessMode == nil)
        #expect(!older.usesGoogleDrivePickedFiles)
        object["googleDriveAccessMode"] = "someFutureMode"
        let future = try JSONDecoder().decode(MusicSource.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(future.googleDriveAccessMode == nil)
        #expect(future.id == "gd")
    }

    @Test("Merges picked file IDs cumulatively for same account and resets on account switch")
    func mergedTokenExtra() {
        let existing: [String: String] = [
            Policy.oauthScopeExtraKey: Policy.fileScope,
            Policy.pickedFileIDsExtraKey: "id1,id2",
            Policy.accountEmailExtraKey: "a@example.com",
        ]
        let incoming: [String: String] = [
            Policy.oauthScopeExtraKey: Policy.fileScope,
            Policy.pickedFileIDsExtraKey: "id2,id3",
        ]

        let cumulative = Policy.mergedTokenExtra(existing: existing, incoming: incoming, replacingAccount: false)
        #expect(cumulative?[Policy.oauthScopeExtraKey] == Policy.fileScope)
        #expect(cumulative?[Policy.pickedFileIDsExtraKey] == "id1,id2,id3")
        #expect(cumulative?[Policy.accountEmailExtraKey] == "a@example.com")

        let replaced = Policy.mergedTokenExtra(existing: existing, incoming: incoming, replacingAccount: true)
        #expect(replaced?[Policy.pickedFileIDsExtraKey] == "id2,id3")
        #expect(replaced?[Policy.accountEmailExtraKey] == nil)

        // 刷新回来没写范围时沿用同一枚授权的范围。
        let refreshed = Policy.mergedTokenExtra(existing: existing, incoming: nil, grantedScope: nil)
        #expect(refreshed?[Policy.oauthScopeExtraKey] == Policy.fileScope)
    }

    @Test("Device auth scope for Google Drive uses drive.file")
    func deviceAuthUsesFileScope() {
        #expect(CloudDeviceAuthRequests.deviceCodeScope(for: .googleDrive) == Policy.fileScope)
        #expect(MusicSourceType.googleDrive.usesExternalFilePicker)
        #expect(!MusicSourceType.oneDrive.usesExternalFilePicker)
    }

    @Test("The reminder follows the access mode and both root tests agree")
    func reminderAndRootAgreement() {
        // 整盘扫描整个 My Drive(目录是 "/")的旧源也要看到提醒。
        #expect(Policy.showsLegacyAccessReminder(storedMode: nil, configuredRoots: ["/"]))
        #expect(Policy.showsLegacyAccessReminder(storedMode: .legacyFullDrive, configuredRoots: ["1AbCdEfFolderID"]))
        #expect(!Policy.showsLegacyAccessReminder(storedMode: nil, configuredRoots: []))
        #expect(!Policy.showsLegacyAccessReminder(storedMode: .pickedFiles, configuredRoots: ["/"]))
        #expect(!Policy.showsLegacyAccessReminder(storedMode: .pickedFiles, configuredRoots: ["1AbCdEfFolderID"]))

        for path in ["/", "", "//", "/ ", " "] {
            #expect(Policy.isAuthorizedFilesRoot(path), "\(path)")
        }
        #expect(Policy.isAuthorizedFilesRoot("root"))
        #expect(!Policy.isAuthorizedFilesRoot("1AbCdEfFolderID"))
        for path in ["/", "", "//", "/Music", "1AbCdEfFolderID"] {
            #expect(Policy.isAuthorizedFilesRoot(path) == SourceDirectorySelectionPolicy.isRootPath(path), "\(path)")
        }
    }
}

@Suite("Google Drive picked-files removal confirmation")
struct GoogleDrivePickedFilesRemovalPolicyTests {
    private typealias Policy = GoogleDrivePickedFilesRemovalPolicy

    @Test("Picker scans hold removals even without a previous state")
    func holdsAfterScopeChange() {
        #expect(Policy.holdsRemovals(scopeMatchesPreviousState: false, storedKind: nil))
        #expect(Policy.holdsRemovals(scopeMatchesPreviousState: true, storedKind: .pickedFilesRemovalConfirmation))
        #expect(Policy.holdsRemovals(scopeMatchesPreviousState: true, storedKind: .pickedFilesRemovalKept))
        #expect(Policy.holdsRemovals(scopeMatchesPreviousState: true, storedKind: .pickedFilesRemovalConfirmed))
        #expect(!Policy.holdsRemovals(scopeMatchesPreviousState: true, storedKind: nil))
        #expect(!Policy.holdsRemovals(scopeMatchesPreviousState: true, storedKind: .serverCatalogMassDisappearance))
    }

    @Test("N missing songs: none removed until confirmed, exactly those after, all kept on decline")
    func confirmThenRemoveExactly() {
        let missing: Set<String> = Set((1...5).map { "song-\($0)" })
        let first = Policy.outcome(missingSongIDs: missing, storedKind: nil, storedSongIDs: [])
        #expect(first.removedSongIDs.isEmpty)
        #expect(first.retainedMissingSongIDs == missing)
        #expect(first.reconciliation == .pickedFilesRemovalConfirmation)
        #expect(first.promptCount == 5)

        // 用户确认以后其中一首又被选回来了:只移除仍然不在列表里的那几首。
        let stillMissing = missing.subtracting(["song-5"])
        let confirmed = Policy.outcome(
            missingSongIDs: stillMissing,
            storedKind: .pickedFilesRemovalConfirmed,
            storedSongIDs: first.unresolvedSongIDs
        )
        #expect(confirmed.removedSongIDs == stillMissing)
        #expect(confirmed.retainedMissingSongIDs.isEmpty)
        #expect(confirmed.reconciliation == nil)

        // 确认之后又有新的歌不在列表里:它们不跟着一起删,重新等确认。
        let grown = Policy.outcome(
            missingSongIDs: missing.union(["song-9"]),
            storedKind: .pickedFilesRemovalConfirmed,
            storedSongIDs: missing
        )
        #expect(grown.removedSongIDs == missing)
        #expect(grown.retainedMissingSongIDs == ["song-9"])
        #expect(grown.promptCount == 1)

        // 选保留:一首不删,也不再提示。
        let kept = Policy.outcome(missingSongIDs: missing, storedKind: .pickedFilesRemovalKept, storedSongIDs: missing)
        #expect(kept.removedSongIDs.isEmpty)
        #expect(kept.retainedMissingSongIDs == missing)
        #expect(kept.reconciliation == .pickedFilesRemovalKept)
        #expect(kept.promptCount == nil)

        // 保留之后又少了别的歌:再问一次,仍然一首不删。
        let keptGrown = Policy.outcome(missingSongIDs: missing.union(["song-9"]), storedKind: .pickedFilesRemovalKept, storedSongIDs: missing)
        #expect(keptGrown.removedSongIDs.isEmpty)
        #expect(keptGrown.promptCount == 6)

        // 都回来了:没有要确认的。
        #expect(Policy.outcome(missingSongIDs: [], storedKind: .pickedFilesRemovalKept, storedSongIDs: missing) == .init())
    }

    @Test("Apple TV never prunes a picked-files source")
    func tvDoesNotPrunePickedFiles() {
        var picked = MusicSource(name: "GD", type: .googleDrive)
        picked.googleDriveAccessMode = .pickedFiles
        #expect(!Policy.tvScanPrunesMissingSongs(source: picked))
        #expect(Policy.tvScanPrunesMissingSongs(source: MusicSource(name: "GD", type: .googleDrive)))
        #expect(Policy.tvScanPrunesMissingSongs(source: MusicSource(name: "OD", type: .oneDrive)))
    }
}
