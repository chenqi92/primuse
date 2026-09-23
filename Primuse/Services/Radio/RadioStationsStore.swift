import Foundation
import PrimuseKit

extension Notification.Name {
    static let primuseRadioStationsDidChange = Notification.Name("primuse.radioStations.changed")
    static let primuseRadioStationDidDelete = Notification.Name("primuse.radioStations.deleted")
}

struct ServerRadioSyncResult: Sendable {
    var discoveredCount = 0
    var synchronizedCount = 0
    var removedCount = 0
    var isSupported = false
}

@MainActor
@Observable
final class RadioStationsStore {
    private(set) var allStations: [RadioStation] {
        didSet { derived = DerivedCache() }
    }

    /// 由电台清单推出来的几样东西，清单一变整份作废。
    ///
    /// 音乐源镜像进来的台一多（群晖 SHOUTcast 目录上千个），每一样都是逐台排序、
    /// 清洗文件夹名、折叠比较，一次几十毫秒；首页、资料库、CarPlay 一次刷新要读好几遍，
    /// 电台页每张卡片的菜单还各要读一遍文件夹和标签 —— 不缓存就是卡片数乘以电台数。
    private struct DerivedCache {
        var stations: [RadioStation]?
        var artworkRevision: String?
        var folders: [RadioStationFolderSummary]?
        var tags: [RadioStationTagSummary]?
        var ungroupedCount: Int?
        var folderGroups: [RadioStationFolderGroup]?
        var priorityByID: [String: Int]?
    }

    @ObservationIgnored private var derived = DerivedCache()

    var stations: [RadioStation] {
        // 先读 allStations，观察者照旧挂在它上面，清单一变就会重新取值。
        let all = allStations
        if let cached = derived.stations { return cached }
        let sorted = RadioStationOrdering.sorted(all.filter { !$0.isDeleted })
        derived.stations = sorted
        return sorted
    }

    /// 台标预览的变化标记：顺序、id、台标与修改时间任何一项变了它就变。
    /// 只在本次运行内可比，不能写盘。
    var artworkRevision: String {
        let visible = stations
        if let cached = derived.artworkRevision { return cached }
        var hasher = Hasher()
        for station in visible {
            hasher.combine(station.id)
            hasher.combine(station.logoFileName)
            hasher.combine(station.logoData?.count)
            hasher.combine(station.modifiedAt)
        }
        let revision = "\(visible.count)-\(hasher.finalize())"
        derived.artworkRevision = revision
        return revision
    }

    /// 全部电台按文件夹分好的段，未分组的在最后。电台页不筛选时按它分段。
    var folderGroups: [RadioStationFolderGroup] {
        let visible = stations
        if let cached = derived.folderGroups { return cached }
        let groups = RadioStationOrganization.grouped(visible)
        derived.folderGroups = groups
        return groups
    }

    /// 每个电台在全局优先级里的位次，从 1 起。
    var priorityByID: [String: Int] {
        let visible = stations
        if let cached = derived.priorityByID { return cached }
        let positions = Dictionary(
            visible.enumerated().map { ($1.id, $0 + 1) },
            uniquingKeysWith: { first, _ in first }
        )
        derived.priorityByID = positions
        return positions
    }

    private let storeURL: URL
    /// 空文件夹的本机占位清单。文件夹本身没有独立记录(见
    /// `RadioStationOrganization`)，所以「建好文件夹再往里放电台」这一步
    /// 需要一个地方记住这个名字。它只属于本机，不进 CloudKit 也不进快照 ——
    /// 文件夹一旦装进第一个电台，别的设备自然就看见它了。
    private let folderPlaceholdersURL: URL
    private var folderPlaceholders: [String] = [] {
        didSet { derived.folders = nil }
    }
    /// 远端写入攒着还没写盘（见 `upsertFromRemote`）。
    @ObservationIgnored private var remotePersistPending = false
    @ObservationIgnored private var remotePersistTask: Task<Void, Never>?
    /// 攒着没写盘的那些远端改动本身，按到达顺序；`nil` 表示远端删除。
    /// 外部整份改写文件后 `reloadFromDisk()` 要把它们放回去（见那里）。
    @ObservationIgnored private var pendingRemoteChanges: [(id: String, station: RadioStation?)] = []
    /// 最近收听时间攒着还没写盘（见 `markPlayed`）。
    @ObservationIgnored private var playedPersistPending = false
    @ObservationIgnored private var playedPersistTask: Task<Void, Never>?

    /// 待上传账本：本机改过、还没交给 CloudKit 引擎的电台 id。
    ///
    /// 同步没在跑的时候（总开关或「音乐源」通道关着、Apple TV 启动时引擎还没起来、
    /// 引导早退）改的电台，通知发出去也没人收；记在这里并写盘，等
    /// `CloudKitSyncService` 起来或通道重新打开时补传，交给正在运行的引擎之后才销账。
    /// 不参与观察 —— 每次记账都让视图失效毫无意义。
    @ObservationIgnored private(set) var cloudPendingStationIDs: Set<String> = []
    /// 账本文件跟电台文件放同一目录（`radio-stations-cloud-pending.json`），
    /// 由 `storeURL` 推出来，测试注入的 `storeURL` 各自隔离。
    private let cloudPendingURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, storeURL: URL? = nil) {
        #if os(tvOS)
        let base = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        let directory = base.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedStoreURL = storeURL ?? directory.appendingPathComponent("radio-stations.json")
        self.storeURL = resolvedStoreURL
        self.cloudPendingURL = resolvedStoreURL.deletingLastPathComponent().appendingPathComponent(
            resolvedStoreURL.deletingPathExtension().lastPathComponent + "-cloud-pending.json"
        )
        self.folderPlaceholdersURL = directory.appendingPathComponent("radio-folders.json")
        self.allStations = []

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
        loadFolderPlaceholders()
        loadCloudPending()
        materializeLogos(for: allStations)
    }

    func station(id: String) -> RadioStation? {
        allStations.first { $0.id == id && !$0.isDeleted }
    }

    func add(_ station: RadioStation) {
        upsert(station)
    }

    func upsert(_ station: RadioStation) {
        var stamped = station
        guard !stamped.isServerMirror else { return }
        guard RadioStationValidation.isValid(name: stamped.name, urlString: stamped.streamURL),
              let normalizedURL = RadioStationValidation.normalizedURLString(stamped.streamURL),
              stamped.logoData.map({ $0.count <= RadioStationValidation.maximumLogoBytes }) ?? true else {
            return
        }
        stamped.name = RadioStationValidation.normalizedName(stamped.name)
        stamped.streamURL = normalizedURL
        stamped.modifiedAt = Date()
        stamped.isDeleted = false
        stamped.deletedAt = nil

        if let index = allStations.firstIndex(where: { $0.id == stamped.id }) {
            if stamped.sortOrder == nil {
                stamped.sortOrder = allStations[index].sortOrder
            }
            // 编辑器是整条重建电台再 upsert 的，订阅字段不在它手里。订阅电台
            // 只接受用户拥有的字段，名称、地址和订阅身份沿用现值。
            if allStations[index].isSubscribed, !allStations[index].isDeleted {
                stamped = RadioSubscriptionFieldOwnership.applyingUserEdits(
                    stamped,
                    to: allStations[index]
                )
            }
            allStations[index] = stamped
        } else {
            if stamped.sortOrder == nil,
               allStations.contains(where: { !$0.isDeleted && $0.sortOrder != nil }) {
                stamped.sortOrder = (allStations.compactMap(\.sortOrder).max() ?? -1) + 1
            }
            allStations.append(stamped)
        }
        persist()
        materializeLogos(for: [stamped])
        notifyChanged(ids: [stamped.id])
    }

    func update(_ id: String, mutate: (inout RadioStation) -> Void) {
        guard let index = allStations.firstIndex(where: { $0.id == id }) else { return }
        guard !allStations[index].isServerMirror else { return }
        // 排除标记是用户「不要这一条」的记录，任何编辑都不该让它复活。
        guard !allStations[index].isSubscriptionExclusionMarker else { return }
        var updated = allStations[index]
        mutate(&updated)
        if allStations[index].isSubscribed, !allStations[index].isDeleted {
            updated = RadioSubscriptionFieldOwnership.applyingUserEdits(updated, to: allStations[index])
        }
        guard RadioStationValidation.isValid(name: updated.name, urlString: updated.streamURL),
              let normalizedURL = RadioStationValidation.normalizedURLString(updated.streamURL),
              updated.logoData.map({ $0.count <= RadioStationValidation.maximumLogoBytes }) ?? true else {
            return
        }
        updated.name = RadioStationValidation.normalizedName(updated.name)
        updated.streamURL = normalizedURL
        updated.modifiedAt = Date()
        updated.isDeleted = false
        updated.deletedAt = nil
        allStations[index] = updated
        persist()
        materializeLogos(for: [updated])
        notifyChanged(ids: [id])
    }

    /// 写回自动发现到的台标。
    ///
    /// 走独立入口而不是 `update` 是有意的：这条路径由后台任务触发，
    /// 必须保证它既不能改动用户正在编辑的字段，也不能把用户自己选的图顶掉 ——
    /// 所以这里只碰 `remoteLogoURL` / `remoteLogoSource` 和缺失的主页地址。
    func applyDiscoveredLogo(
        id: String,
        urlString: String,
        source: RadioLogoSource,
        homepageURL: String? = nil
    ) {
        guard let index = allStations.firstIndex(where: { $0.id == id }),
              !allStations[index].isServerMirror,
              !allStations[index].isDeleted,
              let normalized = RadioLogoURLPolicy.normalized(urlString) else {
            return
        }
        // 用户在发现期间自己选了图、或者自己填了图片链接，就作废这次结果。
        guard allStations[index].logoData?.isEmpty ?? true,
              allStations[index].logoFileName?.isEmpty ?? true,
              allStations[index].remoteLogoSource?.isUserProvided != true else {
            return
        }

        var changed = false
        if allStations[index].remoteLogoURL != normalized {
            allStations[index].remoteLogoURL = normalized
            changed = true
        }
        if allStations[index].remoteLogoSource != source {
            allStations[index].remoteLogoSource = source
            changed = true
        }
        // 主页只在原本没有时补上 —— 它也是后续再次发现的输入。
        if allStations[index].homepageURL?.isEmpty ?? true,
           let homepage = RadioLogoURLPolicy.normalized(homepageURL) {
            allStations[index].homepageURL = homepage
            changed = true
        }
        guard changed else { return }

        allStations[index].modifiedAt = Date()
        persist()
        notifyChanged(ids: [id])
    }

    // MARK: - 文件夹与标签

    /// 现有文件夹，含本机记下的空文件夹。
    var folders: [RadioStationFolderSummary] {
        let visible = stations
        let placeholders = folderPlaceholders
        if let cached = derived.folders { return cached }
        let summaries = RadioStationOrganization.folders(in: visible, additionalNames: placeholders)
        derived.folders = summaries
        return summaries
    }

    /// 没有归入任何文件夹的电台数量。
    var ungroupedStationCount: Int {
        let visible = stations
        if let cached = derived.ungroupedCount { return cached }
        let count = RadioStationOrganization.ungroupedCount(in: visible)
        derived.ungroupedCount = count
        return count
    }

    /// 现有标签，按名称排序。
    var tags: [RadioStationTagSummary] {
        let visible = stations
        if let cached = derived.tags { return cached }
        let summaries = RadioStationOrganization.tags(in: visible)
        derived.tags = summaries
        return summaries
    }

    /// 建一个还没有电台的文件夹。它先只活在本机，装进第一个电台后才跟着同步走。
    @discardableResult
    func createFolder(_ rawName: String) -> String? {
        guard let name = RadioStationOrganization.normalizedFolderName(rawName) else { return nil }
        rememberFolder(name)
        return name
    }

    /// 把若干电台归入一个文件夹；`nil` 表示移出文件夹。
    ///
    /// 服务器镜像也允许归类 —— 文件夹是用户自己的整理方式，跟这个电台是不是
    /// 音乐源给的无关。镜像每次对账都会把这里写的值原样带回去。
    func setFolder(_ rawName: String?, forStationIDs ids: [String]) {
        let name = RadioStationOrganization.normalizedFolderName(rawName)
        if let name { rememberFolder(name) }
        organize(ids: ids) { station in
            guard station.assignedFolderName != name else { return false }
            station.folderName = name
            return true
        }
    }

    func renameFolder(_ rawOldName: String, to rawNewName: String) {
        guard let oldName = RadioStationOrganization.normalizedFolderName(rawOldName),
              let newName = RadioStationOrganization.normalizedFolderName(rawNewName),
              oldName != newName else { return }
        let ids = stations
            .filter { $0.assignedFolderName.map { RadioStationOrganization.isSameName($0, oldName) } == true }
            .map(\.id)
        forgetFolder(oldName)
        rememberFolder(newName)
        organize(ids: ids) { station in
            station.folderName = newName
            return true
        }
    }

    /// 删掉文件夹本身，里面的电台退回未分组 —— 删一个整理方式不该连电台一起删。
    func deleteFolder(_ rawName: String) {
        guard let name = RadioStationOrganization.normalizedFolderName(rawName) else { return }
        let ids = stations
            .filter { $0.assignedFolderName.map { RadioStationOrganization.isSameName($0, name) } == true }
            .map(\.id)
        forgetFolder(name)
        organize(ids: ids) { station in
            station.folderName = nil
            return true
        }
    }

    func addTag(_ rawName: String, toStationIDs ids: [String]) {
        guard let name = RadioStationOrganization.normalizedTagName(rawName) else { return }
        organize(ids: ids) { station in
            guard case .updated(let updated) = RadioStationOrganization.adding(
                tag: name,
                to: station.tagNames
            ) else { return false }
            station.tagNames = updated
            return true
        }
    }

    func removeTag(_ rawName: String, fromStationIDs ids: [String]) {
        guard let name = RadioStationOrganization.normalizedTagName(rawName) else { return }
        organize(ids: ids) { station in
            guard case .updated(let updated) = RadioStationOrganization.removing(
                tag: name,
                from: station.tagNames
            ) else { return false }
            station.tagNames = updated
            return true
        }
    }

    func renameTag(_ rawOldName: String, to rawNewName: String) {
        guard let oldName = RadioStationOrganization.normalizedTagName(rawOldName),
              let newName = RadioStationOrganization.normalizedTagName(rawNewName) else { return }
        organize(ids: stations.map(\.id)) { station in
            guard case .updated(let updated) = RadioStationOrganization.renaming(
                tag: oldName,
                to: newName,
                in: station.tagNames
            ) else { return false }
            station.tagNames = updated
            return true
        }
    }

    func deleteTag(_ rawName: String) {
        removeTag(rawName, fromStationIDs: stations.map(\.id))
    }

    /// 批量改整理字段。整批只落一次盘、只发一次通知 —— 逐个 `update` 会按
    /// 电台数触发同样多次写盘和同步入队。
    private func organize(ids: [String], mutate: (inout RadioStation) -> Bool) {
        guard !ids.isEmpty else { return }
        let targets = Set(ids)
        let now = Date()
        var changedIDs: [String] = []
        for index in allStations.indices where
            targets.contains(allStations[index].id) && !allStations[index].isDeleted {
            var updated = allStations[index]
            guard mutate(&updated) else { continue }
            updated.modifiedAt = now
            allStations[index] = updated
            changedIDs.append(updated.id)
        }
        guard !changedIDs.isEmpty else { return }
        persist()
        notifyChanged(ids: changedIDs)
    }

    private func rememberFolder(_ name: String) {
        guard !folderPlaceholders.contains(where: {
            RadioStationOrganization.isSameName($0, name)
        }) else { return }
        folderPlaceholders.append(name)
        persistFolderPlaceholders()
    }

    private func forgetFolder(_ name: String) {
        let kept = folderPlaceholders.filter { !RadioStationOrganization.isSameName($0, name) }
        guard kept.count != folderPlaceholders.count else { return }
        folderPlaceholders = kept
        persistFolderPlaceholders()
    }

    private func loadFolderPlaceholders() {
        guard let data = try? Data(contentsOf: folderPlaceholdersURL),
              let names = try? decoder.decode([String].self, from: data) else {
            folderPlaceholders = []
            return
        }
        folderPlaceholders = names.compactMap(RadioStationOrganization.normalizedFolderName)
    }

    private func persistFolderPlaceholders() {
        guard let data = try? encoder.encode(folderPlaceholders) else { return }
        try? data.write(to: folderPlaceholdersURL, options: .atomic)
    }

    /// Device-local recency is intentionally not pushed through CloudKit.
    ///
    /// 不立刻写盘：整份清单（含台标数据）每切一次台就重写一遍不划算，
    /// 攒 2 秒合并成一次；期间任何一次 `persist()` 都会把它一起写掉。
    /// 生命周期落盘时由 `flushPendingPersist()` 兜底。
    func markPlayed(_ id: String, at date: Date = Date()) {
        guard let index = allStations.firstIndex(where: { $0.id == id }) else { return }
        allStations[index].lastPlayedAt = date
        schedulePlayedPersist()
    }

    /// 攒着没写盘的（最近收听时间、远端改动）现在写掉。进后台、退出前调。
    func flushPendingPersist() {
        guard playedPersistPending || remotePersistPending else { return }
        persist()
    }

    private func schedulePlayedPersist() {
        playedPersistPending = true
        guard playedPersistTask == nil else { return }
        playedPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flushPendingPersist()
        }
    }

    func moveStations(from offsets: IndexSet, to destination: Int) {
        moveStations(from: offsets, to: destination, within: stations)
    }

    /// 在 `visible` 这个子集内部拖动排序。
    ///
    /// 可见电台在全局顺序里占据的**位置**不动，只是它们彼此之间的先后调换 ——
    /// 筛选状态下直接拿可见下标去改全局顺序，会把没显示出来的电台一起搅乱。
    func moveStations(from offsets: IndexSet, to destination: Int, within visible: [RadioStation]) {
        var ordered = visible
        let validOffsets = offsets.filter { ordered.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }

        let moving = validOffsets.map { ordered[$0] }
        for index in validOffsets.sorted(by: >) {
            ordered.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = max(0, min(ordered.count, destination - removedBeforeDestination))
        ordered.insert(contentsOf: moving, at: insertionIndex)

        let visibleIDs = Set(visible.map(\.id))
        var reordered = ordered.map(\.id).makeIterator()
        let globalOrder = stations.map(\.id).map { id in
            visibleIDs.contains(id) ? (reordered.next() ?? id) : id
        }
        applyPriorityOrder(globalOrder)
    }

    func moveStation(id: String, by offset: Int) {
        guard offset != 0 else { return }
        let ordered = stations
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(ordered.count - 1, index + offset))
        guard target != index else { return }

        var reordered = ordered
        let station = reordered.remove(at: index)
        reordered.insert(station, at: target)
        applyPriorityOrder(reordered.map(\.id))
    }

    func sortStationsByName() {
        let ordered = stations.sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            return result == .orderedSame ? $0.id < $1.id : result == .orderedAscending
        }
        applyPriorityOrder(ordered.map(\.id))
    }

    /// 一次性把顺序设成给定的 id 序列。批量操作(置顶 / 归组)用它，
    /// 逐个 `update` 会按站数触发同样多次落盘和同步。
    func applyOrder(_ stationIDs: [String]) {
        applyPriorityOrder(stationIDs)
    }

    func remove(id: String) {
        guard let index = allStations.firstIndex(where: { $0.id == id }) else { return }
        guard !allStations[index].isServerMirror else { return }
        if allStations[index].isSubscribed {
            // 订阅电台删掉之后要一直挡着清单里那一条，所以变成排除标记，
            // 作为一条普通的保存同步出去。这里**不能**发
            // `primuseRadioStationDidDelete`：CloudKitSyncService 收到它会把这条
            // 记录从 CloudKit 删掉，别的设备上的排除就丢了，下次刷新又加回来。
            guard !allStations[index].isDeleted else { return }
            allStations[index] = RadioSubscriptionMergePolicy.excluding(allStations[index])
            persist()
            notifyChanged(ids: [id])
            #if !os(tvOS)
            // 台标发现的退避记录照样清掉，免得状态文件随「加了又删」无限长大。
            RadioLogoDiscoveryService.shared.forget(stationIDs: [id])
            #endif
            return
        }
        allStations[index].isDeleted = true
        allStations[index].deletedAt = Date()
        allStations[index].modifiedAt = Date()
        persist()
        notifyChanged(ids: [id])
        NotificationCenter.default.post(
            name: .primuseRadioStationDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// CloudKit 送来的一条电台。整份清单是一次编码写盘的，远端一批几百上千条
    /// （订阅清单）逐条整份写，写入量就随条数平方增长，所以这里只记下待写：
    /// `CloudKitSyncService` 在一批处理完、保存引擎游标之前调 `flushRemotePersist()`，
    /// 零散调用由短延迟兜底合并。
    func upsertFromRemote(_ remote: RadioStation) {
        guard let applied = applyRemote(remote) else { return }
        pendingRemoteChanges.append((id: applied.id, station: applied))
        scheduleRemotePersist()
        materializeLogos(for: [applied])
    }

    func removeFromRemote(id: String) {
        allStations.removeAll { $0.id == id }
        pendingRemoteChanges.append((id: id, station: nil))
        scheduleRemotePersist()
    }

    /// 远端改动还有没写盘的就立刻写。
    func flushRemotePersist() {
        guard remotePersistPending else { return }
        persist()
    }

    private func scheduleRemotePersist() {
        remotePersistPending = true
        guard remotePersistTask == nil else { return }
        remotePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flushRemotePersist()
        }
    }

    /// 把一条远端电台并进内存，不写盘。不合法或不比本地新时返回 nil。
    private func applyRemote(_ remote: RadioStation) -> RadioStation? {
        guard remote.logoData.map({ $0.count <= RadioStationValidation.maximumLogoBytes }) ?? true,
              RadioStationValidation.hasConsistentServerIdentity(remote),
              remote.isDeleted
                || RadioStationValidation.hasValidPlaybackReference(remote) else {
            return nil
        }
        var normalized = remote
        if !normalized.isDeleted {
            normalized.name = RadioStationValidation.normalizedName(normalized.name)
            if normalized.requiresSourceStreamResolution,
               normalized.streamURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.streamURL = ""
            } else {
                guard let normalizedURL = RadioStationValidation.normalizedURLString(normalized.streamURL) else {
                    return nil
                }
                normalized.streamURL = normalizedURL
            }
        }
        if let index = allStations.firstIndex(where: { $0.id == normalized.id }) {
            guard allStations[index].modifiedAt <= normalized.modifiedAt else { return nil }
            var merged = normalized
            merged.lastPlayedAt = allStations[index].lastPlayedAt
            // 拉回来的与本机完全相同(全量重拉时的常态)就不算改动, 不写盘。
            guard merged != allStations[index] else { return nil }
            allStations[index] = merged
        } else {
            // 本地没有这条时，普通墓碑照旧不收；订阅的排除标记要收下 —— 它得一直
            // 挡着清单里那一条，否则本机下次刷新会把用户删掉的台加回来。
            guard !normalized.isDeleted || normalized.isSubscriptionExclusionMarker else { return nil }
            allStations.append(normalized)
        }
        return normalized
    }

    func encodedSnapshot() throws -> Data {
        try encoder.encode(allStations)
    }

    /// 把一份整份快照（Apple TV 装快照、局域网直传）逐条按修改时间并进来：
    /// 本机独有的行和本机更新的行都留着，整份并完只写一次盘。
    func applySnapshot(_ data: Data) throws {
        let incoming = try decoder.decode([RadioStation].self, from: data)
        let applied = incoming.compactMap { applyRemote($0) }
        guard !applied.isEmpty else { return }
        persist()
        materializeLogos(for: applied)
        // 被并进来的行都不比本机旧：账本里同一台的本机改动已经被盖过，不用再传。
        clearCloudPending(applied.map(\.id))
    }

    // MARK: - 清单订阅
    //
    // 这几个方法只是数据操作，三个 target 都能编；刷新与界面只在 iOS / macOS 上有。

    /// 这份订阅里还活着的电台，按优先级顺序。
    func stations(inSubscription subscriptionID: String) -> [RadioStation] {
        stations.filter { $0.isSubscribed && $0.subscriptionID == subscriptionID }
    }

    /// 写回一轮订阅合并(或取消订阅)的结果：每个值都是那个电台的最终状态。
    /// 整批只落一次盘、只发一次通知 —— 与 `reconcileServerStations` 同理，
    /// 一份几百条的清单不该触发几百次写盘和同步入队。
    func applySubscriptionChanges(_ changes: [RadioStation]) {
        guard !changes.isEmpty else { return }
        var indexByID: [String: Int] = [:]
        for (index, station) in allStations.enumerated() where indexByID[station.id] == nil {
            indexByID[station.id] = index
        }
        var changedIDs: [String] = []
        var appeared: [RadioStation] = []
        var removedIDs: [String] = []
        var staleRemoteLogoIDs: [String] = []

        for change in changes {
            guard !change.isServerMirror else { continue }
            if !change.isDeleted {
                guard RadioStationValidation.isValid(name: change.name, urlString: change.streamURL),
                      change.logoData.map({ $0.count <= RadioStationValidation.maximumLogoBytes }) ?? true else {
                    continue
                }
            }
            if let index = indexByID[change.id] {
                let previous = allStations[index]
                // 台标地址换了，缓存里那张旧图得作废 —— 缓存按电台 id 寻址，
                // 不作废的话界面会继续显示旧台标。
                if previous.remoteLogoURL != change.remoteLogoURL {
                    staleRemoteLogoIDs.append(change.id)
                }
                if previous.isDeleted, !change.isDeleted { appeared.append(change) }
                if !previous.isDeleted, change.isDeleted { removedIDs.append(change.id) }
                allStations[index] = change
            } else {
                indexByID[change.id] = allStations.count
                allStations.append(change)
                if !change.isDeleted { appeared.append(change) }
            }
            changedIDs.append(change.id)
        }
        guard !changedIDs.isEmpty else { return }

        persist()
        materializeLogos(for: appeared)
        if !staleRemoteLogoIDs.isEmpty {
            Task {
                for id in staleRemoteLogoIDs {
                    await MetadataAssetStore.shared.invalidateCoverCache(
                        forSongID: RadioStationArtworkResolutionPolicy.remoteLogoCacheSongID(for: id)
                    )
                }
            }
        }
        #if !os(tvOS)
        RadioLogoDiscoveryService.shared.forget(stationIDs: removedIDs)
        #endif
        notifyChanged(ids: changedIDs)
    }

    /// 「转为我自己的电台」：原电台变排除标记，另建一个用户自己的电台。
    /// 返回新电台的 id；这个电台不是订阅电台时返回 nil。
    @discardableResult
    func detachFromSubscription(id: String) -> String? {
        guard let index = allStations.firstIndex(where: { $0.id == id }),
              allStations[index].isSubscribed,
              !allStations[index].isDeleted else { return nil }
        let result = RadioSubscriptionMergePolicy.detaching(
            allStations[index],
            newID: UUID().uuidString
        )
        allStations[index] = result.exclusion
        allStations.append(result.own)
        persist()
        materializeLogos(for: [result.own])
        #if !os(tvOS)
        RadioLogoDiscoveryService.shared.forget(stationIDs: [id])
        #endif
        notifyChanged(ids: [result.exclusion.id, result.own.id])
        return result.own.id
    }

    /// 取消订阅：`keepStations` 为真时电台变成用户自己的，否则连同电台一起移除。
    func unsubscribe(subscriptionID: String, keepStations: Bool) {
        applySubscriptionChanges(RadioSubscriptionMergePolicy.unsubscribing(
            subscriptionID: subscriptionID,
            keepStations: keepStations,
            stations: allStations
        ))
    }

    #if !os(tvOS)
    /// Reconciles one source's complete radio snapshot in a single durable
    /// write. Server fields are authoritative, while local playback recency
    /// and user ordering survive refreshes. Missing upstream stations become
    /// tombstones so CloudKit and LAN snapshots cannot resurrect them.
    @discardableResult
    func reconcileServerStations(
        source: MusicSource,
        snapshot: ServerRadioStationSnapshot
    ) -> ServerRadioSyncResult {
        let now = Date()
        var result = ServerRadioSyncResult(
            discoveredCount: snapshot.stations.count,
            isSupported: true
        )
        let keepIDs = ServerRadioReconciliationPolicy.mirrorIDsToKeep(
            sourceID: source.id,
            serverStationIDs: snapshot.stations.map {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            failedServerStationIDs: snapshot.failedStationIDs
        )
        let syncManagedFolderNames = (snapshot.serverFolderNames + snapshot.stations.compactMap(\.serverFolderName))
            .compactMap { ServerRadioFolderPolicy.folderName(sourceName: source.name, serverFolderName: $0) }
        // 一个源可能镜像几千个台(Audio Station 的 SHOUTcast 目录):在副本上按 id 索引改完
        // 再整体写回,不逐台线性查找,也不逐台触发观察通知。
        var stations = allStations
        var indexByID: [String: Int] = [:]
        for (index, station) in stations.enumerated() where indexByID[station.id] == nil {
            indexByID[station.id] = index
        }
        var changedIDs: [String] = []
        var seenServerIDs = Set<String>()
        var nextSortOrder: Int? = stations.contains(where: {
            !$0.isDeleted && $0.sortOrder != nil
        }) ? (stations.compactMap(\.sortOrder).max() ?? -1) + 1 : nil

        for serverStation in snapshot.stations {
            let serverID = serverStation.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serverID.isEmpty, seenServerIDs.insert(serverID).inserted else { continue }
            let name = RadioStationValidation.normalizedName(serverStation.name)
            guard !name.isEmpty else { continue }

            let playbackPath = serverStation.sourcePlaybackPath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPlaybackPath = playbackPath?.isEmpty == false ? playbackPath : nil
            let normalizedStreamURL: String
            if let rawURL = serverStation.streamURL,
               !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let url = RadioStationValidation.normalizedURLString(rawURL) else { continue }
                normalizedStreamURL = url
            } else {
                guard normalizedPlaybackPath != nil else { continue }
                normalizedStreamURL = ""
            }

            let localID = ServerRadioStationIdentity.stationID(
                sourceID: source.id,
                serverStationID: serverID
            )
            let index = indexByID[localID]
            if let index, !stations[index].isServerMirror {
                continue
            }

            let existing = index.map { stations[$0] }
            var updated = RadioStation(
                id: localID,
                name: name,
                streamURL: normalizedStreamURL,
                logoData: nil,
                logoFileName: normalizedOptional(serverStation.coverArtReference),
                streamFormat: serverStation.streamFormat,
                bitRate: serverStation.bitRate,
                createdAt: existing?.createdAt ?? now,
                modifiedAt: existing?.modifiedAt ?? now,
                lastPlayedAt: existing?.lastPlayedAt,
                sortOrder: existing?.sortOrder ?? nextSortOrder,
                sourceID: source.id,
                serverStationID: serverID,
                sourceName: source.name,
                sourcePlaybackPath: normalizedPlaybackPath,
                homepageURL: normalizedHTTPURLString(serverStation.homepageURL),
                // 文件夹和标签是用户在本地整理出来的，每次对账都得原样带回去，
                // 否则一刷新就被清空。服务端自己分了文件夹的，新镜像放进对应文件夹，
                // 用户没挪过的跟着服务端换。
                folderName: ServerRadioFolderPolicy.reconciledFolderName(
                    current: existing?.folderName,
                    isNewMirror: existing == nil,
                    assigned: ServerRadioFolderPolicy.folderName(
                        sourceName: source.name,
                        serverFolderName: serverStation.serverFolderName
                    ),
                    syncManagedFolderNames: syncManagedFolderNames
                ),
                tagNames: existing?.tagNames
            )
            if existing == nil, nextSortOrder != nil {
                nextSortOrder = (nextSortOrder ?? 0) + 1
            }

            if let existing, serverMirrorContentMatches(existing, updated) {
                continue
            }
            updated.modifiedAt = now
            if let index {
                stations[index] = updated
            } else {
                indexByID[localID] = stations.count
                stations.append(updated)
            }
            changedIDs.append(localID)
            result.synchronizedCount += 1
        }

        let prefix = ServerRadioStationIdentity.stationIDPrefix(sourceID: source.id)
        for index in stations.indices where
            stations[index].id.hasPrefix(prefix)
                && !stations[index].isDeleted
                && !keepIDs.contains(stations[index].id) {
            stations[index].isDeleted = true
            stations[index].deletedAt = now
            stations[index].modifiedAt = now
            changedIDs.append(stations[index].id)
            result.removedCount += 1
        }

        // 过了保留期的镜像墓碑直接丢掉。CloudKit 记录在变成墓碑时已经删了,这里只动本地。
        let countBeforePurge = stations.count
        stations.removeAll {
            $0.id.hasPrefix(prefix) && $0.isDeleted
                && ServerRadioReconciliationPolicy.shouldPurgeMirrorTombstone(deletedAt: $0.deletedAt, now: now)
        }
        let purgedTombstones = stations.count != countBeforePurge

        guard !changedIDs.isEmpty || purgedTombstones else { return result }
        allStations = stations
        persist()
        if !changedIDs.isEmpty { notifyChanged(ids: changedIDs) }
        return result
    }

    #endif

    func removeServerMirrors(forSourceIDs sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        let prefixes = sourceIDs.map(ServerRadioStationIdentity.stationIDPrefix(sourceID:))
        let now = Date()
        var changedIDs: [String] = []
        for index in allStations.indices where
            !allStations[index].isDeleted
                && prefixes.contains(where: { allStations[index].id.hasPrefix($0) }) {
            allStations[index].isDeleted = true
            allStations[index].deletedAt = now
            allStations[index].modifiedAt = now
            changedIDs.append(allStations[index].id)
        }
        guard !changedIDs.isEmpty else { return }
        persist()
        notifyChanged(ids: changedIDs)
    }

    /// 外部整份改写了 `radio-stations.json`（Apple TV 的快照事务写入或恢复）之后重读。
    ///
    /// 内存里有两样东西不能跟着旧内容一起丢：
    /// - 已经并进内存、还没写盘的远端记录。CloudKit 一批记录逐条并进来、批末才写盘，
    ///   这时重读会把前面几条冲掉，引擎游标随后越过它们，再也不会送来。
    /// - 待上传账本里的本机改动。它们还没交给 CloudKit，文件里的是别的设备的版本。
    /// 先回放远端、再放回本机改动，两边都按修改时间取新；有变化只整份写一次。
    func reloadFromDisk() {
        let remoteChanges = remotePersistPending ? pendingRemoteChanges : []
        var pendingLocal = cloudPendingStationIDs.isEmpty
            ? []
            : allStations.filter { cloudPendingStationIDs.contains($0.id) }
        // 先按写盘的编码走一遍：日期写盘只留到秒，不这样比，文件里内容相同的行
        // 也会因为毫秒差被当成改动放回去，平白整份重写一次。
        if !pendingLocal.isEmpty,
           let encoded = try? encoder.encode(pendingLocal),
           let roundTripped = try? decoder.decode([RadioStation].self, from: encoded) {
            pendingLocal = roundTripped
        }

        load()

        var changed = false
        for change in remoteChanges {
            if let station = change.station {
                if applyRemote(station) != nil { changed = true }
            } else {
                let countBefore = allStations.count
                allStations.removeAll { $0.id == change.id }
                if allStations.count != countBefore { changed = true }
            }
        }

        if !pendingLocal.isEmpty {
            let result = RadioPendingCloudUploadPolicy.reapply(
                pendingLocal: pendingLocal,
                onto: allStations,
                id: \.id,
                modifiedAt: \.modifiedAt
            )
            if !result.restoredIDs.isEmpty {
                allStations = result.rows
                changed = true
                plog("RadioStationsStore: restored \(result.restoredIDs.count) unsent local station change(s) after reload")
            }
            // 文件里的版本更新：远端已经盖过本机这次改动，本机没有要传的了。
            clearCloudPending(result.supersededIDs)
        }

        if changed { persist() }
        materializeLogos(for: allStations)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else {
            allStations = []
            return
        }
        do {
            allStations = try decoder.decode([RadioStation].self, from: data)
        } catch {
            let backupURL = storeURL.appendingPathExtension("corrupt")
            try? data.write(to: backupURL, options: .atomic)
            allStations = []
            plog("RadioStationsStore: invalid snapshot backed up as \(backupURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func persist() {
        // 整份写盘，远端攒着的改动和最近收听时间也一并写进去了。
        remotePersistTask?.cancel()
        remotePersistTask = nil
        remotePersistPending = false
        pendingRemoteChanges.removeAll()
        playedPersistTask?.cancel()
        playedPersistTask = nil
        playedPersistPending = false
        guard let data = try? encoder.encode(allStations) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func applyPriorityOrder(_ stationIDs: [String]) {
        let orderByID = Dictionary(uniqueKeysWithValues: stationIDs.enumerated().map { ($1, $0) })
        let now = Date()
        var changedIDs: [String] = []

        for index in allStations.indices where !allStations[index].isDeleted {
            guard let order = orderByID[allStations[index].id],
                  allStations[index].sortOrder != order else { continue }
            allStations[index].sortOrder = order
            allStations[index].modifiedAt = now
            changedIDs.append(allStations[index].id)
        }

        guard !changedIDs.isEmpty else { return }
        persist()
        notifyChanged(ids: changedIDs)
    }

    /// 本地改动的唯一出口：先记进待上传账本，再发通知给 `CloudKitSyncService`。
    ///
    /// 不变量：远端入口（`upsertFromRemote`、`removeFromRemote`、`applySnapshot`、
    /// `flushRemotePersist`）绝不能调用它 —— 否则拉下来的远端改动会被当成本机改动记账，
    /// 补传时再推回 CloudKit。
    private func notifyChanged(ids: [String]) {
        markCloudPending(ids)
        NotificationCenter.default.post(
            name: .primuseRadioStationsDidChange,
            object: nil,
            userInfo: ["ids": ids]
        )
    }

    // MARK: - 待上传账本

    /// 这些电台已经交给正在运行的 CloudKit 引擎（或远端版本已经盖过本机改动），销账。
    func clearCloudPending(_ ids: some Sequence<String>) {
        guard !cloudPendingStationIDs.isEmpty else { return }
        let countBefore = cloudPendingStationIDs.count
        cloudPendingStationIDs.subtract(ids)
        guard cloudPendingStationIDs.count != countBefore else { return }
        persistCloudPending()
    }

    private func markCloudPending(_ ids: [String]) {
        let countBefore = cloudPendingStationIDs.count
        cloudPendingStationIDs.formUnion(ids)
        guard cloudPendingStationIDs.count != countBefore else { return }
        persistCloudPending()
    }

    private func loadCloudPending() {
        guard let data = try? Data(contentsOf: cloudPendingURL),
              let ids = try? decoder.decode([String].self, from: data) else { return }
        cloudPendingStationIDs = Set(ids)
    }

    private func persistCloudPending() {
        guard let data = try? encoder.encode(cloudPendingStationIDs.sorted()) else { return }
        try? data.write(to: cloudPendingURL, options: .atomic)
    }

    private func materializeLogos(for stations: [RadioStation]) {
        for station in stations {
            guard let data = station.logoData, !data.isEmpty else { continue }
            Task {
                _ = await MetadataAssetStore.shared.storeCover(data, for: "radio:\(station.id)")
            }
        }
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func normalizedHTTPURLString(_ value: String?) -> String? {
        guard let value else { return nil }
        return RadioStationValidation.normalizedURLString(value)
    }

    private func serverMirrorContentMatches(_ lhs: RadioStation, _ rhs: RadioStation) -> Bool {
        lhs.name == rhs.name
            && lhs.streamURL == rhs.streamURL
            && lhs.logoFileName == rhs.logoFileName
            && lhs.streamFormat == rhs.streamFormat
            && lhs.bitRate == rhs.bitRate
            && lhs.sortOrder == rhs.sortOrder
            && !lhs.isDeleted
            && lhs.sourceID == rhs.sourceID
            && lhs.serverStationID == rhs.serverStationID
            && lhs.sourceName == rhs.sourceName
            && lhs.sourcePlaybackPath == rhs.sourcePlaybackPath
            && lhs.homepageURL == rhs.homepageURL
            && lhs.remoteLogoURL == rhs.remoteLogoURL
            && lhs.remoteLogoSource == rhs.remoteLogoSource
            && lhs.folderName == rhs.folderName
            && lhs.tagNames == rhs.tagNames
    }
}

#if !os(tvOS)
@MainActor
enum ServerRadioSyncService {
    @discardableResult
    static func sync(
        source: MusicSource,
        sourceManager: SourceManager,
        store: RadioStationsStore,
        applyFence: ServerMirrorApplyFence = { true }
    ) async -> ServerRadioSyncResult {
        do {
            guard let snapshot = try await sourceManager.fetchServerRadioStations(for: source) else {
                return ServerRadioSyncResult()
            }
            guard applyFence() else { return ServerRadioSyncResult() }
            let result = store.reconcileServerStations(source: source, snapshot: snapshot)
            plog(
                "📻 Server radio '\(source.name)' synchronized "
                    + "\(result.synchronizedCount)/\(result.discoveredCount), removed \(result.removedCount)"
            )
            return result
        } catch is CancellationError {
            return ServerRadioSyncResult()
        } catch {
            plog("⚠️ Server radio '\(source.name)' sync failed: \(error.localizedDescription)")
            return ServerRadioSyncResult()
        }
    }
}
#endif
