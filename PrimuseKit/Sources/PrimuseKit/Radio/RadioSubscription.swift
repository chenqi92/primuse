import Foundation

// MARK: - 订阅定义

/// 一份电台清单订阅：用户填的 m3u / m3u8 / pls / txt 地址，清单更新时自动同步。
///
/// 定义本身很小，跟着设置走 iCloud 键值存储；清单里的电台照常是普通的
/// `RadioStation` 记录，靠 `subscriptionID` / `subscriptionEntryKey` 认领。
///
/// ## 字段归属(整个功能的核心不变量)
///
/// 订阅电台的每个字段只有一个主人，刷新和编辑都按这张表来：
///
/// - **清单拥有**，每次刷新以清单为准：名称、流地址、格式(由地址推断)、
///   主页(清单给了才覆盖，没给保留现值)、远程台标(清单给了、且现有台标不是用户
///   自己指定的才覆盖，来源记 `.importedManifest`；清单没给就保留 —— 自动发现
///   找来的台标留着)。
/// - **用户拥有**，刷新永远不动：手选台标(`logoData` / `logoFileName`)、
///   用户自己填的台标链接、文件夹(只在「新建」时按 `usesListGroupsAsFolders`
///   取清单分组，之后归用户)、标签、排序(新建时排到末尾)、最近收听、创建时间、码率。
///
/// 编辑订阅电台时只接受用户拥有的字段(`RadioSubscriptionFieldOwnership`)；
/// 刷新只写清单拥有的字段(`RadioSubscriptionMergePolicy`)。两边各管一半，
/// 多台设备、一边刷新一边编辑，谁也不会把谁的改动冲掉。
public struct RadioSubscription: Codable, Identifiable, Hashable, Sendable {
    /// 由清单地址确定性导出(见 `RadioSubscriptionIdentity`)，
    /// 两台设备各自订阅同一个地址会得到同一个 id。
    public var id: String
    /// 默认取清单地址的文件名或 host，用户可以改。
    public var name: String
    /// 归一化后的 http(s) 地址。
    public var listURL: String
    public var autoUpdates: Bool
    /// 只影响「新加入」的电台 —— 已有电台的文件夹归用户。
    public var usesListGroupsAsFolders: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    /// 任意一台设备最近一次成功刷新的时间。跨设备同步，免得每台设备都去刷一遍。
    public var lastRefreshedAt: Date?

    public init(
        id: String,
        name: String,
        listURL: String,
        autoUpdates: Bool = true,
        usesListGroupsAsFolders: Bool = false,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.listURL = listURL
        self.autoUpdates = autoUpdates
        self.usesListGroupsAsFolders = usesListGroupsAsFolders
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastRefreshedAt = lastRefreshedAt
    }

    /// 按清单地址造一份新订阅。地址不是合法的 http(s) 时返回 nil。
    public static func make(
        listURL rawListURL: String,
        name rawName: String? = nil,
        usesListGroupsAsFolders: Bool = false,
        now: Date = Date()
    ) -> RadioSubscription? {
        guard let listURL = RadioStationValidation.normalizedURLString(rawListURL),
              let id = RadioSubscriptionIdentity.subscriptionID(listURL: listURL) else {
            return nil
        }
        let name = rawName.map(RadioStationValidation.normalizedName)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? RadioSubscriptionIdentity.defaultName(listURL: listURL)
        return RadioSubscription(
            id: id,
            name: name,
            listURL: listURL,
            usesListGroupsAsFolders: usesListGroupsAsFolders,
            createdAt: now,
            modifiedAt: now
        )
    }

    /// 界面上显示的来源，只到 host —— 清单地址的查询串里可能带 token。
    public var displayHost: String {
        URL(string: listURL)?.host ?? listURL
    }
}

// MARK: - 身份

public enum RadioSubscriptionIdentity {
    /// 订阅 id 和订阅电台 id 的前缀。不能与服务器镜像的
    /// `ServerRadioStationIdentity.stationIDPrefix`(`primuse.system.serverRadio.`)相交。
    public static let idPrefix = "radiosub."

    /// 清单地址的判重键，规则与电台流地址相同：不分 http/https、去掉末尾斜杠。
    public static func listKey(for listURL: String) -> String? {
        guard let normalized = RadioStationValidation.normalizedURLString(listURL) else {
            return nil
        }
        return RadioImportParser.streamIdentityKey(normalized)
    }

    public static func subscriptionID(listURL: String) -> String? {
        guard let key = listKey(for: listURL) else { return nil }
        return idPrefix + StableFNV1a64.hexDigest(key)
    }

    /// 订阅电台的确定性 id。两台设备在同样的状态下按同一份清单建出来的电台
    /// id 相同，CloudKit 里自然合成一条记录，不会一台一份。
    ///
    /// `attempt` 是被占用时的备选：第 N 次改哈希 `entryKey#N`，
    /// 同样的状态永远得到同样的备选。
    public static func stationID(subscriptionID: String, entryKey: String, attempt: Int = 0) -> String {
        let material = attempt == 0 ? entryKey : "\(entryKey)#\(attempt)"
        return "\(subscriptionID).\(StableFNV1a64.hexDigest(material))"
    }

    /// 默认名字：清单文件名(去掉扩展名)，取不到就用 host。
    public static func defaultName(listURL: String) -> String {
        guard let url = URL(string: listURL) else { return listURL }
        let lastComponent = url.pathComponents.last { !$0.isEmpty && $0 != "/" }
        if let lastComponent {
            let stem = (lastComponent as NSString).deletingPathExtension
                .trimmingCharacters(in: .whitespaces)
            if stem.count >= 2, stem.rangeOfCharacter(from: .alphanumerics) != nil {
                return stem
            }
        }
        return url.host ?? listURL
    }
}

// MARK: - 字段归属

public enum RadioSubscriptionFieldOwnership {
    /// 订阅电台被编辑时只接受用户拥有的字段，清单拥有的一律沿用 `original`。
    ///
    /// 编辑器里名称和地址本来就是只读的，这里是兜底 —— 任何一条编辑路径
    /// (包括整条重建电台再 upsert 的编辑器)都不能改掉清单拥有的字段，
    /// 更不能把订阅字段丢掉。
    ///
    /// 远程台标链接只在「用户自己指定」时归用户：用户填了一个新链接，或者清掉
    /// 自己以前填的链接，都接受；清单或自动发现给的链接不因编辑而改变。
    public static func applyingUserEdits(
        _ edited: RadioStation,
        to original: RadioStation
    ) -> RadioStation {
        var result = original
        result.logoData = edited.logoData
        result.logoFileName = edited.logoFileName
        result.folderName = edited.folderName
        result.tagNames = edited.tagNames
        result.sortOrder = edited.sortOrder
        result.lastPlayedAt = edited.lastPlayedAt
        result.createdAt = edited.createdAt
        result.bitRate = edited.bitRate

        let editedIsUserLogo = edited.remoteLogoURL != nil
            && edited.remoteLogoSource?.isUserProvided == true
        let clearsUserLogo = edited.remoteLogoURL == nil
            && original.remoteLogoSource?.isUserProvided == true
        if editedIsUserLogo || clearsUserLogo {
            result.remoteLogoURL = edited.remoteLogoURL
            result.remoteLogoSource = edited.remoteLogoURL == nil ? nil : edited.remoteLogoSource
        }
        result.modifiedAt = edited.modifiedAt
        return result
    }

    /// 用户整理过的订阅电台：清单把它下架时脱离订阅保留下来，而不是删掉。
    public static func isUserOrganized(_ station: RadioStation) -> Bool {
        !station.assignedTagNames.isEmpty
            || station.logoData?.isEmpty == false
            || station.remoteLogoSource?.isUserProvided == true
    }
}

// MARK: - 刷新结果

public struct RadioSubscriptionRefreshSummary: Codable, Hashable, Sendable {
    /// 新加进来的(含复活的墓碑)。
    public var added: Int
    /// 清单字段有变化的(含换地址认领)。
    public var updated: Int
    /// 清单下架、按墓碑移除的。
    public var removed: Int
    /// 清单下架、但用户整理过所以脱离订阅留下的。
    public var kept: Int
    public var unchanged: Int
    /// 被排除标记挡住的条目。
    public var skippedExcluded: Int
    /// 库里已经有同一个流(不属于这份订阅)的条目。
    public var skippedAlreadyInLibrary: Int
    public var invalid: Int
    /// 因为安全阀暂时没有移除、等用户确认的电台数。
    public var held: Int
    /// 清单超过上限，只处理了前 `maximumEntries` 条。
    public var truncated: Bool
    /// 清单里唯一有效条目的总数(截断前)。
    public var totalEntries: Int

    public init(
        added: Int = 0,
        updated: Int = 0,
        removed: Int = 0,
        kept: Int = 0,
        unchanged: Int = 0,
        skippedExcluded: Int = 0,
        skippedAlreadyInLibrary: Int = 0,
        invalid: Int = 0,
        held: Int = 0,
        truncated: Bool = false,
        totalEntries: Int = 0
    ) {
        self.added = added
        self.updated = updated
        self.removed = removed
        self.kept = kept
        self.unchanged = unchanged
        self.skippedExcluded = skippedExcluded
        self.skippedAlreadyInLibrary = skippedAlreadyInLibrary
        self.invalid = invalid
        self.held = held
        self.truncated = truncated
        self.totalEntries = totalEntries
    }

    public var hasChanges: Bool { added + updated + removed + kept > 0 }
}

public struct RadioSubscriptionRefreshPlan: Hashable, Sendable {
    /// 每个有变化的电台的最终值(含新墓碑、排除标记和脱离订阅的)。
    /// 没有变化的电台不在这里 —— 不写就不会去刷 `modifiedAt`，多台设备
    /// 也就不会拿同一份清单互相覆盖。
    public var changes: [RadioStation]
    /// 安全阀扣下、等用户确认的电台。
    public var heldRemovalStationIDs: [String]
    /// 这一轮新建或复活的活电台，调用方拿去排台标发现。
    public var addedStationIDs: [String]
    public var summary: RadioSubscriptionRefreshSummary

    public init(
        changes: [RadioStation],
        heldRemovalStationIDs: [String],
        addedStationIDs: [String],
        summary: RadioSubscriptionRefreshSummary
    ) {
        self.changes = changes
        self.heldRemovalStationIDs = heldRemovalStationIDs
        self.addedStationIDs = addedStationIDs
        self.summary = summary
    }
}

public enum RadioSubscriptionMergeError: Error, Equatable, Sendable {
    /// 清单里一个有效条目都没有。多半是清单地址临时返回了错误页，
    /// 按失败处理，什么都不改。
    case emptyList
}

// MARK: - 合并策略

/// 把一份清单合并进电台库。纯函数：输入清单候选和全部电台(含墓碑)，
/// 输出要写回的电台，不碰 store 也不做 I/O。
public enum RadioSubscriptionMergePolicy {
    /// 一份订阅最多同步这么多条。超过的只处理前面这些，并且这一轮不做任何移除 ——
    /// 没看到的不等于被删了。
    public static let maximumEntries = 1_000

    /// 安全阀：一次要移除的电台至少这么多、且超过这份订阅现有电台的一半时，
    /// 先扣下来等用户确认。
    public static let heldRemovalMinimumCount = 5

    private struct Entry {
        let key: String
        let name: String
        let url: String
        let logoURL: String?
        let homepageURL: String?
        let groupTitle: String?
    }

    private enum IDResolution {
        case available(String)
        case alreadyInLibrary
    }

    /// 合并一份清单。
    ///
    /// - Parameters:
    ///   - candidates: 清单解析结果。候选自带的「重复」状态被忽略、在这里重新判；
    ///     只丢掉 `.invalid`。
    ///   - stations: 全部电台，含墓碑与排除标记。
    ///   - newlyExcludedEntryKeys: 只在首次订阅时用 —— 用户没勾的可用条目，
    ///     为它们各建一个排除标记。
    ///   - confirmsHeldRemovals: 用户确认过要移除安全阀扣下的电台。
    /// - Throws: `RadioSubscriptionMergeError.emptyList`，此时什么都不改。
    public static func merge(
        subscription: RadioSubscription,
        candidates: [RadioImportCandidate],
        stations: [RadioStation],
        newlyExcludedEntryKeys: Set<String> = [],
        confirmsHeldRemovals: Bool = false,
        now: Date = Date()
    ) throws -> RadioSubscriptionRefreshPlan {
        var summary = RadioSubscriptionRefreshSummary()

        // 规则 1：同一判重键只取第一条，一条有效的都没有就算失败。
        var entries: [Entry] = []
        var listKeys = Set<String>()
        for candidate in candidates {
            guard candidate.status != .invalid,
                  let url = RadioStationValidation.normalizedURLString(candidate.urlString),
                  let key = RadioImportParser.streamIdentityKey(url) else {
                summary.invalid += 1
                continue
            }
            guard listKeys.insert(key).inserted else { continue }
            let name = RadioStationValidation.normalizedName(candidate.name)
            entries.append(Entry(
                key: key,
                name: name.isEmpty ? RadioImportParser.suggestedName(for: url) : name,
                url: url,
                logoURL: RadioLogoURLPolicy.normalized(candidate.logoURLString),
                homepageURL: RadioLogoURLPolicy.normalized(candidate.homepageURLString),
                groupTitle: RadioStationOrganization.normalizedFolderName(candidate.groupTitle)
            ))
        }
        summary.totalEntries = entries.count
        guard !entries.isEmpty else { throw RadioSubscriptionMergeError.emptyList }

        // 规则 2：超过上限只处理前面的，并且这一轮不移除。孤儿按**完整**清单判定，
        // 截断掉的尾巴里的电台不会被误认成下架。
        summary.truncated = entries.count > maximumEntries
        let processed = Array(entries.prefix(maximumEntries))

        let subscriptionID = subscription.id
        var working: [String: RadioStation] = [:]
        for station in stations where working[station.id] == nil {
            working[station.id] = station
        }
        // 变化按第一次发生的顺序输出，同一个电台改两次只出现一次(取最终值)。
        var changedIDs: [String] = []
        var changedIDSet = Set<String>()
        func record(_ station: RadioStation) {
            if changedIDSet.insert(station.id).inserted {
                changedIDs.append(station.id)
            }
            working[station.id] = station
        }

        // 本订阅的电台(活的、排除标记、普通墓碑)，按判重键索引。
        // 同一个键有多条时，排除标记优先(用户的意愿)，其次活的，最后墓碑。
        let own = stations.filter { belongs($0, to: subscriptionID) }
        var ownByKey: [String: RadioStation] = [:]
        for station in own {
            guard let key = station.subscriptionEntryKey else { continue }
            if let existing = ownByKey[key], rank(existing) <= rank(station) { continue }
            ownByKey[key] = station
        }
        let liveOwnCount = own.filter { !$0.isDeleted }.count

        // 不属于本订阅的电台：活的算「已在库里」，任何订阅的排除标记算「已排除」。
        var foreignLiveKeys = Set<String>()
        var foreignExcludedKeys = Set<String>()
        for station in stations where !belongs(station, to: subscriptionID) {
            if station.isSubscriptionExclusionMarker {
                if let key = station.subscriptionEntryKey
                    ?? RadioImportParser.streamIdentityKey(station.streamURL) {
                    foreignExcludedKeys.insert(key)
                }
            } else if !station.isDeleted,
                      let key = RadioImportParser.streamIdentityKey(station.streamURL) {
                foreignLiveKeys.insert(key)
            }
        }

        var addedIDs: [String] = []
        var unmatched: [Entry] = []

        // 规则 3：按 (subscriptionID, entryKey) 匹配。
        for entry in processed {
            guard let station = ownByKey[entry.key] else {
                unmatched.append(entry)
                continue
            }
            if station.isSubscriptionExclusionMarker {
                summary.skippedExcluded += 1
                continue
            }
            if station.isDeleted {
                // 普通墓碑：以前被刷新移除，或取消订阅时一并移除的。复活前同样要
                // 避开别处已有的同一个流，否则会多出一个重复电台。
                if foreignExcludedKeys.contains(entry.key) {
                    summary.skippedExcluded += 1
                    continue
                }
                if foreignLiveKeys.contains(entry.key) {
                    summary.skippedAlreadyInLibrary += 1
                    continue
                }
                if newlyExcludedEntryKeys.contains(entry.key) {
                    var marker = station
                    marker.isSubscriptionExclusion = true
                    marker.deletedAt = station.deletedAt ?? now
                    marker.modifiedAt = now
                    record(marker)
                    summary.skippedExcluded += 1
                    continue
                }
                var revived = applyingListFields(entry, to: station, subscriptionID: subscriptionID)
                revived.isDeleted = false
                revived.deletedAt = nil
                revived.isSubscriptionExclusion = nil
                revived.modifiedAt = now
                record(revived)
                addedIDs.append(revived.id)
                summary.added += 1
                continue
            }
            let updated = applyingListFields(entry, to: station, subscriptionID: subscriptionID)
            if listFieldsMatch(updated, station) {
                summary.unchanged += 1
            } else {
                var stamped = updated
                stamped.modifiedAt = now
                record(stamped)
                summary.updated += 1
            }
        }

        // 规则 5：换地址。清单里已经没有的本订阅电台(活的或排除标记)是「孤儿」，
        // 没匹配到的条目是「新条目」；同一个名字两边都恰好一个，就认定是同一个
        // 电台换了地址，保住 id 和用户的整理。其余情况一概不猜。
        var orphans = own.filter { station in
            guard let key = station.subscriptionEntryKey else { return false }
            return !listKeys.contains(key)
                && (!station.isDeleted || station.isSubscriptionExclusionMarker)
        }
        let claimable = unmatched.filter {
            !foreignLiveKeys.contains($0.key) && !foreignExcludedKeys.contains($0.key)
        }
        let orphansByName = Dictionary(grouping: orphans) { nameKey($0.name) }
        let entriesByName = Dictionary(grouping: claimable) { nameKey($0.name) }
        var claimedEntryKeys = Set<String>()
        var claimedOrphanIDs = Set<String>()
        // 按清单顺序认领，结果与字典遍历顺序无关。
        for entry in claimable {
            let name = nameKey(entry.name)
            guard let orphanGroup = orphansByName[name], orphanGroup.count == 1,
                  let entryGroup = entriesByName[name], entryGroup.count == 1,
                  let orphan = orphanGroup.first else { continue }
            if orphan.isSubscriptionExclusionMarker {
                // 排除标记跟着换 key，继续挡住这一条。
                var marker = orphan
                marker.name = entry.name
                marker.streamURL = entry.url
                marker.streamFormat = inferredFormat(entry.url)
                marker.subscriptionEntryKey = entry.key
                marker.modifiedAt = now
                record(marker)
                summary.skippedExcluded += 1
            } else {
                var moved = applyingListFields(entry, to: orphan, subscriptionID: subscriptionID)
                moved.modifiedAt = now
                record(moved)
                summary.updated += 1
            }
            claimedEntryKeys.insert(entry.key)
            claimedOrphanIDs.insert(orphan.id)
        }
        orphans.removeAll { claimedOrphanIDs.contains($0.id) }
        unmatched.removeAll { claimedEntryKeys.contains($0.key) }

        // 规则 4 / 7：剩下的新条目逐个新建；首次订阅时用户没勾的建排除标记。
        var nextSortOrder: Int? = stations.contains(where: { !$0.isDeleted && $0.sortOrder != nil })
            ? (stations.compactMap(\.sortOrder).max() ?? -1) + 1
            : nil
        for entry in unmatched {
            if foreignExcludedKeys.contains(entry.key) {
                summary.skippedExcluded += 1
                continue
            }
            if foreignLiveKeys.contains(entry.key) {
                summary.skippedAlreadyInLibrary += 1
                continue
            }
            guard case .available(let id) = resolveStationID(
                subscriptionID: subscriptionID,
                entryKey: entry.key,
                in: working
            ) else {
                summary.skippedAlreadyInLibrary += 1
                continue
            }
            if newlyExcludedEntryKeys.contains(entry.key) {
                record(RadioStation(
                    id: id,
                    name: entry.name,
                    streamURL: entry.url,
                    streamFormat: inferredFormat(entry.url),
                    createdAt: now,
                    modifiedAt: now,
                    isDeleted: true,
                    deletedAt: now,
                    subscriptionID: subscriptionID,
                    subscriptionEntryKey: entry.key,
                    isSubscriptionExclusion: true
                ))
                summary.skippedExcluded += 1
                continue
            }
            record(RadioStation(
                id: id,
                name: entry.name,
                streamURL: entry.url,
                streamFormat: inferredFormat(entry.url),
                createdAt: now,
                modifiedAt: now,
                sortOrder: nextSortOrder,
                homepageURL: entry.homepageURL,
                remoteLogoURL: entry.logoURL,
                remoteLogoSource: entry.logoURL == nil ? nil : .importedManifest,
                folderName: subscription.usesListGroupsAsFolders ? entry.groupTitle : nil,
                subscriptionID: subscriptionID,
                subscriptionEntryKey: entry.key
            ))
            if let order = nextSortOrder { nextSortOrder = order + 1 }
            addedIDs.append(id)
            summary.added += 1
        }

        // 规则 6：清单下架的活电台。孤儿里的排除标记原样留着 —— 无害，
        // 也防止那一条哪天回到清单时被复活。
        var held: [String] = []
        if !summary.truncated {
            let delisted = orphans.filter { !$0.isDeleted }
            let exceedsSafetyValve = delisted.count >= heldRemovalMinimumCount
                && delisted.count * 2 > liveOwnCount
            if exceedsSafetyValve && !confirmsHeldRemovals {
                held = delisted.map(\.id).sorted()
                summary.held = held.count
            } else {
                for station in delisted {
                    var next = station
                    if RadioSubscriptionFieldOwnership.isUserOrganized(station) {
                        // 用户整理过：脱离订阅，变成用户自己的电台。
                        next.subscriptionID = nil
                        next.subscriptionEntryKey = nil
                        summary.kept += 1
                    } else {
                        // 普通墓碑，保留订阅字段 —— 这一条哪天回到清单还能原样复活。
                        next.isDeleted = true
                        next.deletedAt = now
                        summary.removed += 1
                    }
                    next.modifiedAt = now
                    record(next)
                }
            }
        }

        return RadioSubscriptionRefreshPlan(
            changes: changedIDs.compactMap { working[$0] },
            heldRemovalStationIDs: held,
            addedStationIDs: addedIDs,
            summary: summary
        )
    }

    /// 规则 8：用户删掉一个订阅电台 —— 变成排除标记，而不是普通墓碑。
    public static func excluding(_ station: RadioStation, now: Date = Date()) -> RadioStation {
        var marker = station
        marker.isDeleted = true
        marker.deletedAt = now
        marker.modifiedAt = now
        if station.isSubscribed {
            marker.isSubscriptionExclusion = true
        }
        return marker
    }

    /// 规则 9：取消订阅。
    ///
    /// - `keepStations`：活电台清掉订阅字段，变成用户自己的(id 不变)。
    /// - 否则活电台变普通墓碑(保留订阅字段，以后重新订阅同一个地址还能复活)。
    ///
    /// 两种情况下排除标记都变成普通墓碑并清掉排除标志 —— 订阅没了，它们
    /// 也就没有必要继续占着 CloudKit，之后照普通删除处理。
    public static func unsubscribing(
        subscriptionID: String,
        keepStations: Bool,
        stations: [RadioStation],
        now: Date = Date()
    ) -> [RadioStation] {
        var changes: [RadioStation] = []
        for station in stations where belongs(station, to: subscriptionID) {
            var next = station
            if station.isSubscriptionExclusionMarker {
                next.isSubscriptionExclusion = nil
                next.deletedAt = station.deletedAt ?? now
            } else if station.isDeleted {
                continue
            } else if keepStations {
                next.subscriptionID = nil
                next.subscriptionEntryKey = nil
            } else {
                next.isDeleted = true
                next.deletedAt = now
            }
            next.modifiedAt = now
            changes.append(next)
        }
        return changes
    }

    /// 安全阀扣下的电台，用户选择「保留」：脱离订阅，变成用户自己的电台(id 不变)。
    /// 只处理仍然活着、仍属于这份订阅的那些。
    public static func releasing(
        stationIDs: [String],
        fromSubscription subscriptionID: String,
        stations: [RadioStation],
        now: Date = Date()
    ) -> [RadioStation] {
        let targets = Set(stationIDs)
        return stations.compactMap { station in
            guard targets.contains(station.id),
                  belongs(station, to: subscriptionID),
                  !station.isDeleted else { return nil }
            var own = station
            own.subscriptionID = nil
            own.subscriptionEntryKey = nil
            own.modifiedAt = now
            return own
        }
    }

    /// 规则 10：转为我自己的电台。原电台变排除标记；另建一个用户自己的电台
    /// (新 id、没有订阅字段)。这样用户之后改地址，清单里那一条也不会被加回来。
    public static func detaching(
        _ station: RadioStation,
        newID: String,
        now: Date = Date()
    ) -> (exclusion: RadioStation, own: RadioStation) {
        let own = RadioStation(
            id: newID,
            name: station.name,
            streamURL: station.streamURL,
            logoData: station.logoData,
            logoFileName: station.logoFileName,
            streamFormat: station.streamFormat,
            bitRate: station.bitRate,
            createdAt: now,
            modifiedAt: now,
            lastPlayedAt: station.lastPlayedAt,
            sortOrder: station.sortOrder,
            homepageURL: station.homepageURL,
            remoteLogoURL: station.remoteLogoURL,
            remoteLogoSource: station.remoteLogoSource,
            folderName: station.folderName,
            tagNames: station.tagNames
        )
        return (excluding(station, now: now), own)
    }

    // MARK: - 内部

    private static func belongs(_ station: RadioStation, to subscriptionID: String) -> Bool {
        station.subscriptionID == subscriptionID && station.isSubscribed
    }

    private static func rank(_ station: RadioStation) -> Int {
        if station.isSubscriptionExclusionMarker { return 0 }
        return station.isDeleted ? 2 : 1
    }

    private static func nameKey(_ name: String) -> String {
        RadioStationOrganization.comparisonKey(RadioStationValidation.normalizedName(name))
    }

    private static func inferredFormat(_ url: String) -> RadioStreamFormat {
        URL(string: url).map { RadioStreamFormat.inferred(from: $0) } ?? .automatic
    }

    /// 只写清单拥有的字段，用户拥有的原样带着走。
    private static func applyingListFields(
        _ entry: Entry,
        to station: RadioStation,
        subscriptionID: String
    ) -> RadioStation {
        var next = station
        next.name = entry.name
        next.streamURL = entry.url
        next.streamFormat = inferredFormat(entry.url)
        if let homepage = entry.homepageURL {
            next.homepageURL = homepage
        }
        if let logo = entry.logoURL, station.remoteLogoSource?.isUserProvided != true {
            next.remoteLogoURL = logo
            next.remoteLogoSource = .importedManifest
        }
        next.subscriptionID = subscriptionID
        next.subscriptionEntryKey = entry.key
        return next
    }

    private static func listFieldsMatch(_ lhs: RadioStation, _ rhs: RadioStation) -> Bool {
        lhs.name == rhs.name
            && lhs.streamURL == rhs.streamURL
            && lhs.streamFormat == rhs.streamFormat
            && lhs.homepageURL == rhs.homepageURL
            && lhs.remoteLogoURL == rhs.remoteLogoURL
            && lhs.remoteLogoSource == rhs.remoteLogoSource
            && lhs.subscriptionID == rhs.subscriptionID
            && lhs.subscriptionEntryKey == rhs.subscriptionEntryKey
    }

    /// 新条目的 id。确定性 id 被占用时：
    /// - 普通墓碑(任何来源)→ 直接复用。墓碑在别的设备上可能已经随 CloudKit 删除
    ///   消失了，复用它才能让两边得到同一个 id；
    /// - 不属于本订阅的活电台(旧版本编辑时把订阅字段丢了，或脱离订阅留下的)→
    ///   当作「已在库里」；
    /// - 本订阅里换过地址的电台或排除标记 → 换下一个确定性备选。
    private static func resolveStationID(
        subscriptionID: String,
        entryKey: String,
        in stations: [String: RadioStation]
    ) -> IDResolution {
        for attempt in 0..<32 {
            let id = RadioSubscriptionIdentity.stationID(
                subscriptionID: subscriptionID,
                entryKey: entryKey,
                attempt: attempt
            )
            guard let occupant = stations[id] else { return .available(id) }
            if occupant.isDeleted && !occupant.isSubscriptionExclusionMarker {
                return .available(id)
            }
            if !occupant.isDeleted && !belongs(occupant, to: subscriptionID) {
                return .alreadyInLibrary
            }
        }
        return .alreadyInLibrary
    }
}

// MARK: - 刷新时机

/// 每台设备自己的刷新状态。不跨设备同步 —— 退避、错误信息和待确认的移除
/// 都是这台设备自己的事。
public struct RadioSubscriptionRefreshStatus: Codable, Hashable, Sendable {
    /// 本机第一次见到这份订阅的时间。
    public var firstSeenAt: Date?
    /// 订阅是在本机建的(而不是从别的设备同步来的)。
    public var createdLocally: Bool
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var consecutiveFailures: Int
    public var lastErrorMessage: String?
    public var lastSummary: RadioSubscriptionRefreshSummary?
    public var heldRemovalStationIDs: [String]

    public init(
        firstSeenAt: Date? = nil,
        createdLocally: Bool = false,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        consecutiveFailures: Int = 0,
        lastErrorMessage: String? = nil,
        lastSummary: RadioSubscriptionRefreshSummary? = nil,
        heldRemovalStationIDs: [String] = []
    ) {
        self.firstSeenAt = firstSeenAt
        self.createdLocally = createdLocally
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.consecutiveFailures = consecutiveFailures
        self.lastErrorMessage = lastErrorMessage
        self.lastSummary = lastSummary
        self.heldRemovalStationIDs = heldRemovalStationIDs
    }

    public var hasFailure: Bool { consecutiveFailures > 0 }
}

public enum RadioSubscriptionRefreshSchedule {
    /// 成功之后隔这么久才再自动刷新。
    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// 失败后的第一次重试间隔，之后连续失败每次翻倍。
    public static let initialRetryDelay: TimeInterval = 60 * 60
    public static let maximumRetryDelay: TimeInterval = 24 * 60 * 60
    /// 从别的设备同步来的订阅，本机第一次自动刷新至少等这么久。
    ///
    /// 发起设备建出来的电台记录(尤其是用户没勾的排除标记)要先经 CloudKit 到达；
    /// 本机要是抢先按清单建出活电台，会以更新的 `modifiedAt` 把排除盖掉。
    public static let syncedSubscriptionGracePeriod: TimeInterval = 30 * 60
    /// 同步来的 `lastRefreshedAt` 比本机时钟超前这么多就不再相信它 ——
    /// 一台时钟错乱的设备不该让别的设备永远不刷新。
    public static let clockSkewTolerance: TimeInterval = 60 * 60

    public static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        var delay = initialRetryDelay
        for _ in 1..<min(failures, 16) {
            delay *= 2
            if delay >= maximumRetryDelay { break }
        }
        return min(delay, maximumRetryDelay)
    }

    /// 自动刷新到期没有。手动「立即更新」不受这些限制。
    public static func isDue(
        subscription: RadioSubscription,
        status: RadioSubscriptionRefreshStatus,
        now: Date = Date()
    ) -> Bool {
        guard subscription.autoUpdates else { return false }

        if !status.createdLocally, let firstSeenAt = status.firstSeenAt,
           now.timeIntervalSince(firstSeenAt) < syncedSubscriptionGracePeriod {
            return false
        }

        let lastSuccess = [subscription.lastRefreshedAt, status.lastSuccessAt]
            .compactMap { $0 }
            .filter { $0.timeIntervalSince(now) <= clockSkewTolerance }
            .max()
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < refreshInterval {
            return false
        }

        if status.consecutiveFailures > 0, let lastAttemptAt = status.lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < retryDelay(afterFailures: status.consecutiveFailures) {
            return false
        }
        return true
    }
}
