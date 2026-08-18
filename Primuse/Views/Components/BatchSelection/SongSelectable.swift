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

    @ViewBuilder
    func body(content: Content) -> some View {
        let isActive = selection.isActive
        let isSelected = membership.isSelected

        if isActive {
            activeContent(content, isSelected: isSelected)
        } else {
            #if os(iOS)
            if let defaultAction {
                inactiveContent(content)
                    .accessibilityAction(named: Text("play")) {
                        defaultAction()
                    }
                    .highPriorityGesture(longPressGesture)
            } else {
                inactiveContent(content)
                    .highPriorityGesture(longPressGesture)
            }
            #else
            inactiveContent(content)
            #endif
        }
    }

    private func inactiveContent(_ content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: Text("batch_select")) {
                selection.activate(seed: songID)
            }
    }

    private func activeContent(_ content: Content, isSelected: Bool) -> some View {
        #if os(macOS)
        content
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? PMColor.brand.opacity(0.16) : .clear)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(PMColor.brand)
                        .frame(width: 3)
                        .padding(.vertical, 5)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        defaultAction?()
                    }
                    .onTapGesture {
                        handleTap()
                    }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(
                isSelected ? [.isButton, .isSelected] : .isButton
            )
            .accessibilityAction(named: Text("batch_select")) {
                handleTap()
            }
        #else
        content
            .overlay(alignment: overlayAlignment) {
                SongSelectionCheckmark(isSelected: isSelected)
                    .background(Circle().fill(.background).padding(2))
                    .padding(style == .leading ? 8 : 10)
                    .allowsHitTesting(false)
            }
            .overlay {
                if defaultAction == nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap() }
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(
                isSelected ? [.isButton, .isSelected] : .isButton
            )
            .accessibilityAction(named: Text("batch_select")) {
                handleTap()
            }
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

    private func handleTap() {
        #if os(macOS)
        // Shift 连选是 Mac 上表格的肌肉记忆。SwiftUI 的 tap 手势不带修饰键
        // 信息，直接读当前全局修饰键状态。
        if NSEvent.modifierFlags.contains(.shift) {
            selection.selectRange(to: songID, in: orderedIDs())
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            selection.toggle(songID)
            return
        }
        selection.selectOnly(songID)
        #else
        selection.toggle(songID)
        #endif
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
