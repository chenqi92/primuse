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

/// 列表多选态。选中 ID 的集合不参与 Observation；行只观察自己的
/// `SongSelectionMembership`，计数和批量操作各自走独立的观察边界。
@MainActor
@Observable
final class SongSelectionModel {
    enum GroupState: Equatable {
        case none
        case partial
        case all
    }

    private(set) var isActive = false
    private(set) var count = 0

    @ObservationIgnored private var selectedIDsStorage: Set<String> = []
    @ObservationIgnored private var membershipsByID: [String: SongSelectionMembership] = [:]

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
        let isSelected: Bool
        if selectedIDsStorage.contains(songID) {
            selectedIDsStorage.remove(songID)
            isSelected = false
        } else {
            selectedIDsStorage.insert(songID)
            isSelected = true
        }
        count = selectedIDsStorage.count
        membership(for: songID).setSelected(isSelected)
        anchorID = songID
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
        let addedIDs = orderedIDs[range]
        selectedIDsStorage.formUnion(addedIDs)
        count = selectedIDsStorage.count
        for id in addedIDs {
            membershipsByID[id]?.setSelected(true)
        }
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
            replaceSelection(with: selectedIDsStorage.subtracting(group))
        } else {
            replaceSelection(with: selectedIDsStorage.union(group))
        }
        anchorID = songIDs.last
    }

    func groupState(for songIDs: [String]) -> GroupState {
        guard !songIDs.isEmpty else { return .none }
        var selectedCount = 0
        for songID in songIDs where selectedIDsStorage.contains(songID) {
            selectedCount += 1
        }
        if selectedCount == 0 { return .none }
        return selectedCount == songIDs.count ? .all : .partial
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

    private func replaceSelection(with selectedIDs: Set<String>) {
        guard selectedIDs != selectedIDsStorage else { return }
        selectedIDsStorage = selectedIDs
        count = selectedIDs.count
        for (songID, membership) in membershipsByID {
            membership.setSelected(selectedIDs.contains(songID))
        }
    }
}
