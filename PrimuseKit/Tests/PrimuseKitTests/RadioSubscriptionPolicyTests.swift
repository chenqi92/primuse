import Foundation
import Testing
@testable import PrimuseKit

@Suite("Radio list subscriptions")
struct RadioSubscriptionPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var t1: Date { t0.addingTimeInterval(3_600) }
    private var t2: Date { t0.addingTimeInterval(7_200) }
    private var t3: Date { t0.addingTimeInterval(10_800) }

    // MARK: - 夹具

    private func subscription(
        _ listURL: String = "https://lists.example.com/radio.m3u",
        groupsAsFolders: Bool = false
    ) -> RadioSubscription {
        RadioSubscription.make(listURL: listURL, usesListGroupsAsFolders: groupsAsFolders, now: t0)!
    }

    private func entry(
        _ name: String,
        _ url: String,
        logo: String? = nil,
        homepage: String? = nil,
        group: String? = nil,
        status: RadioImportCandidate.Status = .playable
    ) -> RadioImportCandidate {
        RadioImportCandidate(
            name: name,
            urlString: url,
            status: status,
            logoURLString: logo,
            homepageURLString: homepage,
            logoSource: logo == nil ? nil : .importedManifest,
            groupTitle: group
        )
    }

    private func key(_ url: String) -> String {
        RadioImportParser.streamIdentityKey(url)!
    }

    private func stationID(_ sub: RadioSubscription, _ url: String, attempt: Int = 0) -> String {
        RadioSubscriptionIdentity.stationID(subscriptionID: sub.id, entryKey: key(url), attempt: attempt)
    }

    /// 模拟 store 落盘：按 id 覆盖或追加。
    private func applying(_ plan: RadioSubscriptionRefreshPlan, to stations: [RadioStation]) -> [RadioStation] {
        var result = stations
        for change in plan.changes {
            if let index = result.firstIndex(where: { $0.id == change.id }) {
                result[index] = change
            } else {
                result.append(change)
            }
        }
        return result
    }

    private func merge(
        _ sub: RadioSubscription,
        _ candidates: [RadioImportCandidate],
        _ stations: [RadioStation],
        excluded: Set<String> = [],
        confirms: Bool = false,
        at now: Date
    ) throws -> RadioSubscriptionRefreshPlan {
        try RadioSubscriptionMergePolicy.merge(
            subscription: sub,
            candidates: candidates,
            stations: stations,
            newlyExcludedEntryKeys: excluded,
            confirmsHeldRemovals: confirms,
            now: now
        )
    }

    private func find(_ id: String, in stations: [RadioStation]) -> RadioStation? {
        stations.first { $0.id == id }
    }

    // MARK: - 身份

    @Test("Subscription ids ignore scheme, host case and trailing slash, and never look like server mirrors")
    func subscriptionIdentityIsDeterministic() {
        let a = RadioSubscriptionIdentity.subscriptionID(listURL: "http://Lists.Example.com/radio.m3u/")
        let b = RadioSubscriptionIdentity.subscriptionID(listURL: "https://lists.example.com/radio.m3u")
        let other = RadioSubscriptionIdentity.subscriptionID(listURL: "https://lists.example.com/other.m3u")
        #expect(a != nil)
        #expect(a == b)
        #expect(a != other)
        #expect(a?.hasPrefix(RadioSubscriptionIdentity.idPrefix) == true)
        #expect(a?.hasPrefix(ServerRadioStationIdentity.stationIDPrefix) == false)
        #expect(RadioSubscriptionIdentity.subscriptionID(listURL: "ftp://lists.example.com/a.m3u") == nil)
        #expect(RadioSubscription.make(listURL: "not a url") == nil)
    }

    @Test("Station ids are deterministic per entry, with a deterministic fallback")
    func stationIdentityIsDeterministic() {
        let first = RadioSubscriptionIdentity.stationID(subscriptionID: "radiosub.x", entryKey: "a.example/one")
        let again = RadioSubscriptionIdentity.stationID(subscriptionID: "radiosub.x", entryKey: "a.example/one")
        let fallback = RadioSubscriptionIdentity.stationID(
            subscriptionID: "radiosub.x",
            entryKey: "a.example/one",
            attempt: 1
        )
        #expect(first == again)
        #expect(first.hasPrefix("radiosub.x."))
        #expect(fallback != first)
        #expect(fallback == RadioSubscriptionIdentity.stationID(
            subscriptionID: "radiosub.x",
            entryKey: "a.example/one",
            attempt: 1
        ))
        #expect(StableFNV1a64.hexDigest("a").count == 16)
    }

    @Test("Default names come from the list file name, then the host")
    func defaultNames() {
        #expect(RadioSubscriptionIdentity.defaultName(listURL: "https://example.com/lists/jazz.m3u") == "jazz")
        #expect(RadioSubscriptionIdentity.defaultName(listURL: "https://radio.example.com/") == "radio.example.com")
        #expect(subscription().displayHost == "lists.example.com")
    }

    // MARK: - 新建 / 更新 / 无变化

    @Test("A first merge creates stations with deterministic ids, list fields and trailing sort order")
    func createsStations() throws {
        let sub = subscription()
        let manual = RadioStation(id: "manual", name: "Mine", streamURL: "https://mine.example/live", sortOrder: 4)
        let plan = try merge(sub, [
            entry("Alpha", "https://a.example/one", homepage: "https://a.example"),
            entry("Beta", "https://b.example/two.aac", logo: "https://b.example/logo.png", group: "News"),
        ], [manual], at: t1)

        #expect(plan.summary.added == 2)
        #expect(plan.summary.totalEntries == 2)
        #expect(plan.changes.count == 2)
        #expect(plan.heldRemovalStationIDs.isEmpty)
        let alpha = try #require(find(stationID(sub, "https://a.example/one"), in: plan.changes))
        let beta = try #require(find(stationID(sub, "https://b.example/two.aac"), in: plan.changes))
        #expect(plan.addedStationIDs == [alpha.id, beta.id])
        #expect(alpha.subscriptionID == sub.id)
        #expect(alpha.subscriptionEntryKey == "a.example/one")
        #expect(alpha.isSubscribed)
        #expect(!alpha.isDeleted)
        #expect(alpha.homepageURL == "https://a.example")
        #expect(alpha.sortOrder == 5)
        #expect(beta.sortOrder == 6)
        #expect(beta.streamFormat == .aac)
        #expect(beta.remoteLogoURL == "https://b.example/logo.png")
        #expect(beta.remoteLogoSource == .importedManifest)
        // 没开「按清单分组放进文件夹」
        #expect(beta.folderName == nil)
        #expect(alpha.createdAt == t1)
        #expect(alpha.modifiedAt == t1)
    }

    @Test("List groups become folders only when the subscription asks for it")
    func groupsBecomeFoldersOnCreation() throws {
        let sub = subscription(groupsAsFolders: true)
        let plan = try merge(sub, [entry("Beta", "https://b.example/two", group: "News")], [], at: t1)
        #expect(plan.changes.first?.folderName == "News")
        // 库里没有任何电台排过序时，新电台也不强加一个序号。
        #expect(plan.changes.first?.sortOrder == nil)
    }

    @Test("Only the first entry per stream key counts, invalid entries are counted and dropped")
    func deduplicatesWithinTheList() throws {
        let sub = subscription()
        let plan = try merge(sub, [
            entry("One", "https://a.example/one"),
            entry("One again", "http://a.example/one/", status: .duplicate),
            entry("Broken", "ftp://nope", status: .invalid),
        ], [], at: t1)
        #expect(plan.summary.added == 1)
        #expect(plan.summary.invalid == 1)
        #expect(plan.summary.totalEntries == 1)
        #expect(plan.changes.first?.name == "One")
    }

    @Test("A list-field change updates the station and keeps every user-owned field")
    func updatesListFields() throws {
        let sub = subscription()
        var stations = applying(try merge(sub, [entry("Alpha", "http://a.example/one")], [], at: t1), to: [])
        let id = stationID(sub, "http://a.example/one")
        let index = try #require(stations.firstIndex { $0.id == id })
        stations[index].tagNames = ["Jazz"]
        stations[index].folderName = "Evening"
        stations[index].logoData = Data([1, 2, 3])
        stations[index].sortOrder = 9
        stations[index].lastPlayedAt = t1
        stations[index].bitRate = 128_000

        let plan = try merge(sub, [
            entry("Alpha FM", "https://a.example/one", logo: "https://a.example/logo.png", group: "Other"),
        ], stations, at: t2)
        #expect(plan.summary.updated == 1)
        let updated = try #require(plan.changes.first)
        #expect(updated.id == id)
        #expect(updated.name == "Alpha FM")
        #expect(updated.streamURL == "https://a.example/one")
        #expect(updated.remoteLogoURL == "https://a.example/logo.png")
        #expect(updated.modifiedAt == t2)
        #expect(updated.tagNames == ["Jazz"])
        #expect(updated.folderName == "Evening")
        #expect(updated.logoData == Data([1, 2, 3]))
        #expect(updated.sortOrder == 9)
        #expect(updated.lastPlayedAt == t1)
        #expect(updated.bitRate == 128_000)
        #expect(updated.createdAt == t1)
    }

    @Test("An unchanged list produces no writes at all")
    func unchangedListWritesNothing() throws {
        let sub = subscription()
        let candidates = [entry("Alpha", "https://a.example/one"), entry("Beta", "https://b.example/two")]
        let stations = applying(try merge(sub, candidates, [], at: t1), to: [])
        let plan = try merge(sub, candidates, stations, at: t2)
        #expect(plan.changes.isEmpty)
        #expect(plan.summary.unchanged == 2)
        #expect(!plan.summary.hasChanges)
    }

    @Test("List logos never replace user logos; a missing list logo keeps a discovered one")
    func logoOwnership() throws {
        let sub = subscription()
        var stations = applying(try merge(sub, [
            entry("User", "https://u.example/live"),
            entry("Found", "https://f.example/live", homepage: "https://f.example"),
        ], [], at: t1), to: [])
        let userID = stationID(sub, "https://u.example/live")
        let foundID = stationID(sub, "https://f.example/live")
        stations[stations.firstIndex { $0.id == userID }!].remoteLogoURL = "https://mine.example/logo.png"
        stations[stations.firstIndex { $0.id == userID }!].remoteLogoSource = .userProvidedURL
        stations[stations.firstIndex { $0.id == foundID }!].remoteLogoURL = "https://f.example/icon.png"
        stations[stations.firstIndex { $0.id == foundID }!].remoteLogoSource = .homepageIcon

        // 清单给了台标，但用户自己指定过 —— 不动；另一个清单没给台标、也没给主页 —— 保留现值。
        let plan = try merge(sub, [
            entry("User", "https://u.example/live", logo: "https://list.example/u.png"),
            entry("Found", "https://f.example/live"),
        ], stations, at: t2)
        #expect(plan.changes.isEmpty)

        // 清单开始给台标了：覆盖自动发现的那张，来源记成清单。
        let second = try merge(sub, [
            entry("User", "https://u.example/live"),
            entry("Found", "https://f.example/live", logo: "https://list.example/f.png"),
        ], stations, at: t2)
        let found = try #require(find(foundID, in: second.changes))
        #expect(found.remoteLogoURL == "https://list.example/f.png")
        #expect(found.remoteLogoSource == .importedManifest)
        #expect(found.homepageURL == "https://f.example")
    }

    // MARK: - 排除与复活

    @Test("An exclusion marker is never revived by later refreshes")
    func exclusionIsNeverRevived() throws {
        let sub = subscription()
        var stations = applying(try merge(sub, [
            entry("Alpha", "https://a.example/one"),
            entry("Beta", "https://b.example/two"),
        ], [], at: t1), to: [])
        let alphaID = stationID(sub, "https://a.example/one")
        let index = try #require(stations.firstIndex { $0.id == alphaID })
        stations[index] = RadioSubscriptionMergePolicy.excluding(stations[index], now: t2)
        #expect(stations[index].isSubscriptionExclusionMarker)
        #expect(stations[index].subscriptionID == sub.id)

        let plan = try merge(sub, [
            entry("Alpha renamed", "https://a.example/one"),
            entry("Beta", "https://b.example/two"),
        ], stations, at: t3)
        #expect(plan.changes.isEmpty)
        #expect(plan.summary.skippedExcluded == 1)
        #expect(plan.summary.added == 0)
    }

    @Test("A plain tombstone of the subscription comes back with its user fields")
    func plainTombstoneIsRevived() throws {
        let sub = subscription()
        let both = [entry("Alpha", "https://a.example/one"), entry("Beta", "https://b.example/two")]
        var stations = applying(try merge(sub, both, [], at: t1), to: [])
        let alphaID = stationID(sub, "https://a.example/one")
        stations[stations.firstIndex { $0.id == alphaID }!].folderName = "Morning"

        // 清单下架 Alpha：它没被整理过(文件夹不算)，变成保留订阅字段的普通墓碑。
        let removal = try merge(sub, [entry("Beta", "https://b.example/two")], stations, at: t2)
        #expect(removal.summary.removed == 1)
        stations = applying(removal, to: stations)
        let tombstone = try #require(find(alphaID, in: stations))
        #expect(tombstone.isDeleted)
        #expect(!tombstone.isSubscriptionExclusionMarker)
        #expect(tombstone.subscriptionID == sub.id)

        // Alpha 回到清单：同一个 id 复活，文件夹沿用墓碑上的值。
        let revival = try merge(sub, both, stations, at: t3)
        #expect(revival.summary.added == 1)
        #expect(revival.addedStationIDs == [alphaID])
        let revived = try #require(find(alphaID, in: revival.changes))
        #expect(!revived.isDeleted)
        #expect(revived.deletedAt == nil)
        #expect(revived.folderName == "Morning")
        #expect(revived.modifiedAt == t3)
    }

    @Test("A tombstone is not revived when the same stream now lives elsewhere in the library")
    func revivalAvoidsDuplicates() throws {
        let sub = subscription()
        var stations = applying(try merge(sub, [entry("Alpha", "https://a.example/one")], [], at: t1), to: [])
        let alphaID = stationID(sub, "https://a.example/one")
        stations[stations.firstIndex { $0.id == alphaID }!].isDeleted = true
        stations.append(RadioStation(id: "manual", name: "My Alpha", streamURL: "https://a.example/one/"))
        let plan = try merge(sub, [entry("Alpha", "https://a.example/one")], stations, at: t2)
        #expect(plan.changes.isEmpty)
        #expect(plan.summary.skippedAlreadyInLibrary == 1)
    }

    @Test("Entries already in the library as the user's own station are skipped")
    func skipsStationsAlreadyInLibrary() throws {
        let sub = subscription()
        let manual = RadioStation(id: "manual", name: "Mine", streamURL: "http://a.example/one/")
        let plan = try merge(sub, [entry("Alpha", "https://a.example/one")], [manual], at: t1)
        #expect(plan.changes.isEmpty)
        #expect(plan.summary.skippedAlreadyInLibrary == 1)
    }

    @Test("Entries held by another subscription, or excluded there, are skipped")
    func skipsOtherSubscriptions() throws {
        let sub = subscription()
        let other = subscription("https://elsewhere.example/list.pls")
        let otherLive = RadioStation(
            id: "radiosub.other.1",
            name: "Alpha",
            streamURL: "https://a.example/one",
            subscriptionID: other.id,
            subscriptionEntryKey: "a.example/one"
        )
        let otherExcluded = RadioStation(
            id: "radiosub.other.2",
            name: "Beta",
            streamURL: "https://b.example/two",
            isDeleted: true,
            subscriptionID: other.id,
            subscriptionEntryKey: "b.example/two",
            isSubscriptionExclusion: true
        )
        let plan = try merge(sub, [
            entry("Alpha", "https://a.example/one"),
            entry("Beta", "https://b.example/two"),
        ], [otherLive, otherExcluded], at: t1)
        #expect(plan.changes.isEmpty)
        #expect(plan.summary.skippedAlreadyInLibrary == 1)
        #expect(plan.summary.skippedExcluded == 1)
    }

    // MARK: - 换地址

    @Test("A station that changed its address keeps its id and the user's organization")
    func claimsMovedStation() throws {
        let sub = subscription()
        var stations = applying(try merge(sub, [
            entry("Jazz FM", "https://old.example/jazz"),
            entry("News", "https://news.example/live"),
        ], [], at: t1), to: [])
        let jazzID = stationID(sub, "https://old.example/jazz")
        stations[stations.firstIndex { $0.id == jazzID }!].tagNames = ["Favourite"]

        let plan = try merge(sub, [
            entry("jazz fm", "https://new.example/jazz.aac"),
            entry("News", "https://news.example/live"),
        ], stations, at: t2)
        #expect(plan.summary.updated == 1)
        #expect(plan.summary.added == 0)
        #expect(plan.summary.removed == 0)
        #expect(plan.summary.kept == 0)
        let moved = try #require(find(jazzID, in: plan.changes))
        #expect(moved.streamURL == "https://new.example/jazz.aac")
        #expect(moved.subscriptionEntryKey == "new.example/jazz.aac")
        #expect(moved.streamFormat == .aac)
        #expect(moved.name == "jazz fm")
        #expect(moved.tagNames == ["Favourite"])
    }

    @Test("An exclusion marker follows its station to the new address and keeps excluding it")
    func exclusionFollowsMove() throws {
        let sub = subscription()
        var stations = applying(try merge(sub, [
            entry("Jazz FM", "https://old.example/jazz"),
            entry("News", "https://news.example/live"),
        ], [], at: t1), to: [])
        let jazzID = stationID(sub, "https://old.example/jazz")
        let index = try #require(stations.firstIndex { $0.id == jazzID })
        stations[index] = RadioSubscriptionMergePolicy.excluding(stations[index], now: t1)

        let plan = try merge(sub, [
            entry("Jazz FM", "https://new.example/jazz"),
            entry("News", "https://news.example/live"),
        ], stations, at: t2)
        #expect(plan.summary.added == 0)
        #expect(plan.summary.skippedExcluded == 1)
        let marker = try #require(find(jazzID, in: plan.changes))
        #expect(marker.isSubscriptionExclusionMarker)
        #expect(marker.subscriptionEntryKey == "new.example/jazz")
        #expect(marker.streamURL == "https://new.example/jazz")

        // 之后的刷新继续挡住它。
        let later = try merge(sub, [
            entry("Jazz FM", "https://new.example/jazz"),
            entry("News", "https://news.example/live"),
        ], applying(plan, to: stations), at: t3)
        #expect(later.changes.isEmpty)
        #expect(later.summary.skippedExcluded == 1)
    }

    @Test("Ambiguous names are not guessed as moves")
    func ambiguousNamesAreNotClaimed() throws {
        let sub = subscription()
        let stations = applying(try merge(sub, [
            entry("Radio", "https://one.example/live"),
            entry("Keep", "https://keep.example/live"),
        ], [], at: t1), to: [])
        let plan = try merge(sub, [
            entry("Radio", "https://two.example/live"),
            entry("Radio", "https://three.example/live"),
            entry("Keep", "https://keep.example/live"),
        ], stations, at: t2)
        #expect(plan.summary.added == 2)
        #expect(plan.summary.removed == 1)
        #expect(plan.summary.updated == 0)
        let old = try #require(find(stationID(sub, "https://one.example/live"), in: plan.changes))
        #expect(old.isDeleted)
        #expect(old.streamURL == "https://one.example/live")
    }

    @Test("A deterministic id taken by a moved station falls back to the next deterministic id")
    func occupiedIDFallsBack() throws {
        let sub = subscription()
        var stations = applying(try merge(sub, [entry("Jazz", "https://a.example/one")], [], at: t1), to: [])
        // Jazz 换到新地址，保住了按旧地址算出来的 id。
        stations = applying(try merge(sub, [entry("Jazz", "https://b.example/two")], stations, at: t2), to: stations)
        let jazzID = stationID(sub, "https://a.example/one")
        #expect(find(jazzID, in: stations)?.subscriptionEntryKey == "b.example/two")

        // 旧地址又作为另一个台出现：确定性 id 已被 Jazz 占着，换下一个备选。
        let plan = try merge(sub, [
            entry("Jazz", "https://b.example/two"),
            entry("Classic", "https://a.example/one"),
        ], stations, at: t3)
        #expect(plan.summary.added == 1)
        let classic = try #require(plan.changes.first { $0.name == "Classic" })
        #expect(classic.id == stationID(sub, "https://a.example/one", attempt: 1))
        #expect(classic.subscriptionEntryKey == "a.example/one")
    }

    @Test("An id held by a non-subscription station counts as already in the library; a tombstone id is reused")
    func occupiedByForeignStation() throws {
        let sub = subscription()
        let id = stationID(sub, "https://a.example/one")
        // 旧版本编辑过，订阅字段丢了，地址也改了 —— 判重键对不上，但 id 被占着。
        let stripped = RadioStation(id: id, name: "Alpha", streamURL: "https://elsewhere.example/alpha")
        let plan = try merge(sub, [entry("Alpha", "https://a.example/one")], [stripped], at: t1)
        #expect(plan.changes.isEmpty)
        #expect(plan.summary.skippedAlreadyInLibrary == 1)

        // 同一个 id 上只剩一条墓碑(别的设备可能已经随 CloudKit 删除把它清掉了)：直接复用。
        var tombstone = stripped
        tombstone.isDeleted = true
        let reuse = try merge(sub, [entry("Alpha", "https://a.example/one")], [tombstone], at: t1)
        #expect(reuse.summary.added == 1)
        #expect(reuse.changes.first?.id == id)
        #expect(reuse.changes.first?.isDeleted == false)
    }

    // MARK: - 下架

    @Test("A delisted station becomes a tombstone that keeps its subscription fields")
    func delistedStationIsRemoved() throws {
        let sub = subscription()
        let stations = applying(try merge(sub, [
            entry("Alpha", "https://a.example/one"),
            entry("Beta", "https://b.example/two"),
            entry("Gamma", "https://c.example/three"),
        ], [], at: t1), to: [])
        let plan = try merge(sub, [
            entry("Alpha", "https://a.example/one"),
            entry("Beta", "https://b.example/two"),
        ], stations, at: t2)
        #expect(plan.summary.removed == 1)
        let gamma = try #require(find(stationID(sub, "https://c.example/three"), in: plan.changes))
        #expect(gamma.isDeleted)
        #expect(gamma.deletedAt == t2)
        #expect(gamma.isSubscriptionExclusion == nil)
        #expect(gamma.subscriptionEntryKey == "c.example/three")
    }

    @Test("A delisted station the user organized is detached instead of deleted")
    func organizedStationIsKept() throws {
        let sub = subscription()
        var stations = applying(try merge(sub, [
            entry("Tagged", "https://t.example/live"),
            entry("Logo", "https://l.example/live"),
            entry("Linked", "https://k.example/live"),
            entry("Stay", "https://s.example/live"),
        ], [], at: t1), to: [])
        stations[stations.firstIndex { $0.name == "Tagged" }!].tagNames = ["Mine"]
        stations[stations.firstIndex { $0.name == "Logo" }!].logoData = Data([9])
        stations[stations.firstIndex { $0.name == "Linked" }!].remoteLogoSource = .userProvidedURL
        stations[stations.firstIndex { $0.name == "Linked" }!].remoteLogoURL = "https://mine.example/k.png"

        let plan = try merge(sub, [entry("Stay", "https://s.example/live")], stations, at: t2)
        #expect(plan.summary.kept == 3)
        #expect(plan.summary.removed == 0)
        #expect(plan.summary.held == 0)
        for change in plan.changes {
            #expect(!change.isDeleted)
            #expect(change.subscriptionID == nil)
            #expect(change.subscriptionEntryKey == nil)
            #expect(!change.isSubscribed)
        }
    }

    @Test("Mass removals are held for confirmation, and removed once confirmed")
    func safetyValveHoldsMassRemovals() throws {
        let sub = subscription()
        let all = (0..<8).map { entry("Station \($0)", "https://s\($0).example/live") }
        let stations = applying(try merge(sub, all, [], at: t1), to: [])
        let survivors = Array(all.prefix(2))

        let held = try merge(sub, survivors, stations, at: t2)
        #expect(held.changes.isEmpty)
        #expect(held.summary.held == 6)
        #expect(held.summary.removed == 0)
        #expect(held.heldRemovalStationIDs.count == 6)
        #expect(held.heldRemovalStationIDs == held.heldRemovalStationIDs.sorted())

        let confirmed = try merge(sub, survivors, stations, confirms: true, at: t2)
        #expect(confirmed.summary.removed == 6)
        #expect(confirmed.heldRemovalStationIDs.isEmpty)
        let allRemoved = confirmed.changes.allSatisfy { $0.isDeleted }
        #expect(allRemoved)
    }

    @Test("Keeping held stations detaches them from the subscription with their ids")
    func releasingHeldStations() throws {
        let sub = subscription()
        let all = (0..<8).map { entry("Station \($0)", "https://s\($0).example/live") }
        let stations = applying(try merge(sub, all, [], at: t1), to: [])
        let held = try merge(sub, Array(all.prefix(2)), stations, at: t2).heldRemovalStationIDs
        let released = RadioSubscriptionMergePolicy.releasing(
            stationIDs: held + ["missing"],
            fromSubscription: sub.id,
            stations: stations,
            now: t3
        )
        #expect(released.count == 6)
        #expect(Set(released.map(\.id)) == Set(held))
        let allOwn = released.allSatisfy { !$0.isSubscribed && !$0.isDeleted && $0.modifiedAt == t3 }
        #expect(allOwn)

        // 之后清单恢复：这些台已经是用户自己的，同一个流按「已在库里」跳过。
        let recovered = try merge(sub, all, applying(RadioSubscriptionRefreshPlan(
            changes: released,
            heldRemovalStationIDs: [],
            addedStationIDs: [],
            summary: RadioSubscriptionRefreshSummary()
        ), to: stations), at: t3)
        #expect(recovered.summary.skippedAlreadyInLibrary == 6)
        #expect(recovered.summary.added == 0)
    }

    @Test("Small removals, or removals of at most half the stations, go through without confirmation")
    func safetyValveThresholds() throws {
        let sub = subscription()
        let all = (0..<12).map { entry("Station \($0)", "https://s\($0).example/live") }
        let stations = applying(try merge(sub, all, [], at: t1), to: [])
        // 5 个 ≤ 12 的一半
        let half = try merge(sub, Array(all.prefix(7)), stations, at: t2)
        #expect(half.summary.removed == 5)
        #expect(half.summary.held == 0)
        // 4 个不到下限，即使超过一半也照常移除
        let small = applying(try merge(sub, Array(all.prefix(6)), [], at: t1), to: [])
        let few = try merge(sub, Array(all.prefix(2)), small, at: t2)
        #expect(few.summary.removed == 4)
        #expect(few.summary.held == 0)
    }

    @Test("A truncated list processes the first 1000 entries and removes nothing")
    func truncatedListRemovesNothing() throws {
        let sub = subscription()
        let stations = applying(try merge(sub, [entry("Old", "https://old.example/live")], [], at: t1), to: [])
        let huge = (0..<1_001).map { entry("S\($0)", "https://h.example/\($0)") }
        let plan = try merge(sub, huge, stations, at: t2)
        #expect(plan.summary.truncated)
        #expect(plan.summary.totalEntries == 1_001)
        #expect(plan.summary.added == RadioSubscriptionMergePolicy.maximumEntries)
        #expect(plan.summary.removed == 0)
        let noneRemoved = plan.changes.allSatisfy { !$0.isDeleted }
        #expect(noneRemoved)
        #expect(find(stationID(sub, "https://old.example/live"), in: plan.changes) == nil)
    }

    @Test("A list without a single usable entry fails and changes nothing")
    func emptyListFails() {
        let sub = subscription()
        #expect(throws: RadioSubscriptionMergeError.emptyList) {
            try RadioSubscriptionMergePolicy.merge(
                subscription: sub,
                candidates: [self.entry("Broken", "gopher://x", status: .invalid)],
                stations: [],
                now: self.t1
            )
        }
        #expect(throws: RadioSubscriptionMergeError.emptyList) {
            try RadioSubscriptionMergePolicy.merge(subscription: sub, candidates: [], stations: [], now: self.t1)
        }
    }

    // MARK: - 首次订阅 / 取消订阅 / 转为自己的

    @Test("Unchecked entries on first subscribe become exclusion markers")
    func firstSubscribeExclusions() throws {
        let sub = subscription()
        let candidates = [entry("Alpha", "https://a.example/one"), entry("Beta", "https://b.example/two")]
        let plan = try merge(sub, candidates, [], excluded: [key("https://b.example/two")], at: t1)
        #expect(plan.summary.added == 1)
        #expect(plan.summary.skippedExcluded == 1)
        #expect(plan.addedStationIDs == [stationID(sub, "https://a.example/one")])
        let marker = try #require(find(stationID(sub, "https://b.example/two"), in: plan.changes))
        #expect(marker.isSubscriptionExclusionMarker)
        #expect(marker.subscriptionID == sub.id)
        #expect(marker.name == "Beta")
        #expect(marker.streamURL == "https://b.example/two")

        // 标记能被编码再解码(CloudKit 记录就是这样走的)。
        let roundTrip = try JSONDecoder().decode(RadioStation.self, from: JSONEncoder().encode(marker))
        #expect(roundTrip == marker)

        let later = try merge(sub, candidates, applying(plan, to: []), at: t2)
        #expect(later.changes.isEmpty)
        #expect(later.summary.skippedExcluded == 1)
    }

    @Test("Unsubscribing either keeps stations as the user's own or removes them")
    func unsubscribing() throws {
        let sub = subscription()
        var stations = applying(try merge(sub, [
            entry("Alpha", "https://a.example/one"),
            entry("Beta", "https://b.example/two"),
        ], [], excluded: [key("https://b.example/two")], at: t1), to: [])
        let oldTombstone = RadioStation(
            id: "radiosub.gone",
            name: "Gone",
            streamURL: "https://gone.example/live",
            isDeleted: true,
            subscriptionID: sub.id,
            subscriptionEntryKey: "gone.example/live"
        )
        let manual = RadioStation(id: "manual", name: "Mine", streamURL: "https://mine.example/live")
        stations += [oldTombstone, manual]
        let alphaID = stationID(sub, "https://a.example/one")
        let betaID = stationID(sub, "https://b.example/two")

        let kept = RadioSubscriptionMergePolicy.unsubscribing(
            subscriptionID: sub.id,
            keepStations: true,
            stations: stations,
            now: t2
        )
        #expect(kept.count == 2)
        let ownAlpha = try #require(find(alphaID, in: kept))
        #expect(!ownAlpha.isDeleted)
        #expect(ownAlpha.subscriptionID == nil)
        #expect(ownAlpha.subscriptionEntryKey == nil)
        let plainBeta = try #require(find(betaID, in: kept))
        #expect(plainBeta.isDeleted)
        #expect(plainBeta.isSubscriptionExclusion == nil)
        #expect(!plainBeta.isSubscriptionExclusionMarker)

        let removed = RadioSubscriptionMergePolicy.unsubscribing(
            subscriptionID: sub.id,
            keepStations: false,
            stations: stations,
            now: t2
        )
        #expect(removed.count == 2)
        let allPlainTombstones = removed.allSatisfy { $0.isDeleted && !$0.isSubscriptionExclusionMarker }
        #expect(allPlainTombstones)
        #expect(find(alphaID, in: removed)?.subscriptionID == sub.id)
        #expect(find("manual", in: removed) == nil)
        #expect(find("radiosub.gone", in: removed) == nil)
    }

    @Test("Converting to an own station excludes the list entry and copies the user's station")
    func detachingToOwnStation() throws {
        let sub = subscription()
        var stations = applying(try merge(sub, [
            entry("Alpha", "https://a.example/one.flac", logo: "https://a.example/logo.png", homepage: "https://a.example"),
        ], [], at: t1), to: [])
        let alphaID = stationID(sub, "https://a.example/one.flac")
        let index = try #require(stations.firstIndex { $0.id == alphaID })
        stations[index].folderName = "Evening"
        stations[index].tagNames = ["Jazz"]
        stations[index].sortOrder = 3
        stations[index].lastPlayedAt = t1
        stations[index].logoData = Data([7])

        let result = RadioSubscriptionMergePolicy.detaching(stations[index], newID: "own-1", now: t2)
        #expect(result.exclusion.id == alphaID)
        #expect(result.exclusion.isSubscriptionExclusionMarker)
        let own = result.own
        #expect(own.id == "own-1")
        #expect(!own.isSubscribed)
        #expect(own.subscriptionID == nil)
        #expect(own.name == "Alpha")
        #expect(own.streamURL == "https://a.example/one.flac")
        #expect(own.streamFormat == .flac)
        #expect(own.remoteLogoURL == "https://a.example/logo.png")
        #expect(own.homepageURL == "https://a.example")
        #expect(own.folderName == "Evening")
        #expect(own.tagNames == ["Jazz"])
        #expect(own.sortOrder == 3)
        #expect(own.lastPlayedAt == t1)
        #expect(own.logoData == Data([7]))

        // 之后的刷新：清单那一条被挡住，也不会因为「同一个流已在库里」以外的原因再建一个。
        stations[index] = result.exclusion
        stations.append(own)
        let later = try merge(sub, [entry("Alpha", "https://a.example/one.flac")], stations, at: t3)
        #expect(later.changes.isEmpty)
        #expect(later.summary.skippedExcluded == 1)
    }

    // MARK: - 字段归属

    @Test("Editing a subscribed station only accepts user-owned fields")
    func editsOnlyTouchUserFields() throws {
        let sub = subscription()
        let original = try #require(try merge(sub, [
            entry("Alpha", "https://a.example/one", logo: "https://list.example/a.png"),
        ], [], at: t1).changes.first)

        // 编辑器整条重建电台：订阅字段丢了，名称地址也被改了。
        let edited = RadioStation(
            id: original.id,
            name: "Hacked",
            streamURL: "https://evil.example/stream",
            logoData: Data([5]),
            logoFileName: "cover.jpg",
            streamFormat: .flac,
            bitRate: 64_000,
            createdAt: original.createdAt,
            modifiedAt: t2,
            sortOrder: 11,
            homepageURL: "https://evil.example",
            remoteLogoURL: "https://list.example/a.png",
            remoteLogoSource: .importedManifest,
            folderName: "Mine",
            tagNames: ["Tag"]
        )
        let result = RadioSubscriptionFieldOwnership.applyingUserEdits(edited, to: original)
        #expect(result.name == "Alpha")
        #expect(result.streamURL == "https://a.example/one")
        #expect(result.streamFormat == original.streamFormat)
        #expect(result.homepageURL == original.homepageURL)
        #expect(result.subscriptionID == sub.id)
        #expect(result.subscriptionEntryKey == original.subscriptionEntryKey)
        #expect(result.logoData == Data([5]))
        #expect(result.logoFileName == "cover.jpg")
        #expect(result.folderName == "Mine")
        #expect(result.tagNames == ["Tag"])
        #expect(result.sortOrder == 11)
        #expect(result.bitRate == 64_000)
        #expect(result.modifiedAt == t2)
        #expect(result.remoteLogoURL == "https://list.example/a.png")
        #expect(result.remoteLogoSource == .importedManifest)

        // 用户自己填的台标链接归用户。
        var ownLink = edited
        ownLink.remoteLogoURL = "https://mine.example/a.png"
        ownLink.remoteLogoSource = .userProvidedURL
        let linked = RadioSubscriptionFieldOwnership.applyingUserEdits(ownLink, to: original)
        #expect(linked.remoteLogoURL == "https://mine.example/a.png")
        #expect(linked.remoteLogoSource == .userProvidedURL)

        // 清掉清单给的链接不算数，清掉自己填的算数。
        var cleared = edited
        cleared.remoteLogoURL = nil
        cleared.remoteLogoSource = nil
        #expect(RadioSubscriptionFieldOwnership.applyingUserEdits(cleared, to: original).remoteLogoURL
            == "https://list.example/a.png")
        let clearedOwn = RadioSubscriptionFieldOwnership.applyingUserEdits(cleared, to: linked)
        #expect(clearedOwn.remoteLogoURL == nil)
        #expect(clearedOwn.remoteLogoSource == nil)
    }

    // MARK: - 刷新时机

    @Test("Auto refresh runs at most daily and never when disabled")
    func scheduleDailyInterval() {
        var sub = subscription()
        let local = RadioSubscriptionRefreshStatus(firstSeenAt: t0, createdLocally: true)
        #expect(RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: local, now: t0))

        sub.lastRefreshedAt = t0
        #expect(!RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: local, now: t0.addingTimeInterval(2 * 3_600)))
        #expect(RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: local, now: t0.addingTimeInterval(25 * 3_600)))

        // 本机最近一次成功比同步来的更新
        var recent = local
        recent.lastSuccessAt = t0.addingTimeInterval(20 * 3_600)
        #expect(!RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: recent, now: t0.addingTimeInterval(25 * 3_600)))

        sub.autoUpdates = false
        #expect(!RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: local, now: t0.addingTimeInterval(48 * 3_600)))
    }

    @Test("Failures back off from one hour, doubling up to a day")
    func scheduleBackoff() {
        #expect(RadioSubscriptionRefreshSchedule.retryDelay(afterFailures: 0) == 0)
        #expect(RadioSubscriptionRefreshSchedule.retryDelay(afterFailures: 1) == 3_600)
        #expect(RadioSubscriptionRefreshSchedule.retryDelay(afterFailures: 2) == 7_200)
        #expect(RadioSubscriptionRefreshSchedule.retryDelay(afterFailures: 3) == 14_400)
        #expect(RadioSubscriptionRefreshSchedule.retryDelay(afterFailures: 10) == 86_400)
        #expect(RadioSubscriptionRefreshSchedule.retryDelay(afterFailures: 1_000) == 86_400)

        let sub = subscription()
        var status = RadioSubscriptionRefreshStatus(firstSeenAt: t0, createdLocally: true)
        status.consecutiveFailures = 1
        status.lastAttemptAt = t0
        #expect(!RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: status, now: t0.addingTimeInterval(1_800)))
        #expect(RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: status, now: t0.addingTimeInterval(3_700)))
        status.consecutiveFailures = 3
        #expect(!RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: status, now: t0.addingTimeInterval(3 * 3_600)))
        #expect(RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: status, now: t0.addingTimeInterval(4 * 3_600 + 1)))
    }

    @Test("A subscription synced from another device waits before its first automatic refresh")
    func scheduleSyncedGrace() {
        let sub = subscription()
        let synced = RadioSubscriptionRefreshStatus(firstSeenAt: t0, createdLocally: false)
        #expect(!RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: synced, now: t0.addingTimeInterval(10 * 60)))
        #expect(RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: synced, now: t0.addingTimeInterval(31 * 60)))
        let local = RadioSubscriptionRefreshStatus(firstSeenAt: t0, createdLocally: true)
        #expect(RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: local, now: t0.addingTimeInterval(60)))
    }

    @Test("A refresh time far in the future does not block refreshing forever")
    func scheduleClockSkew() {
        var sub = subscription()
        let local = RadioSubscriptionRefreshStatus(firstSeenAt: t0, createdLocally: true)
        sub.lastRefreshedAt = t0.addingTimeInterval(3 * 3_600)
        #expect(RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: local, now: t0))
        sub.lastRefreshedAt = t0.addingTimeInterval(10 * 60)
        #expect(!RadioSubscriptionRefreshSchedule.isDue(subscription: sub, status: local, now: t0))
    }

    // MARK: - 兼容

    @Test("Stations saved before subscriptions existed still decode, and nil fields stay out of the JSON")
    func legacyJSONDecodes() throws {
        let json = """
        {"id":"legacy","name":"Old","streamURL":"https://old.example/live","streamFormat":"mp3",
         "createdAt":1800000000,"modifiedAt":1800000000,"isDeleted":false}
        """
        let station = try JSONDecoder().decode(RadioStation.self, from: Data(json.utf8))
        #expect(station.subscriptionID == nil)
        #expect(station.subscriptionEntryKey == nil)
        #expect(station.isSubscriptionExclusion == nil)
        #expect(!station.isSubscribed)
        #expect(!station.isSubscriptionExclusionMarker)

        let encoded = String(decoding: try JSONEncoder().encode(station), as: UTF8.self)
        #expect(!encoded.contains("subscription"))

        let subscribed = RadioStation(
            name: "New",
            streamURL: "https://new.example/live",
            subscriptionID: "radiosub.x",
            subscriptionEntryKey: "new.example/live"
        )
        let decoded = try JSONDecoder().decode(RadioStation.self, from: JSONEncoder().encode(subscribed))
        #expect(decoded == subscribed)
        #expect(decoded.isSubscribed)
    }

    @Test("Subscription definitions round-trip through JSON")
    func subscriptionCodable() throws {
        var sub = subscription(groupsAsFolders: true)
        sub.lastRefreshedAt = t1
        let decoded = try JSONDecoder().decode(RadioSubscription.self, from: JSONEncoder().encode(sub))
        #expect(decoded == sub)
        #expect(decoded.autoUpdates)
    }
}
