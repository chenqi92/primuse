import Foundation

/// 逐句打轴时的游标与撤销记录。
///
/// `LyricsEditorDocument` 负责歌词本身；这个类型只负责一次打轴会话里的推进、
/// 回退和微调。把这些状态放在视图之外，既能避免 SwiftUI 重绘打乱游标，也能
/// 让“重打已有时间戳后撤销”恢复原始行级/字级数据，而不是简单清空时间戳。
public struct LyricsTimingSession: Hashable, Sendable {
    private struct Change: Hashable, Sendable {
        let lineID: UUID
        let before: EditableLyricLine
        var after: EditableLyricLine
    }

    public private(set) var cursorIndex: Int?
    public private(set) var adjustmentIndex: Int?

    private var undoStack: [Change] = []
    private var redoStack: [Change] = []

    public init(document: LyricsEditorDocument, preferredIndex: Int? = nil) {
        cursorIndex = Self.resolveCursor(in: document, preferredIndex: preferredIndex)
        adjustmentIndex = Self.resolveAdjustmentIndex(
            in: document,
            cursorIndex: cursorIndex
        )
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// 手动切换正在打轴的行。只移动游标，不清空撤销历史；如果选中的是已打轴
    /// 行，后续微调就作用在该行，否则继续保留最近一次实际打点作为微调目标。
    @discardableResult
    public mutating func select(
        index: Int?,
        document: LyricsEditorDocument
    ) -> Bool {
        if let index {
            guard document.lines.indices.contains(index) else { return false }
            cursorIndex = index
            if document.lines[index].isStamped {
                adjustmentIndex = index
            } else if adjustmentIndex.flatMap({ adjustment in
                document.lines.indices.contains(adjustment)
                    ? document.lines[adjustment].timestamp
                    : nil
            }) == nil {
                adjustmentIndex = Self.resolveAdjustmentIndex(
                    in: document,
                    cursorIndex: index
                )
            }
        } else {
            cursorIndex = nil
        }
        return true
    }

    /// 文本增删、拖动排序或整体偏移后，下标历史已经不再可靠，重新建立会话。
    public mutating func reset(
        document: LyricsEditorDocument,
        preferredIndex: Int? = nil
    ) {
        cursorIndex = Self.resolveCursor(in: document, preferredIndex: preferredIndex)
        adjustmentIndex = Self.resolveAdjustmentIndex(
            in: document,
            cursorIndex: cursorIndex
        )
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }

    /// 给当前句记录时间并自动推进到下一句。返回实际被修改的行下标。
    @discardableResult
    public mutating func stamp(
        document: inout LyricsEditorDocument,
        time: TimeInterval
    ) -> Int? {
        guard let index = validCursor(in: document) else { return nil }

        let before = document.lines[index]
        document.stamp(at: index, time: time)
        let after = document.lines[index]
        record(Change(lineID: before.id, before: before, after: after))

        adjustmentIndex = index
        cursorIndex = document.lines.indices.contains(index + 1) ? index + 1 : nil
        return index
    }

    /// 恢复最近一次打点或微调前的完整行，包含原有的字级时间戳。
    @discardableResult
    public mutating func undo(document: inout LyricsEditorDocument) -> Int? {
        guard let change = undoStack.last,
              let index = document.lines.firstIndex(where: { $0.id == change.lineID }) else { return nil }

        undoStack.removeLast()
        document.lines[index] = change.before
        redoStack.append(change)
        cursorIndex = index
        adjustmentIndex = Self.resolveAdjustmentIndex(
            in: document,
            cursorIndex: cursorIndex
        )
        return index
    }

    /// 重做最近撤销的打点或微调。
    @discardableResult
    public mutating func redo(document: inout LyricsEditorDocument) -> Int? {
        guard let change = redoStack.last,
              let index = document.lines.firstIndex(where: { $0.id == change.lineID }) else { return nil }

        redoStack.removeLast()
        document.lines[index] = change.after
        undoStack.append(change)
        adjustmentIndex = index
        cursorIndex = document.lines.indices.contains(index + 1) ? index + 1 : nil
        return index
    }

    public func canNudge(in document: LyricsEditorDocument) -> Bool {
        guard let index = adjustmentIndex, document.lines.indices.contains(index) else { return false }
        return document.lines[index].timestamp != nil
    }

    /// 微调最近打过的那一句，并把微调本身也放进撤销栈。
    @discardableResult
    public mutating func nudge(
        document: inout LyricsEditorDocument,
        by delta: TimeInterval
    ) -> Int? {
        guard delta.isFinite,
              let index = adjustmentIndex,
              document.lines.indices.contains(index),
              let current = document.lines[index].timestamp else { return nil }

        let before = document.lines[index]
        document.stamp(at: index, time: max(0, current + delta))
        let after = document.lines[index]
        if var latest = undoStack.last, latest.lineID == before.id {
            // 打点后的连续微调属于同一句操作；“回退一句”应恢复打点前状态，
            // 而不是只撤销最后 0.1 秒。
            undoStack.removeLast()
            latest.after = after
            undoStack.append(latest)
            redoStack.removeAll(keepingCapacity: true)
        } else {
            record(Change(lineID: before.id, before: before, after: after))
        }
        return index
    }

    private mutating func record(_ change: Change) {
        undoStack.append(change)
        redoStack.removeAll(keepingCapacity: true)
    }

    private func validCursor(in document: LyricsEditorDocument) -> Int? {
        guard let cursorIndex, document.lines.indices.contains(cursorIndex) else { return nil }
        return cursorIndex
    }

    private static func resolveCursor(
        in document: LyricsEditorDocument,
        preferredIndex: Int?
    ) -> Int? {
        if let preferredIndex, document.lines.indices.contains(preferredIndex) {
            return preferredIndex
        }
        if let next = document.nextUnstampedIndex { return next }
        return document.lines.indices.first
    }

    private static func resolveAdjustmentIndex(
        in document: LyricsEditorDocument,
        cursorIndex: Int?
    ) -> Int? {
        if let cursorIndex, document.lines.indices.contains(cursorIndex) {
            if document.lines[cursorIndex].isStamped { return cursorIndex }
            if cursorIndex > 0 {
                return (0..<cursorIndex).reversed().first {
                    document.lines[$0].isStamped
                }
            }
        }
        return document.lines.indices.reversed().first {
            document.lines[$0].isStamped
        }
    }
}
