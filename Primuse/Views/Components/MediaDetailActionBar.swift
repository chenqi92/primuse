import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#endif

/// 沉浸式详情页头部要消费的安全区尺寸。
///
/// 横屏时左右安全区不一定相等（刘海机横放、折叠屏外屏都可能只有一侧被切），
/// 所以两侧分开给值，头部按侧各自消费，不要拿其中一个当两边用。
/// macOS 侧只会拿到全零。
struct ImmersiveLibraryDetailInsets: Equatable {
    var top: CGFloat = 0
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    /// 头图几何：按这一刻的视口（首屏高度、字号、尺寸等级）算好，各页直接取值。
    var hero: LibraryDetailHeroLayout = LibraryDetailHeroLayoutPolicy.standard
}

#if os(iOS)
/// 详情页那层随封面变化的整页底色。
///
/// 封面主色不能直接铺满一页：饱和度高的封面会刺眼，亮封面上白字会糊。怎么压深由
/// `LibraryDetailTintPolicy` 定(规则在 PrimuseKit 里，有测试)，这里只把算好的颜色
/// 接成一张会呼吸的网格渐变(`LibraryDetailBreathingBackground`)。头图、列表、页尾
/// 共用同一层底色，页面才是一整块，而不是彩色头顶着一块灰底。
struct LibraryDetailTintStyle: Hashable {
    var top: Color
    var bottom: Color
    /// 封面调色板第二色按同一套规则压出来的副色。封面只有一种颜色时就是主色。
    var accentTop: Color
    var accentBottom: Color
    /// 3×3 网格的九个颜色，从左上按行排(`LibraryDetailTintPolicy.meshStops`):主色、亮一档、
    /// 副色三团在上半屏,正中一团暗一档,最下一行是页尾色。相邻两点都不同色 —— 封面只有一种颜色时
    /// 漂移也看得出来;九色都守白字对比度,两色之间的过渡不会比较亮的那一端更亮。
    var meshColors: [Color]

    /// 取不到封面色时的中性底。取色是异步的，颜色到位之前也先用它。
    static func neutral(colorScheme: ColorScheme) -> LibraryDetailTintStyle {
        style(LibraryDetailTintPolicy.neutralTint(appearance: appearance(for: colorScheme)))
    }

    /// - Parameters:
    ///   - artworkColor: `CoverTintProvider` 取到的封面主色。
    ///   - secondary: 封面调色板的第二色，给呼吸背景里的副色用；没有时副色就是主色。
    static func artwork(
        _ artworkColor: Color?,
        secondary: Color? = nil,
        colorScheme: ColorScheme
    ) -> LibraryDetailTintStyle {
        guard let artworkColor, let components = artworkColor.hsbComponents else {
            return neutral(colorScheme: colorScheme)
        }
        let appearance = appearance(for: colorScheme)
        let main = LibraryDetailTintPolicy.tint(
            hue: components.hue,
            saturation: components.saturation,
            brightness: components.brightness,
            appearance: appearance
        )
        let accent = LibraryDetailTintPolicy.accentTint(
            primary: components,
            secondary: secondary?.hsbComponents,
            appearance: appearance
        )
        return style(main, accent: accent)
    }

    private static func appearance(
        for colorScheme: ColorScheme
    ) -> LibraryDetailTintPolicy.Appearance {
        colorScheme == .dark ? .dark : .light
    }

    private static func style(_ tint: LibraryDetailTint, accent: LibraryDetailTint? = nil) -> LibraryDetailTintStyle {
        let accent = accent ?? tint
        return LibraryDetailTintStyle(
            top: color(tint.top),
            bottom: color(tint.bottom),
            accentTop: color(accent.top),
            accentBottom: color(accent.bottom),
            meshColors: LibraryDetailTintPolicy.meshStops(main: tint, accent: accent).map(color)
        )
    }

    private static func color(_ stop: LibraryDetailTintStop) -> Color {
        Color(hue: stop.hue, saturation: stop.saturation, brightness: stop.brightness)
    }
}

extension Color {
    /// 取色服务给出的是 `Color`，而压深规则要的是 HSB 三个分量。
    fileprivate var hsbComponents: (hue: Double, saturation: Double, brightness: Double)? {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(self).getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else { return nil }
        return (Double(hue), Double(saturation), Double(brightness))
    }
}

private struct LibraryDetailTintEnvironmentKey: EnvironmentKey {
    static let defaultValue: LibraryDetailTintStyle? = nil
}

extension EnvironmentValues {
    /// 当前详情页的底色。头图、内容块、行分隔线都按它决定自己画多透。
    var libraryDetailTint: LibraryDetailTintStyle? {
        get { self[LibraryDetailTintEnvironmentKey.self] }
        set { self[LibraryDetailTintEnvironmentKey.self] = newValue }
    }
}

/// 把某首歌的封面主色接成整页底色。
///
/// 代表封面这首歌由页面自己挑(专辑用专辑封面那首、艺术家用头像那首、风格用第一首
/// 代表曲)。取色是后台异步做的，所以先给中性底，色到了再淡入 —— 页面结构不跳动。
private struct LibraryDetailTintModifier: ViewModifier {
    let song: Song?

    @Environment(CoverTintProvider.self) private var coverTints
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.skin) private var skin

    /// 两套基座的详情页默认都是「封面色的海报」;样式声明了用自己的底色时不染。
    private var style: LibraryDetailTintStyle? {
        guard skin.tintsCollectionPages else { return nil }
        let palette = song.flatMap { coverTints.palette(forSongID: $0.id) }
        return .artwork(palette?.primary, secondary: palette?.secondary, colorScheme: colorScheme)
    }

    func body(content: Content) -> some View {
        let resolved = style
        content
            .environment(\.libraryDetailTint, resolved)
            .pmAnimation(.ambient, value: resolved)
            .task(id: song?.id) {
                guard let song else { return }
                coverTints.prepare([song])
            }
            // 这两页都能就地换封面，换完要立刻改底色，不能等下次进页面。
            .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
                coverTints.invalidateArtwork(from: note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
                coverTints.invalidateArtwork(from: note)
            }
    }
}

extension View {
    /// 详情页整页底色，取自这首歌的封面。
    func libraryDetailTint(from song: Song?) -> some View {
        modifier(LibraryDetailTintModifier(song: song))
    }

    /// 详情页里内容块的衬底。染了色的页面上用半透明白，让底色透上来；这样列表看着
    /// 是浮在页面上的一层，而不是另一块拼上去的白卡片。没染色(自己画底色的皮肤)时用
    /// 皮肤的卡片底,经典皮肤下它就是原来的 secondarySystemBackground。
    @ViewBuilder
    func libraryDetailSection(
        tint: LibraryDetailTintStyle?,
        cornerRadius: CGFloat = 16
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if tint == nil {
            background(.skin(.surface), in: shape)
                .overlay { shape.stroke(.primary.opacity(0.06), lineWidth: 0.5) }
        } else {
            background(.white.opacity(0.09), in: shape)
                .overlay { shape.stroke(.white.opacity(0.12), lineWidth: 0.5) }
        }
    }
}

struct ImmersiveLibraryDetailScrollView<Header: View, Content: View>: View {
    private let header: (ImmersiveLibraryDetailInsets) -> Header
    private let content: Content
    private let title: String?

    @Environment(\.libraryDetailTint) private var tint
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.legacyBottomChromeOverlayActive) private var legacyBottomChromeOverlayActive
    /// iPhone 才在宽画布(Duo 内屏横握)上把头图与列表并排,iPad 保持原样。
    @Environment(\.pmIsPhoneIdiom) private var isPhoneIdiom

    /// 单栏 ⇄ 两栏时头图(封面、标题、操作行)从旧位置滑到新位置。
    @Namespace private var layoutNamespace
    @State private var headerSwitch = LibraryDetailHeaderSwitch()

    /// 头图里大标题的下沿（头部坐标）。页面给大标题挂上 `libraryDetailHeroTitle()` 才有值。
    @State private var heroTitleBottom: CGFloat?
    @State private var showsInlineTitle = false
    /// 顶部安全区（状态栏 + 导航栏），给大标题算淡出位置。
    @State private var heroTopInset: CGFloat = 0

    /// - Parameter title: 大标题滚到导航栏下面之后，导航栏中间淡入的小标题。
    init(
        title: String? = nil,
        @ViewBuilder header: @escaping (ImmersiveLibraryDetailInsets) -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.header = header
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let safeArea = geometry.safeAreaInsets
            // 底部遮挡按实测：系统标签栏与附件迷你条在安全区里，iOS 18–26.0 的叠加式迷你条不在，要另加。
            let viewport = LibraryDetailHeroViewport(
                width: Double(geometry.size.width),
                height: Double(geometry.size.height + safeArea.top + safeArea.bottom),
                topInset: Double(safeArea.top),
                bottomInset: Double(safeArea.bottom)
                    + (legacyBottomChromeOverlayActive ? LibraryDetailHeroLayoutPolicy.legacyMiniPlayerOverlay : 0),
                isCompactHeight: heightClass.isCompact,
                isRegularWidth: horizontalSizeClass == .regular,
                typeSize: LibraryDetailTypeSize(dynamicTypeSize)
            )
            let insets = ImmersiveLibraryDetailInsets(
                top: safeArea.top,
                leading: safeArea.leading,
                trailing: safeArea.trailing,
                hero: LibraryDetailHeroLayoutPolicy.layout(for: viewport)
            )
            // 头图要铺满整幅屏幕, 正文不能钻到灵动岛和圆角下面。所以整页在这里
            // 连左右安全区一起出血, 正文再把左右安全区按侧加回来 —— 头部自己
            // 拿 insets 消费, 底图就是唯一铺到边的那一层。
            let pageWidth = geometry.size.width + safeArea.leading + safeArea.trailing
            let usesTwoColumns = LibraryDetailWideCanvas.usesTwoColumns(
                isPhoneIdiom: isPhoneIdiom,
                horizontalSizeClass: horizontalSizeClass,
                heightClass: heightClass,
                size: CGSize(width: pageWidth, height: geometry.size.height + safeArea.top + safeArea.bottom)
            )
            Group {
            if usesTwoColumns {
                twoColumnPage(geometry: geometry, viewport: viewport, pageWidth: pageWidth)
            } else {
            ScrollView {
                VStack(spacing: 0) {
                    header(insets)
                        .coordinateSpace(.named(LibraryDetailHeroSpace.name))
                        .libraryDetailMatchedHeader()
                        .libraryDetailSingleHeaderSwitch(headerSwitch)
                    content
                        .padding(.leading, safeArea.leading)
                        .padding(.trailing, safeArea.trailing)
                        .pmLayoutSwitchFade()
                }
                // Horizontal artwork shelves must not determine the page width.
                .frame(width: pageWidth)
                // 底色是深的, 页面里的语义色(主/次文字、分隔线、行高亮)就得按深色外观
                // 取值 —— 否则浅色模式下会是黑字压在深底上。
                .environment(\.colorScheme, tint == nil ? colorScheme : .dark)
                // 链接和图标按钮改用白色: 主题色来自正在播放的那首歌, 跟本页底色撞色
                // 的概率不低。
                .tint(tint == nil ? nil : Color.white)
            }
            .ignoresSafeArea(.container, edges: [.top, .horizontal])
            .libraryDetailSoftTopEdge()
            .onScrollGeometryChange(for: CGFloat.self) { scroll in
                scroll.contentOffset.y + scroll.contentInsets.top
            } action: { _, scrolled in
                updateInlineTitle(scrolled: scrolled, topInset: safeArea.top)
            }
            .onChange(of: safeArea.top, initial: true) { _, top in
                heroTopInset = top
            }
            .transition(PMLayoutSwitchTransition())
            }
            }
            // 头图挂到同一个命名空间上(只在 iPhone 上：外屏展开到内屏时单栏的头图也要滑过去)。
            // iPad 为 nil，头图原样不动。
            .environment(
                \.libraryDetailLayoutNamespace,
                LibraryDetailWideCanvas.isPhoneCanvas(isPhoneIdiom) ? layoutNamespace : nil
            )
            // iPhone Duo 开合时单栏 ⇄ 两栏换构图：头图滑到新位置，曲目等其余内容淡入。
            .pmLayoutSwitchAnimation(usesTwoColumns)
            .libraryDetailTracksHeaderSwitch(usesTwoColumns, state: $headerSwitch)
        }
        .environment(\.libraryDetailHeroTitleReporter, { bottom in
            if heroTitleBottom != bottom { heroTitleBottom = bottom }
        })
        .environment(\.libraryDetailHeroTopInset, heroTopInset)
        // 封面底色离内容更近,盖在皮肤底色上面;自己画底色的皮肤下没有封面底色,露出皮肤的。
        .background {
            if let tint {
                LibraryDetailBreathingBackground(tint: tint)
                    .ignoresSafeArea()
            }
        }
        .skinPageBackground(replacing: .canvasSunken)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let title {
                // 标题按值传进导航栏条目:条目跑在自己的视图图里,读不到页面的环境。
                ToolbarItem(placement: .principal) {
                    LibraryDetailInlineTitle(title: title, isVisible: showsInlineTitle, onArtwork: tint != nil)
                }
            }
        }
    }

    /// 宽画布(iPhone Duo 内屏横握)上的两栏:头图(封面、标题、操作行)在左栏,曲目与其余内容在右栏,
    /// 两栏各自滚动。头图按左栏那么宽的竖版手机算几何,和外屏上看到的是同一副头图;大标题始终在左栏里,
    /// 导航栏不再淡入小标题。
    @ViewBuilder
    private func twoColumnPage(
        geometry: GeometryProxy,
        viewport: LibraryDetailHeroViewport,
        pageWidth: CGFloat
    ) -> some View {
        let safeArea = geometry.safeAreaInsets
        // 左栏按扣掉两侧安全区之后的可用宽度取，再加上左侧安全区：竖栏落在左侧时头图不被吃掉一截。
        let leadingWidth = LibraryDetailWideCanvas.leadingColumnWidth(pageWidth: pageWidth, safeArea: safeArea)
        let trailingWidth = max(0, pageWidth - leadingWidth)
        let columnViewport = LibraryDetailHeroViewport(
            width: Double(leadingWidth - safeArea.leading),
            height: viewport.height,
            topInset: viewport.topInset,
            bottomInset: viewport.bottomInset,
            isCompactHeight: viewport.isCompactHeight,
            isRegularWidth: false,
            typeSize: viewport.typeSize
        )
        let insets = ImmersiveLibraryDetailInsets(
            top: safeArea.top,
            leading: safeArea.leading,
            trailing: 0,
            hero: LibraryDetailHeroLayoutPolicy.layout(for: columnViewport)
        )
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                header(insets)
                    .coordinateSpace(.named(LibraryDetailHeroSpace.name))
                    .libraryDetailMatchedHeader()
                    .frame(width: leadingWidth)
                    .environment(\.horizontalSizeClass, .compact)
                    .environment(\.libraryDetailActionsAdapt, true)
            }
            .scrollIndicators(.hidden)
            .frame(width: leadingWidth)

            ScrollView {
                content
                    .padding(.top, safeArea.top + 16)
                    .padding(.trailing, safeArea.trailing)
                    .frame(width: trailingWidth)
            }
            .frame(width: trailingWidth)
            .pmLayoutSwitchFade()
        }
        .environment(\.colorScheme, tint == nil ? colorScheme : .dark)
        .tint(tint == nil ? nil : Color.white)
        .ignoresSafeArea(.container, edges: [.top, .horizontal])
        .libraryDetailSoftTopEdge()
        .transition(PMLayoutSwitchTransition())
    }

    /// 大标题淡到一半（下沿离导航栏下沿还剩一半淡出距离）时换成导航栏里的小标题；
    /// 带滞回，停在线上不闪。只在翻转时写状态。
    private func updateInlineTitle(scrolled: CGFloat, topInset: CGFloat) {
        guard let heroTitleBottom else { return }
        let next = LibraryDetailHeroMotionPolicy.showsInlineTitle(
            scrolled: Double(scrolled),
            threshold: Double(heroTitleBottom - topInset - libraryDetailHeroTitleFadeDistance / 2),
            wasShowing: showsInlineTitle
        )
        if next != showsInlineTitle { showsInlineTitle = next }
    }
}

/// 详情页会呼吸的整页底色：3×3 网格渐变，控制点在固定幅度里慢慢漂。
///
/// 换专辑（或者取色晚到）时新旧两层在 ZStack 里交叉淡入，漂移不被打断；
/// 开了「减弱动态效果」时停在静止位置，App 不在前台或页面被盖住时停在原处。
struct LibraryDetailBreathingBackground: View {
    let tint: LibraryDetailTintStyle

    var body: some View {
        ZStack {
            LibraryDetailMeshLayer(tint: tint)
                .id(tint)
                .transition(.opacity)
        }
        .pmAnimation(.trackChange, value: tint)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LibraryDetailMeshLayer: View {
    let tint: LibraryDetailTintStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// 页面被推到后面(或者 sheet 盖住)时不必再逐帧画。
    @State private var isOnScreen = false

    /// 静止位置,减弱动态效果时就停在这里。
    private static let restingPoints = LibraryDetailBreathingPolicy.restingPoints.map(Self.simd)

    private var breathes: Bool {
        !reduceMotion && scenePhase == .active && isOnScreen
    }

    var body: some View {
        // 控制点位置是时间的函数(`LibraryDetailBreathingPolicy`):各点按自己的频率与相位做正弦摆动,
        // 两头慢中间快,整面是一团团色块在流,不是一张网格来回推拉。幅度是网格坐标里的定值,
        // 不随页面尺寸变;30 帧足够 —— 每帧只挪一两个点。
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !breathes)) { context in
            MeshGradient(
                width: 3,
                height: 3,
                points: reduceMotion
                    ? Self.restingPoints
                    : LibraryDetailBreathingPolicy
                        .points(at: context.date.timeIntervalSinceReferenceDate)
                        .map(Self.simd),
                colors: tint.meshColors
            )
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }

    nonisolated private static func simd(_ point: LibraryDetailMeshPoint) -> SIMD2<Float> {
        SIMD2(Float(point.x), Float(point.y))
    }
}

/// 详情页头图下那一排的圆形次按钮(随机、下载、加入快速访问)。
///
/// 压在封面取色的整页底色上:iOS 26 起用系统玻璃,更早的系统用半透明白叠材质。
/// 两套基座共用 —— 这一排的版式由详情页自己决定,不随皮肤变。
struct LibraryDetailCircleButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var size: CGFloat = 54
    var isOn = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .libraryDetailGlass(Circle(), highlighted: isOn)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 详情页的主按钮:白底胶囊,字用本页底色。
struct LibraryDetailPlayPill: View {
    var title: LocalizedStringKey = "play"
    var systemImage = "play.fill"
    /// 为假时胶囊里只有图标(字放不下时),文字留给旁白。
    var showsTitle = true
    var height: CGFloat = 54
    let disabled: Bool
    let action: () -> Void

    @Environment(\.libraryDetailTint) private var tint

    var body: some View {
        Button(action: action) {
            label
                .font(.headline.weight(.bold))
                .foregroundStyle(tint?.bottom ?? .black)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(.white, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    @ViewBuilder
    private var label: some View {
        if showsTitle {
            Label(title, systemImage: systemImage)
        } else {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
    }
}

/// 艺术家页居中的大圆形播放键。
struct LibraryDetailPlayCircle: View {
    var size: CGFloat = 80
    let disabled: Bool
    let action: () -> Void

    @Environment(\.libraryDetailTint) private var tint

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(tint?.bottom ?? .black)
                .offset(x: size * 0.03)
                .frame(width: size, height: size)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .accessibilityLabel(Text("play"))
    }
}

/// 详情页上「加入 / 移出快捷收藏」的圆键。读写的是资料库快捷收藏那份存储,
/// 与「编辑快捷收藏」页同一套规则:满了就不能再加。
struct QuickAccessPinCircleButton: View {
    let pin: LibraryPinReference
    var size: CGFloat = 54

    @AppStorage(LibraryPinStorage.defaultsKey) private var pinsRawValue = ""
    @AppStorage(LibraryDisplayConfiguration.quickAccessLimitKey)
    private var configuredLimit = LibraryDisplayConfiguration.defaultQuickAccessLimit

    private var limit: Int { LibraryDisplayConfiguration.normalizedQuickAccessLimit(configuredLimit) }
    private var pins: [LibraryPinReference] { LibraryPinStorage.decode(pinsRawValue, maximumCount: limit) }

    var body: some View {
        let current = pins
        let isPinned = current.contains(pin)
        LibraryDetailCircleButton(
            systemImage: isPinned ? "pin.fill" : "pin",
            label: isPinned ? "library_remove_quick_access" : "library_add_quick_access",
            size: size,
            isOn: isPinned,
            disabled: !isPinned && current.count >= limit
        ) {
            var updated = current
            if let index = updated.firstIndex(of: pin) {
                updated.remove(at: index)
            } else if updated.count < limit {
                updated.append(pin)
            }
            pinsRawValue = LibraryPinStorage.encode(updated, maximumCount: limit)
        }
        .sensoryFeedback(.selection, trigger: isPinned)
    }
}

extension View {
    /// 压在封面色上的玻璃底。
    @ViewBuilder
    func libraryDetailGlass<S: Shape>(_ shape: S, highlighted: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular.tint(.white.opacity(highlighted ? 0.34 : 0.12)).interactive(),
                in: shape
            )
        } else {
            background(.white.opacity(highlighted ? 0.32 : 0.16), in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}
#endif

#if os(iOS)
/// 详情页什么时候排成两栏：iPhone（含 iPhone Duo）上常规宽度、非紧凑高度、横向且足够宽的画布，
/// 也就是 Duo 内屏横握。iPad 有自己的侧边栏版式，普通 iPhone 横竖屏都是紧凑的一边，都不走这里。
enum LibraryDetailWideCanvas {
    @MainActor
    static func usesTwoColumns(
        isPhoneIdiom: Bool,
        horizontalSizeClass: UserInterfaceSizeClass?,
        heightClass: PMHeightClass,
        size: CGSize
    ) -> Bool {
        WideCanvasColumnsPolicy.usesTwoColumns(
            isPhone: isPhoneCanvas(isPhoneIdiom),
            isRegularWidth: horizontalSizeClass == .regular,
            isCompactHeight: heightClass.isCompact,
            width: Double(size.width),
            height: Double(size.height)
        )
    }

    /// 这块画布有没有可能分两栏：没有可能时调用方连尺寸都不必量，普通 iPhone 的视图树原样不动。
    @MainActor
    static func mayUseTwoColumns(
        isPhoneIdiom: Bool,
        horizontalSizeClass: UserInterfaceSizeClass?,
        heightClass: PMHeightClass
    ) -> Bool {
        isPhoneCanvas(isPhoneIdiom)
            && horizontalSizeClass == .regular
            && !heightClass.isCompact
    }

    /// 左栏（头图）的宽度：按扣掉两侧安全区之后的可用宽度取，再加上左侧安全区 ——
    /// 系统竖栏落在左侧时，头图的封面与操作行照样有那么宽，不被竖栏吃掉一截。
    static func leadingColumnWidth(pageWidth: CGFloat, safeArea: EdgeInsets) -> CGFloat {
        let contentWidth = max(0, pageWidth - safeArea.leading - safeArea.trailing)
        return CGFloat(WideCanvasColumnsPolicy.detailLeadingColumnWidth(pageWidth: Double(contentWidth)))
            + safeArea.leading
    }

    @MainActor
    static func isPhoneCanvas(_ isPhoneIdiom: Bool) -> Bool {
        isPhoneIdiom || UIDevice.current.userInterfaceIdiom == .phone
    }
}
#endif

extension EnvironmentValues {
    /// 详情页单栏与两栏（iPhone Duo 内屏）的头部共用的命名空间。只在 iPhone 上有，iPad 与 Mac 为 nil。
    var libraryDetailLayoutNamespace: Namespace.ID? {
        get { self[LibraryDetailLayoutNamespaceKey.self] }
        set { self[LibraryDetailLayoutNamespaceKey.self] = newValue }
    }
}

private struct LibraryDetailLayoutNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private enum LibraryDetailLayoutElement: Hashable {
    case header
    /// 刚从两栏换回单栏时单栏头部用的身份：不和正在退场的左栏头部配对，直接出现在自己的位置。
    case headerInPlace
}

private struct LibraryDetailHeaderJoinsMatchKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 头部这一次要不要和另一种排法的头部配对滑动。两栏切回单栏时为假（见 `LibraryDetailHeaderSwitch`）。
    fileprivate var libraryDetailHeaderJoinsMatch: Bool {
        get { self[LibraryDetailHeaderJoinsMatchKey.self] }
        set { self[LibraryDetailHeaderJoinsMatchKey.self] = newValue }
    }
}

extension View {
    /// 把详情页头部挂到两栏容器的命名空间上：单栏换成两栏时头部滑到左栏；两栏换回单栏时旧头部在原处淡出、
    /// 新头部直接出现在自己的位置。没有命名空间（不是 iPhone）时原样返回。
    func libraryDetailMatchedHeader() -> some View {
        modifier(LibraryDetailMatchedHeader())
    }
}

private struct LibraryDetailMatchedHeader: ViewModifier {
    @Environment(\.libraryDetailLayoutNamespace) private var namespace
    @Environment(\.libraryDetailHeaderJoinsMatch) private var joinsMatch

    func body(content: Content) -> some View {
        if let namespace {
            // 只对齐位置、不插值尺寸：单栏与左栏宽度差得多，插值宽度会让标题与按钮一路折行。
            // 换排法时新旧两份头部同时在场：新的保持不透明，旧的很快淡出，不会叠成两份实心的。
            content
                .matchedGeometryEffect(
                    id: joinsMatch ? LibraryDetailLayoutElement.header : .headerInPlace,
                    in: namespace,
                    properties: .position,
                    anchor: .top
                )
                .pmLayoutSwitchQuickFadeOut()
        } else {
            content
        }
    }
}

/// 详情页头部在单栏与两栏之间换排法的方向。
///
/// 单栏换成两栏时，窄的左栏头部从单栏头部的中点滑过去，全程在屏幕里。反过来两栏换回单栏时，整幅宽的新头部
/// 要是从窄左栏的中点起步，左半截会越过屏幕左缘被裁掉 —— 所以这一次单栏头部不配对，旧头部在原处很快淡出、
/// 新头部直接出现在自己的位置。换完、旧头部退场之后单栏头部再回到配对里，下一次换成两栏时照样滑。
struct LibraryDetailHeaderSwitch: Equatable {
    struct Pending: Equatable {
        var twoColumns: Bool
        var generation: Int
    }

    /// 页面最后停稳在哪种排法。还没排过时为 nil。
    private(set) var settledTwoColumns: Bool?
    /// 正在换过去、过渡还没走完的排法。
    private(set) var pending: Pending?
    private var generation = 0

    /// 单栏头部此刻要不要参与配对：页面停在两栏、正要换回单栏时不配对。
    var singleHeaderJoinsMatch: Bool {
        settledTwoColumns != true
    }

    mutating func change(to twoColumns: Bool) {
        guard let settled = settledTwoColumns else {
            settledTwoColumns = twoColumns
            return
        }
        guard settled != twoColumns else {
            pending = nil
            return
        }
        generation += 1
        pending = Pending(twoColumns: twoColumns, generation: generation)
    }

    mutating func settle(_ done: Pending) {
        guard pending == done else { return }
        settledTwoColumns = done.twoColumns
        pending = nil
    }
}

extension View {
    /// 单栏那一份头部所在的子树：两栏刚换回单栏时头部不配对，直接出现在自己的位置。
    func libraryDetailSingleHeaderSwitch(_ state: LibraryDetailHeaderSwitch) -> some View {
        environment(\.libraryDetailHeaderJoinsMatch, state.singleHeaderJoinsMatch)
    }

    /// 跟着排法记下换排法的方向；等这一次换构图的过渡走完（旧头部退场）才记成停稳。
    func libraryDetailTracksHeaderSwitch(_ twoColumns: Bool, state: Binding<LibraryDetailHeaderSwitch>) -> some View {
        modifier(LibraryDetailHeaderSwitchTracker(twoColumns: twoColumns, state: state))
    }
}

private struct LibraryDetailHeaderSwitchTracker: ViewModifier {
    let twoColumns: Bool
    @Binding var state: LibraryDetailHeaderSwitch

    func body(content: Content) -> some View {
        content
            .onChange(of: twoColumns, initial: true) { _, newValue in
                state.change(to: newValue)
            }
            .task(id: state.pending) {
                guard let pending = state.pending else { return }
                try? await Task.sleep(for: PMLayoutSwitchTiming.settleDelay)
                guard !Task.isCancelled else { return }
                state.settle(pending)
            }
    }
}

/// 歌单、智能歌单这类自己排整页的详情页用的两栏容器：够宽时头部与列表左右分栏、各自滚动，
/// 否则原样交回单栏的整页（调用方自己的 ScrollView）。只在可能分栏的画布上才量尺寸，
/// 普通 iPhone 与 iPad 上直接返回单栏，视图树不变。
struct LibraryDetailWideColumns<Single: View, Header: View, Content: View>: View {
    @ViewBuilder let single: () -> Single
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(\.pmIsPhoneIdiom) private var isPhoneIdiomEnvironment
    /// 单栏 ⇄ 两栏时头部从旧位置滑到新位置(页面在头部上挂 `libraryDetailMatchedHeader()`)。
    @Namespace private var layoutNamespace
    @State private var headerSwitch = LibraryDetailHeaderSwitch()
    #endif

    var body: some View {
        #if os(iOS)
        let mayUseTwoColumns = LibraryDetailWideCanvas.mayUseTwoColumns(
            isPhoneIdiom: isPhoneIdiomEnvironment,
            horizontalSizeClass: horizontalSizeClass,
            heightClass: heightClass
        )
        Group {
        if mayUseTwoColumns {
            GeometryReader { geometry in
                let safeArea = geometry.safeAreaInsets
                let pageWidth = geometry.size.width + safeArea.leading + safeArea.trailing
                let usesTwoColumns = LibraryDetailWideCanvas.usesTwoColumns(
                    isPhoneIdiom: isPhoneIdiomEnvironment,
                    horizontalSizeClass: horizontalSizeClass,
                    heightClass: heightClass,
                    size: CGSize(width: pageWidth, height: geometry.size.height + safeArea.top + safeArea.bottom)
                )
                Group {
                if usesTwoColumns {
                    let leadingWidth = LibraryDetailWideCanvas.leadingColumnWidth(pageWidth: pageWidth, safeArea: safeArea)
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            header()
                                .padding(.leading, safeArea.leading)
                                .padding(.top, 16)
                                .frame(width: leadingWidth)
                                .environment(\.libraryDetailActionsAdapt, true)
                        }
                        .scrollIndicators(.hidden)
                        .frame(width: leadingWidth)

                        ScrollView {
                            content()
                                .padding(.top, 16)
                                .padding(.trailing, safeArea.trailing)
                                .frame(width: max(0, pageWidth - leadingWidth))
                        }
                        .pmLayoutSwitchFade()
                    }
                    .ignoresSafeArea(.container, edges: .horizontal)
                    .transition(PMLayoutSwitchTransition())
                } else {
                    single()
                        .libraryDetailSingleHeaderSwitch(headerSwitch)
                        .transition(PMLayoutSwitchTransition())
                }
                }
                // iPhone Duo 内屏转屏时单栏 ⇄ 两栏换构图：头部滑到新位置，曲目等其余内容淡入。
                .pmLayoutSwitchAnimation(usesTwoColumns)
                .libraryDetailTracksHeaderSwitch(usesTwoColumns, state: $headerSwitch)
            }
        } else {
            single()
                .libraryDetailSingleHeaderSwitch(headerSwitch)
                .transition(PMLayoutSwitchTransition())
                .libraryDetailTracksHeaderSwitch(false, state: $headerSwitch)
        }
        }
        // 头部挂到同一个命名空间上：外屏(紧凑宽度)展开到内屏时，单栏的头部也滑到两栏的左栏。
        // 不是 iPhone 时为 nil，头部原样不动。
        .environment(
            \.libraryDetailLayoutNamespace,
            LibraryDetailWideCanvas.isPhoneCanvas(isPhoneIdiomEnvironment) ? layoutNamespace : nil
        )
        // iPhone Duo 开合(紧凑 ⇄ 常规宽度)时同理。
        .pmLayoutSwitchAnimation(mayUseTwoColumns)
        #else
        single()
        #endif
    }
}


struct LibraryDetailActionButton: View {
    /// 按钮的样子。窄栏里整行文字放不下时，操作行会退到后两种（见 `LibraryDetailAdaptiveActionRow`）。
    enum Form {
        /// 图标 + 文字的胶囊（原来的样子）。
        case capsule
        /// 只有图标的胶囊，文字留给旁白。
        case iconCapsule
        /// 只有图标的圆形。
        case circle
    }

    let title: LocalizedStringKey
    let systemImage: String
    var emphasized = false
    var onArtwork = true
    var fillsWidth = false
    var form: Form = .capsule
    let disabled: Bool
    let action: () -> Void

    #if os(iOS)
    @Environment(\.libraryDetailTint) private var tint
    #endif

    /// 染了色的详情页上主按钮是白底、字用本页底色；次按钮是一层半透明白。
    /// 主题色在这里不能用 —— 它跟着正在播放的歌走，跟本页底色撞色的概率不低。
    private var labelColor: Color {
        #if os(iOS)
        if let tint { return emphasized ? tint.bottom : .white }
        #endif
        return emphasized || onArtwork ? .white : .accentColor
    }

    private var fillColor: Color {
        #if os(iOS)
        if tint != nil { return emphasized ? .white : .white.opacity(0.16) }
        #endif
        return emphasized ? .accentColor : (onArtwork ? .white.opacity(0.18) : .accentColor.opacity(0.12))
    }

    var body: some View {
        Button(action: action) {
            switch form {
            case .capsule:
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(labelColor)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 48)
                    .background(fillColor, in: Capsule())
            case .iconCapsule:
                Label(title, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .foregroundStyle(labelColor)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 48)
                    .background(fillColor, in: Capsule())
            case .circle:
                // 圆要把图标整个圈住：大字号下图标比 48 还大，四周再留一圈。
                Label(title, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .foregroundStyle(labelColor)
                    .padding(12)
                    .frame(minWidth: 48, minHeight: 48)
                    .background(fillColor, in: Circle())
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

/// 专辑、艺术家、流派详情页头部的「播放 / 随机播放」一行。
///
/// 放得下时就是原来那两颗胶囊（`stacksAtLargeType` 时大字号下上下叠）。窄栏里整行文字放不下时
/// 依次退成「播放通栏 + 圆形随机」「只剩图标」，按钮文字不折成两行。
struct LibraryDetailPlayShuffleRow: View {
    /// 专辑、艺术家的两颗胶囊平分整行；流派的按文字宽。
    var fillsWidth = true
    /// 大字号（xxLarge 起）时两颗上下叠。
    var stacksAtLargeType = true
    let playDisabled: Bool
    let shuffleDisabled: Bool
    let play: () -> Void
    let shuffle: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LibraryDetailAdaptiveActionRow {
            let layout = stacksAtLargeType && dynamicTypeSize >= .xxLarge
                ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: 10))
            layout {
                playButton(.capsule, fills: fillsWidth)
                shuffleButton(.capsule, fills: fillsWidth)
            }
        } reduced: {
            HStack(spacing: 10) {
                playButton(.capsule, fills: true)
                shuffleButton(.circle, fills: false)
            }
        } minimal: {
            HStack(spacing: 10) {
                playButton(.iconCapsule, fills: true)
                shuffleButton(.circle, fills: false)
            }
        }
    }

    private func playButton(_ form: LibraryDetailActionButton.Form, fills: Bool) -> some View {
        LibraryDetailActionButton(
            title: "play",
            systemImage: "play.fill",
            emphasized: true,
            fillsWidth: fills,
            form: form,
            disabled: playDisabled,
            action: play
        )
    }

    private func shuffleButton(_ form: LibraryDetailActionButton.Form, fills: Bool) -> some View {
        LibraryDetailActionButton(
            title: "shuffle",
            systemImage: "shuffle",
            fillsWidth: fills,
            form: form,
            disabled: shuffleDisabled,
            action: shuffle
        )
    }
}

/// 详情页操作行在窄栏里的退让。整行放得下就是 `full`（原来的排法）；iPhone Duo 两栏的左栏、
/// 系统竖栏这类新画布上放不下时依次换成 `reduced`、`minimal`，按钮文字永不折行。
/// 普通 iPhone 与 iPad 只走 `full`，和原来逐像素一致；`adaptsAtAnyWidth` 的行（整行文字在普通 iPhone
/// 上本来就放不下的）不论画布都按宽度退让。
///
/// 不用 `ViewThatFits`：它按理想宽度摆选中的那一种，撑满整行的按钮会缩成按文字宽。这里先在一层
/// 不显示的背景里量出各排法不折行时要多宽，再按这一行实际有多宽挑一种正常摆。
struct LibraryDetailAdaptiveActionRow<Full: View, Reduced: View, Minimal: View>: View {
    /// 不论在什么画布上都按这一行的实际宽度退让。
    var adaptsAtAnyWidth = false
    @ViewBuilder let full: () -> Full
    @ViewBuilder let reduced: () -> Reduced
    @ViewBuilder let minimal: () -> Minimal

    @Environment(\.libraryDetailActionsAdapt) private var adaptsInColumn
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @State private var widths = LibraryDetailActionRowWidths()

    var body: some View {
        if adaptsAtAnyWidth || adaptsInColumn || verticalBarEdge != nil {
            chosenRow
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.available = $0 }
                .background {
                    ZStack {
                        full()
                            .fixedSize()
                            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                                widths.full = $0.width
                                widths.fullSingleLineHeight = $0.height
                            }
                        if let available = widths.available {
                            // 按这一行实际的宽度再排一次：等宽的几颗按钮是平分整行的，总宽放得下时
                            // 最长的那颗仍可能折行，比一比高度就知道。
                            full()
                                .frame(width: available)
                                .fixedSize(horizontal: false, vertical: true)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                    widths.fullHeightAtAvailable = $0
                                }
                        }
                        reduced()
                            .fixedSize(horizontal: true, vertical: false)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.reduced = $0 }
                    }
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            full()
        }
    }

    @ViewBuilder
    private var chosenRow: some View {
        switch widths.step {
        case .full: full()
        case .reduced: reduced()
        case .minimal: minimal()
        }
    }
}

/// 操作行这一栏有多宽、各排法不折行时要多宽，按此挑排法。还没量出来时先用原来的排法。
struct LibraryDetailActionRowWidths: Equatable {
    enum Step {
        case full, reduced, minimal
    }

    var available: CGFloat?
    var full: CGFloat?
    var reduced: CGFloat?
    /// `full` 不折行时的高度，和按这一行实际宽度排出来的高度。后者更高就是有按钮的文字折行了。
    var fullSingleLineHeight: CGFloat?
    var fullHeightAtAvailable: CGFloat?

    private var fullWrapsAtAvailable: Bool {
        guard let fullSingleLineHeight, let fullHeightAtAvailable else { return false }
        return fullHeightAtAvailable > fullSingleLineHeight + 0.5
    }

    var step: Step {
        guard let available else { return .full }
        // 半个点的余量：量出来的理想宽度与实际摆放的宽度会差一点浮点零头。
        if let full, full <= available + 0.5, !fullWrapsAtAvailable { return .full }
        if let reduced, reduced <= available + 0.5 { return .reduced }
        return full == nil || reduced == nil ? .full : .minimal
    }
}

private struct LibraryDetailActionsAdaptKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 详情页头部排在窄栏里（iPhone Duo 两栏的左栏）：操作行放不下整行文字时换更省地方的排法。
    var libraryDetailActionsAdapt: Bool {
        get { self[LibraryDetailActionsAdaptKey.self] }
        set { self[LibraryDetailActionsAdaptKey.self] = newValue }
    }
}

struct LibraryReviewSection: View {
    @Environment(MusicLibrary.self) private var library
    @AppStorage(LibraryReviewPreferences.enabledKey) private var isEnabled = false

    let subject: LibraryReviewSubject
    var compact = false
    var onArtwork = false
    var foregroundColor: Color? = nil
    var topSpacing: CGFloat = 0

    @State private var showsCommentEditor = false

    private var usesCompactControls: Bool {
        #if os(iOS)
        compact
        #else
        false
        #endif
    }

    private var review: LibraryReview? {
        library.libraryReview(for: subject)
    }

    var body: some View {
        if isEnabled {
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                if !compact {
                    Label("library_review_title", systemImage: "star.bubble")
                        .font(.headline)
                        .foregroundStyle(onArtwork ? Color.white : Color.primary)
                }

                HStack(spacing: compact ? 5 : 8) {
                    LibraryReviewRatingPicker(
                        rating: review?.rating,
                        foregroundStyle: foregroundColor ?? (onArtwork ? .white : .yellow),
                        buttonSize: usesCompactControls ? 36 : 30
                    ) { rating in
                        library.updateLibraryReview(
                            for: subject,
                            rating: rating == review?.rating ? nil : rating,
                            comment: review?.comment ?? ""
                        )
                    }

                    Spacer(minLength: 8)

                    if usesCompactControls {
                        commentButton.buttonStyle(.plain)
                    } else {
                        commentButton.buttonStyle(.bordered)
                    }
                }

                if let comment = review?.comment, !comment.isEmpty {
                    Text(verbatim: comment)
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(foregroundColor?.opacity(0.78) ?? (onArtwork ? Color.white.opacity(0.78) : Color.secondary))
                        .lineLimit(compact ? 2 : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture { showsCommentEditor = true }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, topSpacing)
            .sheet(isPresented: $showsCommentEditor) {
                LibraryReviewCommentEditor(subject: subject)
            }
        }
    }

    private var commentButton: some View {
        Button {
            showsCommentEditor = true
        } label: {
            if compact {
                Image(systemName: review?.comment.isEmpty == false ? "text.bubble.fill" : "text.bubble")
                    .font(usesCompactControls ? .system(size: 17, weight: .medium) : nil)
                    .frame(width: usesCompactControls ? 36 : nil, height: usesCompactControls ? 36 : nil)
                    .contentShape(Rectangle())
            } else {
                Label(
                    review?.comment.isEmpty == false
                        ? "library_review_edit_comment"
                        : "library_review_add_comment",
                    systemImage: review?.comment.isEmpty == false ? "text.bubble.fill" : "text.bubble"
                )
            }
        }
        .foregroundStyle(foregroundColor ?? (onArtwork ? Color.white : Color.accentColor))
        .accessibilityLabel(Text(review?.comment.isEmpty == false
            ? "library_review_edit_comment" : "library_review_add_comment"))
        .accessibilityHint(Text("library_review_comment_hint"))
    }
}

struct LibraryReviewRatingPicker: View {
    let rating: Int?
    let foregroundStyle: Color
    var symbolSize: CGFloat = 17
    var buttonSize: CGFloat = 30
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    onSelect(value)
                } label: {
                    Image(systemName: value <= (rating ?? 0) ? "star.fill" : "star")
                        .font(.system(size: symbolSize, weight: .semibold))
                        .foregroundStyle(
                            value <= (rating ?? 0)
                                ? foregroundStyle
                                : foregroundStyle.opacity(0.35)
                        )
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text(
                        String(
                            format: String(localized: "library_review_star_format"),
                            value
                        )
                    )
                )
                .accessibilityAddTraits(value == rating ? .isSelected : [])
            }
        }
        // 五颗星是一个很小的容器；没有事务驱动的话 contentTransition 不会生效。
        .pmAnimation(.control, value: rating)
        .contextMenu {
            if let rating {
                Button("library_review_clear_rating", systemImage: "star.slash") { onSelect(rating) }
            }
        }
        .accessibilityActions {
            if let rating {
                Button("library_review_clear_rating") { onSelect(rating) }
            }
        }
    }
}

private struct LibraryReviewCommentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var library

    let subject: LibraryReviewSubject
    @State private var draft = ""

    private var currentReview: LibraryReview? {
        library.libraryReview(for: subject)
    }

    var body: some View {
        NavigationStack {
            SkinForm {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 150)
                        .onChange(of: draft) { _, value in
                            if value.count > LibraryReviewPreferences.maximumCommentLength {
                                draft = String(value.prefix(LibraryReviewPreferences.maximumCommentLength))
                            }
                        }
                } footer: {
                    Text(verbatim:
                        "\(draft.count)/\(LibraryReviewPreferences.maximumCommentLength)"
                    )
                    .monospacedDigit()
                }
            }
            .navigationTitle("library_review_comment_title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        library.updateLibraryReview(
                            for: subject,
                            rating: currentReview?.rating,
                            comment: draft
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { draft = currentReview?.comment ?? "" }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }
}
