import Foundation
import Observation
import PrimuseKit

/// 列表多选态。行只读 `contains(_:)`，`selectedIDs` 变化时重建的仅是当前
/// 屏幕上实例化出来的那十几行 —— 万首曲库全选也不会走全量 diff。
@MainActor
@Observable
final class SongSelectionModel {
    private(set) var isActive = false
    private(set) var selectedIDs: Set<String> = []

    /// Shift 范围选的锚点。故意不参与 Observation：它只在点击回调里读写，
    /// 让它触发行重建纯属浪费。
    @ObservationIgnored private var anchorID: String?

    var count: Int { selectedIDs.count }
    var isEmpty: Bool { selectedIDs.isEmpty }

    func contains(_ songID: String) -> Bool {
        selectedIDs.contains(songID)
    }

    /// `seed` 是长按/右键进入选择模式时那一行 —— 用户的意图显然是"先选中它"。
    func activate(seed songID: String? = nil) {
        isActive = true
        guard let songID else { return }
        selectedIDs = [songID]
        anchorID = songID
    }

    func deactivate() {
        isActive = false
        selectedIDs = []
        anchorID = nil
    }

    func toggle(_ songID: String) {
        if selectedIDs.contains(songID) {
            selectedIDs.remove(songID)
        } else {
            selectedIDs.insert(songID)
        }
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
        selectedIDs.formUnion(orderedIDs[range])
        self.anchorID = songID
    }

    func selectAll(_ songIDs: [String]) {
        selectedIDs = Set(songIDs)
        anchorID = songIDs.last
    }

    func clear() {
        selectedIDs = []
        anchorID = nil
    }

    /// 列表内容变了（歌被删、搜索条件收窄）之后丢弃已经不在列表里的选中项，
    /// 否则批量操作会作用到用户已经看不见的歌上。
    func prune(to available: Set<String>) {
        guard !selectedIDs.isEmpty else { return }
        let kept = selectedIDs.intersection(available)
        guard kept.count != selectedIDs.count else { return }
        selectedIDs = kept
    }

    /// 按列表当前顺序还原成 Song，跟用户看到的顺序一致（加入队列时尤其重要）。
    func orderedSongs(in orderedIDs: [String], resolve: (String) -> Song?) -> [Song] {
        guard !selectedIDs.isEmpty else { return [] }
        return orderedIDs.compactMap { selectedIDs.contains($0) ? resolve($0) : nil }
    }
}
