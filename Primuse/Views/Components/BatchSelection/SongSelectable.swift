import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 勾选圈的摆放方式。
enum SongSelectionStyle: Equatable {
    /// 插在行首（列表 / 表格行）。
    case leading
    /// 浮在右上角（网格 tile —— 插行首会把整块封面挤歪）。
    case overlay
}

/// 勾选圈本体。尺寸对齐系统 editMode 的圆圈，换页面也不会忽大忽小。
struct SongSelectionCheckmark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

private struct SongSelectableModifier: ViewModifier {
    let songID: String
    let selection: SongSelectionModel
    let membership: SongSelectionMembership
    let style: SongSelectionStyle
    let orderedIDs: () -> [String]
    let defaultAction: (() -> Void)?

    func body(content: Content) -> some View {
        let isActive = selection.isActive
        let isSelected = membership.isSelected
        let decorated = content
            .overlay(alignment: overlayAlignment) {
                selectionOverlay(isActive: isActive, isSelected: isSelected)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(
                isActive
                    ? (isSelected ? [.isButton, .isSelected] : .isButton)
                    : []
            )
            .accessibilityAction(named: Text("batch_select")) {
                if isActive {
                    handleTap()
                } else {
                    selection.activate(seed: songID)
                }
            }

        #if os(iOS)
        if let defaultAction {
            if isActive {
                decorated.highPriorityGesture(longPressGesture)
            } else {
                decorated
                    .accessibilityAction(named: Text("play")) {
                        defaultAction()
                    }
                    .highPriorityGesture(longPressGesture)
            }
        } else {
            decorated.highPriorityGesture(longPressGesture)
        }
        #else
        decorated
        #endif
    }

    #if os(iOS)
    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .onEnded { _ in
                guard !selection.isActive else { return }
                selection.activate(seed: songID)
            }
    }
    #endif

    private var overlayAlignment: Alignment {
        switch style {
        case .leading: .leading
        case .overlay: .topTrailing
        }
    }

    private func selectionOverlay(isActive: Bool, isSelected: Bool) -> some View {
        ZStack(alignment: overlayAlignment) {
            Color.clear
                .contentShape(Rectangle())

            SongSelectionCheckmark(isSelected: isSelected)
                .background(Circle().fill(.background).padding(2))
                .padding(style == .leading ? 8 : 10)
                .opacity(isActive ? 1 : 0)
                .accessibilityHidden(true)
        }
        // iOS list rows already route their Button action through the selection
        // model. Leaving a full-row transparent gesture above them lets a
        // toolbar Menu dismissal click through and toggle the row underneath
        // ("select all" became N - 1 and "clear" left one item selected).
        // Grid/table callers without a default action still use this overlay.
        .allowsHitTesting(isActive && defaultAction == nil)
        .onTapGesture {
            guard defaultAction == nil else { return }
            handleTap()
        }
        .accessibilityHidden(true)
    }

    private func handleTap() {
        #if os(macOS)
        // Shift 连选是 Mac 上表格的肌肉记忆。SwiftUI 的 tap 手势不带修饰键
        // 信息，直接读当前全局修饰键状态。
        if NSEvent.modifierFlags.contains(.shift) {
            selection.selectRange(to: songID, in: orderedIDs())
            return
        }
        #endif
        selection.toggle(songID)
    }
}

extension View {
    /// 让一行歌参与多选。非选择模式下完全透明 —— 既不改布局也不拦手势。
    ///
    /// - Parameters:
    ///   - orderedIDs: 列表当前顺序，仅在 macOS Shift 连选时求值，所以传闭包
    ///     而不是数组，避免每帧为万首曲库建一次数组。
    func songSelectable(
        songID: String,
        selection: SongSelectionModel,
        style: SongSelectionStyle = .leading,
        orderedIDs: @escaping () -> [String],
        defaultAction: (() -> Void)? = nil
    ) -> some View {
        modifier(SongSelectableModifier(
            songID: songID,
            selection: selection,
            membership: selection.membership(for: songID),
            style: style,
            orderedIDs: orderedIDs,
            defaultAction: defaultAction
        ))
    }
}
