import Foundation
import Observation
import os
import PrimuseKit
#if canImport(UIKit)
import UIKit
#endif

enum SongListPerformanceSignpost {
    static let signposter = OSSignposter(
        subsystem: "com.primuse.performance",
        category: "SongList"
    )
    static let logger = Logger(
        subsystem: "com.primuse.performance",
        category: "SongList"
    )

    @MainActor
    static func selectionIntent(active: Bool, count: Int) {
        signposter.emitEvent(
            "SelectionIntent",
            "active: \(active, privacy: .public), count: \(count, privacy: .public)"
        )
        logger.info(
            "SelectionIntent active=\(active, privacy: .public) count=\(count, privacy: .public)"
        )
        #if canImport(UIKit)
        SongListDisplayTickRecorder(active: active).start()
        #endif
    }

    @MainActor
    static func sortSelection(current: String, requested: String, accepted: Bool) {
        signposter.emitEvent(
            "SortSelection",
            "current: \(current, privacy: .public), requested: \(requested, privacy: .public), accepted: \(accepted, privacy: .public)"
        )
        logger.info(
            "SortSelection current=\(current, privacy: .public) requested=\(requested, privacy: .public) accepted=\(accepted, privacy: .public)"
        )
    }

    @MainActor
    static func sortIntent(generation: Int, count: Int, order: String) {
        signposter.emitEvent(
            "SortIntent",
            "generation: \(generation, privacy: .public), count: \(count, privacy: .public), order: \(order, privacy: .public)"
        )
        logger.info(
            "SortIntent generation=\(generation, privacy: .public) count=\(count, privacy: .public) order=\(order, privacy: .public)"
        )
    }

    @MainActor
    static func sortDispatched(generation: Int, order: String) {
        signposter.emitEvent(
            "SortDispatched",
            "generation: \(generation, privacy: .public), order: \(order, privacy: .public)"
        )
        logger.info(
            "SortDispatched generation=\(generation, privacy: .public) order=\(order, privacy: .public)"
        )
    }

    @MainActor
    static func sortFeedbackScheduled(generation: Int, order: String) {
        signposter.emitEvent(
            "SortFeedbackScheduled",
            "generation: \(generation, privacy: .public), order: \(order, privacy: .public)"
        )
        logger.info(
            "SortFeedbackScheduled generation=\(generation, privacy: .public) order=\(order, privacy: .public)"
        )
    }

    @MainActor
    static func sortFeedbackShown(generation: Int, order: String, updated: Bool) {
        if updated {
            signposter.emitEvent(
                "SortFeedbackUpdated",
                "generation: \(generation, privacy: .public), order: \(order, privacy: .public)"
            )
        } else {
            signposter.emitEvent(
                "SortFeedbackShown",
                "generation: \(generation, privacy: .public), order: \(order, privacy: .public)"
            )
        }
        logger.info(
            "SortFeedbackShown generation=\(generation, privacy: .public) order=\(order, privacy: .public) updated=\(updated, privacy: .public)"
        )
    }

    @MainActor
    static func sortWaitingForPublication(generation: Int, order: String) {
        signposter.emitEvent(
            "SortWaitingForPublication",
            "generation: \(generation, privacy: .public), order: \(order, privacy: .public)"
        )
        logger.info(
            "SortWaitingForPublication generation=\(generation, privacy: .public) order=\(order, privacy: .public)"
        )
    }

    @MainActor
    static func sortCancelled(generation: Int, order: String) {
        signposter.emitEvent(
            "SortCancelled",
            "generation: \(generation, privacy: .public), order: \(order, privacy: .public)"
        )
        logger.info(
            "SortCancelled generation=\(generation, privacy: .public) order=\(order, privacy: .public)"
        )
    }

    @MainActor
    static func sortPublished(generation: Int, count: Int, order: String) {
        signposter.emitEvent(
            "SortPublished",
            "generation: \(generation, privacy: .public), count: \(count, privacy: .public), order: \(order, privacy: .public)"
        )
        logger.info(
            "SortPublished generation=\(generation, privacy: .public) count=\(count, privacy: .public) order=\(order, privacy: .public)"
        )
        #if canImport(UIKit)
        SongListDisplayTickRecorder(sortGeneration: generation).start()
        #endif
    }
}

#if canImport(UIKit)
@MainActor
private final class SongListDisplayTickRecorder: NSObject {
    private enum Kind {
        case selection(active: Bool)
        case sort(generation: Int)
    }

    private let kind: Kind
    private var displayLink: CADisplayLink?

    init(active: Bool) {
        kind = .selection(active: active)
    }

    init(sortGeneration: Int) {
        kind = .sort(generation: sortGeneration)
    }

    func start() {
        let displayLink = CADisplayLink(target: self, selector: #selector(recordTick))
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func recordTick() {
        displayLink?.invalidate()
        displayLink = nil
        switch kind {
        case .selection(let active):
            SongListPerformanceSignpost.signposter.emitEvent(
                "SelectionFirstDisplayTick",
                "active: \(active, privacy: .public)"
            )
            SongListPerformanceSignpost.logger.info(
                "SelectionFirstDisplayTick active=\(active, privacy: .public)"
            )
        case .sort(let generation):
            SongListPerformanceSignpost.signposter.emitEvent(
                "SortFirstDisplayTick",
                "generation: \(generation, privacy: .public)"
            )
            SongListPerformanceSignpost.logger.info(
                "SortFirstDisplayTick generation=\(generation, privacy: .public)"
            )
        }
    }
}
#endif

/// A row observes only its own membership object. Toggling one ID therefore
/// does not invalidate every instantiated row that happens to share this model.
@MainActor
@Observable
final class SongSelectionMembership {
    let songID: String
    private(set) var isSelected: Bool

    init(songID: String, isSelected: Bool) {
        self.songID = songID
        self.isSelected = isSelected
    }

    fileprivate func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
    }
}

/// Folder rows observe one aggregate snapshot instead of the ignored global
/// selection set. The backing index updates this object once per affected
/// folder, even when a single action changes thousands of songs.
@MainActor
@Observable
final class SongSelectionGroupMembership {
    let nodeID: LibraryFolderNodeID
    private(set) var snapshot: LibraryFolderSelectionSnapshot

    init(snapshot: LibraryFolderSelectionSnapshot) {
        nodeID = snapshot.nodeID
        self.snapshot = snapshot
    }

    fileprivate func apply(_ snapshot: LibraryFolderSelectionSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }
}

/// 列表多选态。选中 ID 的集合不参与 Observation；行只观察自己的
/// `SongSelectionMembership`，计数和批量操作各自走独立的观察边界。
@MainActor
@Observable
final class SongSelectionModel {
    typealias GroupState = LibraryFolderSelectionState

    private(set) var isActive = false
    private(set) var count = 0

    @ObservationIgnored private var selectedIDsStorage: Set<String> = []
    @ObservationIgnored private var membershipsByID: [String: SongSelectionMembership] = [:]
    @ObservationIgnored private var groupSelectionIndex = LibraryFolderSelectionIndex()
    @ObservationIgnored private var groupMembershipsByNodeID: [
        LibraryFolderNodeID: SongSelectionGroupMembership
    ] = [:]

    /// Shift 范围选的锚点。故意不参与 Observation：它只在点击回调里读写，
    /// 让它触发行重建纯属浪费。
    @ObservationIgnored private var anchorID: String?

    var selectedIDs: Set<String> { selectedIDsStorage }
    var isEmpty: Bool { count == 0 }

    func contains(_ songID: String) -> Bool {
        selectedIDsStorage.contains(songID)
    }

    func membership(for songID: String) -> SongSelectionMembership {
        if let membership = membershipsByID[songID] {
            return membership
        }
        let membership = SongSelectionMembership(
            songID: songID,
            isSelected: selectedIDsStorage.contains(songID)
        )
        membershipsByID[songID] = membership
        return membership
    }

    func groupMembership(
        for nodeID: LibraryFolderNodeID,
        version: LibraryFolderSelectionVersion,
        songIDs: [String]
    ) -> SongSelectionGroupMembership {
        let snapshot = groupSelectionIndex.register(
            nodeID: nodeID,
            version: version,
            songIDs: songIDs,
            selectedSongIDs: selectedIDsStorage
        )
        if let membership = groupMembershipsByNodeID[nodeID] {
            membership.apply(snapshot)
            return membership
        }
        let membership = SongSelectionGroupMembership(snapshot: snapshot)
        groupMembershipsByNodeID[nodeID] = membership
        return membership
    }

    /// `seed` 是长按/右键进入选择模式时那一行 —— 用户的意图显然是"先选中它"。
    func activate(seed songID: String? = nil) {
        isActive = true
        if let songID {
            replaceSelection(with: [songID])
            anchorID = songID
        }
        SongListPerformanceSignpost.selectionIntent(active: true, count: count)
    }

    func deactivate() {
        isActive = false
        replaceSelection(with: [])
        anchorID = nil
        SongListPerformanceSignpost.selectionIntent(active: false, count: 0)
    }

    func toggle(_ songID: String) {
        if selectedIDsStorage.remove(songID) == nil {
            selectedIDsStorage.insert(songID)
        }
        publishSelectionChange(changedSongIDs: [songID])
        anchorID = songID
    }

    /// Desktop lists use a plain click to replace the current selection, while
    /// Command-click toggles and Shift-click extends a range.
    func selectOnly(_ songID: String) {
        isActive = true
        replaceSelection(with: [songID])
        anchorID = songID
    }

    private func add<S: Sequence>(_ songIDs: S) where S.Element == String {
        var changedSongIDs = Set<String>()
        for songID in songIDs where selectedIDsStorage.insert(songID).inserted {
            changedSongIDs.insert(songID)
        }
        publishSelectionChange(changedSongIDs: changedSongIDs)
    }

    private func remove<S: Sequence>(_ songIDs: S) where S.Element == String {
        var changedSongIDs = Set<String>()
        for songID in songIDs where selectedIDsStorage.remove(songID) != nil {
            changedSongIDs.insert(songID)
        }
        publishSelectionChange(changedSongIDs: changedSongIDs)
    }

    private func publishSelectionChange(changedSongIDs: Set<String>) {
        guard !changedSongIDs.isEmpty else { return }
        count = selectedIDsStorage.count
        for songID in changedSongIDs {
            membershipsByID[songID]?.setSelected(selectedIDsStorage.contains(songID))
        }
        for snapshot in groupSelectionIndex.selectionDidChange(
            changedSongIDs: changedSongIDs,
            selectedSongIDs: selectedIDsStorage
        ) {
            groupMembershipsByNodeID[snapshot.nodeID]?.apply(snapshot)
        }
    }

    private func replaceSelection(with selectedIDs: Set<String>) {
        guard selectedIDs != selectedIDsStorage else { return }
        let changedSongIDs = selectedIDsStorage.symmetricDifference(selectedIDs)
        selectedIDsStorage = selectedIDs
        publishSelectionChange(changedSongIDs: changedSongIDs)
    }

    /// 锚点到目标之间整段纳入选中（不取消已选的其它行）。没有锚点时退化成单选。
    func selectRange(to songID: String, in orderedIDs: [String]) {
        guard let anchorID,
              let start = orderedIDs.firstIndex(of: anchorID),
              let end = orderedIDs.firstIndex(of: songID)
        else {
            toggle(songID)
            return
        }
        let range = start <= end ? start...end : end...start
        add(orderedIDs[range])
        self.anchorID = songID
    }

    func selectAll(_ songIDs: [String]) {
        replaceSelection(with: Set(songIDs))
        anchorID = songIDs.last
    }

    /// Folder rows reuse the song selection model so every downstream batch
    /// action keeps the existing queue and deletion boundaries. Selecting an
    /// additional folder unions its descendants; selecting it again removes
    /// only that folder's songs.
    func toggleGroup(_ songIDs: [String]) {
        let group = Set(songIDs)
        guard !group.isEmpty else { return }
        if group.isSubset(of: selectedIDsStorage) {
            remove(group)
        } else {
            add(group)
        }
        anchorID = songIDs.last
    }

    func clear() {
        replaceSelection(with: [])
        anchorID = nil
    }

    /// 列表内容变了（歌被删、搜索条件收窄）之后丢弃已经不在列表里的选中项，
    /// 否则批量操作会作用到用户已经看不见的歌上。
    func prune(to available: Set<String>) {
        guard !selectedIDsStorage.isEmpty else { return }
        let kept = selectedIDsStorage.intersection(available)
        guard kept.count != selectedIDsStorage.count else { return }
        replaceSelection(with: kept)
    }

    /// 按列表当前顺序还原成 Song，跟用户看到的顺序一致（加入队列时尤其重要）。
    func orderedSongs(in orderedIDs: [String], resolve: (String) -> Song?) -> [Song] {
        guard !selectedIDsStorage.isEmpty else { return [] }
        return orderedIDs.compactMap { selectedIDsStorage.contains($0) ? resolve($0) : nil }
    }

}
