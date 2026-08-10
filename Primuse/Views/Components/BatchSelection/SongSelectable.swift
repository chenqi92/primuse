import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 勾选圈的摆放方式。
enum SongSelectionStyle {
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
    let style: SongSelectionStyle
    let orderedIDs: () -> [String]

    func body(content: Content) -> some View {
        if selection.isActive {
            let isSelected = selection.contains(songID)
            decorated(content, isSelected: isSelected)
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        } else {
            content
        }
    }

    @ViewBuilder
    private func decorated(_ content: Content, isSelected: Bool) -> some View {
        switch style {
        case .leading:
            HStack(spacing: 10) {
                SongSelectionCheckmark(isSelected: isSelected)
                // 行内部普遍自带 Button + contextMenu（播放 / 加入歌单 / 删除）。
                // 选择模式下必须整体让位，否则点一下既 toggle 又开始播放。
                content
                    .allowsHitTesting(false)
            }
        case .overlay:
            content
                .allowsHitTesting(false)
                .overlay(alignment: .topTrailing) {
                    SongSelectionCheckmark(isSelected: isSelected)
                        // 勾选圈直接压在封面上，浅色封面会吃掉未选中的空心圈，
                        // 垫一层不透明底保证任何封面上都看得见。
                        .background(Circle().fill(.background).padding(2))
                        .padding(8)
                }
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
        orderedIDs: @escaping () -> [String]
    ) -> some View {
        modifier(SongSelectableModifier(
            songID: songID,
            selection: selection,
            style: style,
            orderedIDs: orderedIDs
        ))
    }
}
