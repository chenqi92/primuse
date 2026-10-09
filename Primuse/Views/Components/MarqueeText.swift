import SwiftUI

/// 单行文字:放得下时照常显示;放不下时停一会儿再慢慢往左滚,首尾接上循环
/// (Apple Music 播放页的歌名、艺人那样)。开着「减弱动态效果」时不滚,只在末尾截断。
/// 读屏读完整的文字。滚动只在这一行自己的视图里发生,不让外层重画。
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    /// 每秒滚多少点。
    var speed: CGFloat = 30
    /// 每轮开始前停多久。
    var pause: Duration = .seconds(2.5)
    /// 首尾之间空多宽。
    var gap: CGFloat = 40

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isScrolling = false

    private var scrolls: Bool { !reduceMotion && textWidth > containerWidth + 1 && containerWidth > 0 }

    private struct ScrollKey: Equatable {
        var text: String
        var distance: CGFloat
        var enabled: Bool
    }

    var body: some View {
        // 占位的这一行定高度与可用宽度,真正画出来的在上面一层。
        Text(verbatim: text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .background(alignment: .leading) {
                // 量这一行不换行、不截断时有多宽。
                Text(verbatim: text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if scrolls {
                    HStack(spacing: gap) {
                        Text(verbatim: text)
                        Text(verbatim: text)
                    }
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: offset)
                    .frame(width: containerWidth, alignment: .leading)
                    .mask(edgeFade)
                } else {
                    Text(verbatim: text)
                        .font(font)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .task(id: ScrollKey(text: text, distance: textWidth + gap, enabled: scrolls)) {
                await scrollLoop()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text))
    }

    /// 末尾一直淡出;开始滚了开头也淡出,停着时第一个字不被压淡。
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(isScrolling ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 12)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 16)
        }
    }

    private func scrollLoop() async {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            offset = 0
            isScrolling = false
        }
        guard scrolls else { return }
        let distance = textWidth + gap
        let duration = Double(distance / max(speed, 1))
        while !Task.isCancelled {
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { isScrolling = true }
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // 滚完一整段时第二份正好停在开头,无动画地放回去看不出接缝。
            withTransaction(reset) { offset = 0 }
            withAnimation(.easeOut(duration: 0.25)) { isScrolling = false }
        }
    }
}
