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
}

#if os(iOS)
/// 详情页那层随封面变化的整页底色。
///
/// 封面主色不能直接铺满一页：饱和度高的封面会刺眼，亮封面上白字会糊。怎么压深由
/// `LibraryDetailTintPolicy` 定(规则在 PrimuseKit 里，有测试)，这里只把算好的两段
/// 颜色接成渐变。头图、列表、页尾共用同一条渐变，页面才是一整块，而不是彩色头顶
/// 着一块灰底。
struct LibraryDetailTintStyle: Equatable {
    var top: Color
    var bottom: Color

    /// 上半屏保持头图收尾的那个颜色, 过了头图才慢慢变深 —— 否则头图末端与页面底色
    /// 在接缝处差着一截, 反而多出一条边。
    var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: top, location: 0),
                .init(color: top, location: 0.42),
                .init(color: bottom, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 取不到封面色时的中性底。取色是异步的，颜色到位之前也先用它。
    static func neutral(colorScheme: ColorScheme) -> LibraryDetailTintStyle {
        style(LibraryDetailTintPolicy.neutralTint(appearance: appearance(for: colorScheme)))
    }

    /// - Parameter artworkColor: `CoverTintProvider` 取到的封面主色。
    static func artwork(_ artworkColor: Color?, colorScheme: ColorScheme) -> LibraryDetailTintStyle {
        guard let artworkColor, let components = artworkColor.hsbComponents else {
            return neutral(colorScheme: colorScheme)
        }
        return style(LibraryDetailTintPolicy.tint(
            hue: components.hue,
            saturation: components.saturation,
            brightness: components.brightness,
            appearance: appearance(for: colorScheme)
        ))
    }

    private static func appearance(
        for colorScheme: ColorScheme
    ) -> LibraryDetailTintPolicy.Appearance {
        colorScheme == .dark ? .dark : .light
    }

    private static func style(_ tint: LibraryDetailTint) -> LibraryDetailTintStyle {
        LibraryDetailTintStyle(top: color(tint.top), bottom: color(tint.bottom))
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

    private var style: LibraryDetailTintStyle {
        .artwork(song.flatMap { coverTints.tint(forSongID: $0.id) }, colorScheme: colorScheme)
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
    /// 是浮在页面上的一层，而不是另一块拼上去的白卡片。
    @ViewBuilder
    func libraryDetailSection(
        tint: LibraryDetailTintStyle?,
        cornerRadius: CGFloat = 16
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if tint == nil {
            background(Color(uiColor: .secondarySystemBackground), in: shape)
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

    @Environment(\.libraryDetailTint) private var tint
    @Environment(\.colorScheme) private var colorScheme

    init(
        @ViewBuilder header: @escaping (ImmersiveLibraryDetailInsets) -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let safeArea = geometry.safeAreaInsets
            let insets = ImmersiveLibraryDetailInsets(
                top: safeArea.top,
                leading: safeArea.leading,
                trailing: safeArea.trailing
            )
            // 头图要铺满整幅屏幕, 正文不能钻到灵动岛和圆角下面。所以整页在这里
            // 连左右安全区一起出血, 正文再把左右安全区按侧加回来 —— 头部自己
            // 拿 insets 消费, 底图就是唯一铺到边的那一层。
            let pageWidth = geometry.size.width + safeArea.leading + safeArea.trailing
            ScrollView {
                VStack(spacing: 0) {
                    header(insets)
                    content
                        .padding(.leading, safeArea.leading)
                        .padding(.trailing, safeArea.trailing)
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
        }
        .background {
            if let tint {
                tint.gradient.ignoresSafeArea()
            } else {
                Color(.systemGroupedBackground).ignoresSafeArea()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}
#endif

struct LibraryDetailActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var emphasized = false
    var onArtwork = true
    var fillsWidth = false
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
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(labelColor)
                .padding(.horizontal, 20)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 48)
                .background(fillColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

struct MediaDetailActionBar: View {
    let canPlay: Bool
    let canShuffle: Bool
    let playAction: () -> Void
    let shuffleAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: playAction) {
                Label("play_all", systemImage: "play.fill")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPlay)

            Button(action: shuffleAction) {
                Label("shuffle", systemImage: "shuffle")
                    .frame(minWidth: 112)
            }
            .buttonStyle(.bordered)
            .disabled(!canShuffle)

            #if os(macOS)
            // macOS 详情区按钮靠左,不撑满。
            Spacer(minLength: 0)
            #endif
        }
        .controlSize(.regular)
        .labelStyle(.titleAndIcon)
        #if os(iOS)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        #endif
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
            Form {
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
