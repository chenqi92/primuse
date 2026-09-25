import SwiftUI

#if os(iOS)
extension View {
    /// 固定内容的面板（确认框、小编辑器）默认停在半屏；矮屏上（iPhone SE、iPhone Duo 外屏）半屏装不下
    /// 全部内容时，改停在刚好装下内容的高度（最多拉满）。挂在面板里真正滚动的那块内容上（ScrollView / List）。
    ///
    /// 普通 iPhone 半屏装得下的面板，detent 原样是 `[.medium, .large]`，外观不变。只给「内容就该一眼看全」
    /// 的面板用；队列、加入歌单这类本来就是半屏先露一截、往上拉看全的列表不要挂。
    func pmFitsContentInSheet() -> some View {
        modifier(PMContentFittingSheetDetents())
    }

    /// 系统竖栏（iPhone Duo）那一侧，面板里的内容不必再让出竖栏的宽度：面板本身已经铺满屏宽，
    /// 竖栏那一段被面板盖住了。只要面板没有伸进竖排状态栏与摄像头那块遮挡区，左右边距就取对称。
    /// 没有竖栏的设备原样返回。
    func pmSheetSymmetricMargins() -> some View {
        modifier(PMSheetSymmetricMargins())
    }
}

private struct PMContentFittingSheetDetents: ViewModifier {
    /// 滚动内容还差多少点才能完整显示；≤ 0 表示装得下（负数是多出来的空白）。
    @State private var overflow: CGFloat = 0
    /// 面板这一层的可见高度。
    @State private var visibleHeight: CGFloat = 0
    /// 改停的高度。nil 时还是原来的半屏 / 全屏两档。
    @State private var fittedHeight: CGFloat?
    /// 面板此刻停在哪一档。只在停在最矮那一档时才按量出来的差值调整：拉到全屏时量到的空白
    /// 与改停的高度无关。
    @State private var selection: PresentationDetent = .medium
    /// 最多调几次：`.height` 量的高度含不含底部安全区因系统版本而异，第一次按差值加上去，
    /// 还差的那一点下一次补齐；再往后内容自己变化（比如按钮排法变了）也只再跟几次，不会来回抖。
    @State private var adjustments = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                    - geometry.containerSize.height
            } action: { _, value in
                overflow = value
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                visibleHeight = height
            }
            .onChange(of: overflow) { _, value in
                fit(overflow: value)
            }
            .onChange(of: visibleHeight) { _, _ in
                fit(overflow: overflow)
            }
            .environment(\.pmSheetContentOverflowed, fittedHeight != nil)
            .presentationDetents(
                fittedHeight.map { [.height($0), .large] } ?? [.medium, .large],
                selection: $selection
            )
    }

    private func fit(overflow: CGFloat) {
        guard visibleHeight > 0, adjustments < 4 else { return }
        if let fittedHeight {
            // 已经改停过、此刻也停在这一档：还差就补，多出来的空白也收回。
            guard selection == .height(fittedHeight), abs(overflow) > 1 else { return }
            adjustments += 1
            let height = max(fittedHeight + overflow.rounded(.up), 1)
            self.fittedHeight = height
            selection = .height(height)
        } else {
            // 还停在半屏：只有真的装不下才改停。
            guard selection == .medium, overflow > 1 else { return }
            adjustments += 1
            let height = visibleHeight + overflow.rounded(.up)
            fittedHeight = height
            selection = .height(height)
        }
    }
}

private struct PMSheetContentOverflowedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 这个面板在半屏里装不下、已经改停到按内容算的高度。面板里的排版可以据此收紧一档
    /// （比如两颗按钮改成并排）；普通 iPhone 上半屏装得下时恒为 false。
    var pmSheetContentOverflowed: Bool {
        get { self[PMSheetContentOverflowedKey.self] }
        set { self[PMSheetContentOverflowedKey.self] = newValue }
    }
}

private struct PMSheetSymmetricMargins: ViewModifier {
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    /// 面板这块区域里没有正在生效的遮挡区（竖排状态栏、前置摄像头）。
    @State private var isClearOfOcclusion = false

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(
                .container,
                edges: verticalBarEdge != nil && isClearOfOcclusion ? .horizontal : []
            )
            .onGeometryChange(for: Bool.self) { proxy in
                let height = Double(proxy.size.height)
                return PMReservedRegions.activeOcclusions(in: proxy).allSatisfy { region in
                    region.maxY <= 0 || region.minY >= height
                }
            } action: { isClear in
                isClearOfOcclusion = isClear
            }
    }
}
#endif
