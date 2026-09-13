#if os(tvOS)
import SwiftUI
import PrimuseKit
import UIKit

/// 单层输入框。tvOS 的 `TextField` / `SecureField` 自带一层胶囊底框,且**无法去掉**
/// (`.textFieldStyle(.plain)` 在 tvOS 上不生效),外面再画一层就成了「大框套小框」。
/// 所以这里不画任何底框,只做两件事:撑满外层宽度(相邻两格才不会一大一小),
/// 以及不覆盖字号——框高是系统按自身字号算的,换成自定义字号框内文字就会偏。
struct TVTextFieldBox<Field: View>: View {
    var mono: Bool = false
    @ViewBuilder var field: () -> Field

    var body: some View {
        // 只改字形不改字号:等宽字形便于看地址和端口,字号仍由系统决定。
        Group {
            if mono { field().monospaced() } else { field() }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 开关行。tvOS 的原生 `Toggle` 自己就是一枚满宽的绿色胶囊,外面再包一层
/// 自绘圆角底就成了「大框套椭圆框」;这里整行自绘,和设置页的开关保持一致。
struct TVSwitchRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    var maxWidth: CGFloat = 720

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: { isOn.toggle() }) { focused in
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isOn ? TVColor.brand : TVColor.textFaint)
                    .frame(width: 34)
                Text(title).tvFont(.caption, weight: .medium).foregroundStyle(TVColor.text)
                Spacer(minLength: 12)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surfaceStrong))
                        .frame(width: 62, height: 34)
                    Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                }
                .animation(.easeOut(duration: 0.18), value: isOn)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .accessibilityValue(Text(isOn
            ? PMString("ext.tv.sources.status.enabled")
            : PMString("ext.tv.sources.status.disabled")))
    }
}

struct TVLibraryReviewControl: View {
    @Environment(TVStore.self) private var store
    @AppStorage(LibraryReviewPreferences.enabledKey) private var isEnabled = false

    let subject: LibraryReviewSubject
    @State private var showsCommentEditor = false

    private var review: LibraryReview? {
        store.library.libraryReview(for: subject)
    }

    private var rating: Int { review?.rating ?? 0 }

    var body: some View {
        if isEnabled {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { value in
                        starButton(value)
                    }
                    commentButton
                }

                if let comment = review?.comment, !comment.isEmpty {
                    Text(verbatim: comment)
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textMuted)
                        .lineLimit(2)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
            .fullScreenCover(isPresented: $showsCommentEditor) {
                TVLibraryReviewCommentEditor(subject: subject)
                    .environment(store)
            }
        }
    }

    /// 用自绘焦点态代替 `.bordered`:tvOS 的系统按钮样式会盖一层白色平台层,
    /// 和这套暗色主题里的其它按钮长得完全不一样。
    private func starButton(_ value: Int) -> some View {
        let filled = value <= rating
        return TVFocusButton(radius: 12, scale: 1.06, lift: 0, action: {
            store.library.updateLibraryReview(
                for: subject,
                rating: value == review?.rating ? nil : value,
                comment: review?.comment ?? ""
            )
        }) { focused in
            Image(systemName: filled ? "star.fill" : "star")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(filled ? TVColor.warn : (focused ? TVColor.text : TVColor.textMuted))
                .frame(width: 54, height: 54)
                .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityLabel(
            Text(String(format: String(localized: "library_review_star_format"), value))
        )
        .accessibilityAddTraits(filled ? [.isButton, .isSelected] : .isButton)
    }

    private var commentButton: some View {
        let hasComment = review?.comment.isEmpty == false
        return TVFocusButton(radius: 12, scale: 1.06, lift: 0, action: { showsCommentEditor = true }) { focused in
            Image(systemName: hasComment ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(hasComment ? TVColor.brand : (focused ? TVColor.text : TVColor.textMuted))
                .frame(width: 54, height: 54)
                .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityLabel(
            Text(hasComment ? "library_review_edit_comment" : "library_review_add_comment")
        )
    }
}

/// 评论编辑弹框。原先用 `NavigationStack` + `Form`,是这套 tvOS 界面里唯一一处
/// iOS 风格的系统表单;改成和其它覆层一致的「氛围底 + 居中面板」,输入框也按同一
/// 规则处理(标题在框外、占位串留空、撑满列宽)。
private struct TVLibraryReviewCommentEditor: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let subject: LibraryReviewSubject
    @State private var draft = ""
    @FocusState private var inputActive: Bool

    private var currentReview: LibraryReview? {
        store.library.libraryReview(for: subject)
    }

    private var limit: Int { LibraryReviewPreferences.maximumCommentLength }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            card
                .padding(.horizontal, 90)
                .padding(.vertical, 60)
        }
        .onAppear {
            draft = currentReview?.comment ?? ""
            inputActive = true
        }
        .onExitCommand { dismiss() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "library_review_comment_title"))
                .tvFont(.pageTitle)
                .foregroundStyle(TVColor.text)
            Rectangle().fill(TVColor.divider)
                .frame(height: 1)
                .padding(.top, 26).padding(.bottom, 28)

            HStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(inputActive ? TVColor.brand : TVColor.textFaint)
                    .frame(width: 26)
                Text(String(localized: "library_review_comment_title"))
                    .tvFont(.caption)
                    .foregroundStyle(inputActive ? TVColor.text : TVColor.textFaint)
                Spacer(minLength: 0)
                Text(verbatim: "\(draft.count)/\(limit)")
                    .tvFont(.caption, design: .monospaced)
                    .foregroundStyle(draft.count >= limit ? TVColor.warn : TVColor.textFaint)
            }
            .padding(.bottom, 10)

            TVTextFieldBox {
                TextField("", text: $draft)
                    .focused($inputActive)
                    .accessibilityLabel(Text("library_review_comment_title"))
                    .onChange(of: draft) { _, value in
                        if value.count > limit {
                            draft = String(value.prefix(limit))
                        }
                    }
            }

            HStack(spacing: 16) {
                TVFocusButton(radius: 14, accent: TVColor.brand, scale: 1.02, lift: 0, action: save) { focused in
                    Text(String(localized: "save"))
                        .tvFont(.button)
                        .foregroundStyle(TVColor.onBrand)
                        .padding(.horizontal, 30).padding(.vertical, 16)
                        .frame(minWidth: 220)
                        .background(TVColor.brand.opacity(focused ? 1 : 0.85),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Spacer(minLength: 0)
                TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: { dismiss() }) { focused in
                    Text(String(localized: "cancel"))
                        .tvFont(.button)
                        .foregroundStyle(TVColor.text)
                        .padding(.horizontal, 26).padding(.vertical, 16)
                        .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.top, 32)
        }
        .padding(.horizontal, 64).padding(.vertical, 52)
        .frame(maxWidth: 1080, alignment: .leading)
        .tvPanel(radius: 26)
    }

    private func save() {
        store.library.updateLibraryReview(
            for: subject,
            rating: currentReview?.rating,
            comment: draft
        )
        dismiss()
    }
}

// MARK: - 横向区块(Apple Music tvOS shelf 风)

struct TVRow<Content: View>: View {
    let label: String
    var sub: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label).tvFont(.sectionTitle).foregroundStyle(TVColor.text)
                if let sub { Text(sub).tvFont(.caption).foregroundStyle(TVColor.textFaint) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 28) { content() }
                    // 为首尾卡片的焦点描边和放大保留空间。
                    .padding(.vertical, 30)
                    .padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - 专辑卡片

struct TVAlbumCard: View {
    let album: TVAlbum
    var width: CGFloat = 240
    var titleOverride: String? = nil
    var subtitleOverride: String? = nil
    var action: () -> Void = {}
    @Environment(TVStore.self) private var store

    var body: some View {
        TVFocusButton(ring: false,
                      action: { store.play(album: album); action() }) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVArtworkView(album: album, size: width)
                    .tvFocusRing(focused, radius: TVRadius.cover, scale: 1.04, lift: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(titleOverride ?? album.title)
                        .tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text).lineLimit(2, reservesSpace: true)
                    Text(subtitleOverride ?? album.artist)
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                .padding(.top, 12).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityLabel(Text(titleOverride ?? album.title))
        .accessibilityValue(Text(subtitleOverride ?? album.artist))
    }
}

// MARK: - 歌曲卡片(用所属专辑封面)

struct TVSongCard: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    var width: CGFloat = 240
    var reason: String? = nil
    var action: () -> Void = {}

    var body: some View {
        let album = store.albumOf(song)
        TVFocusButton(ring: false,
                      action: { store.play(song); action() }) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", songID: song.id, coverRef: song.coverRef,
                              tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: width)
                    .tvFocusRing(focused, radius: TVRadius.cover, scale: 1.04, lift: 0)
                VStack(alignment: .leading, spacing: 6) {
                    if let reason {
                        Label(reason, systemImage: "sparkles")
                            .tvFont(.caption, weight: .semibold)
                            .foregroundStyle(TVColor.brand)
                            .lineLimit(1, reservesSpace: true)
                            .opacity(reason.isEmpty ? 0 : 1)
                    }
                    Text(song.title).tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text).lineLimit(2, reservesSpace: true)
                    Text(song.artist).tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                .padding(.top, 12).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

// MARK: - 电台卡片

struct TVRadioStationCard: View {
    @Environment(TVStore.self) private var store
    let station: RadioStation
    var width: CGFloat = 220
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(ring: false,
                      action: {
                          TVSiriMediaInteractionDonor.donate(station: station)
                          store.play(station)
                          action()
                      }) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVRadioArtworkView(station: station, size: width, radius: TVRadius.cover)
                    .tvFocusRing(focused, radius: TVRadius.cover, scale: 1.04, lift: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(station.name)
                        .tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2, reservesSpace: true)
                    Text(station.playbackSubtitle)
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(1)
                }
                .padding(.top, 12)
                .padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

struct TVRadioArtworkView: View {
    let station: RadioStation
    let size: CGFloat
    var radius: CGFloat = TVRadius.cover

    @State private var logo: UIImage?

    private var logoIdentity: Int { station.logoData?.hashValue ?? 0 }

    var body: some View {
        Group {
            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFill()
            } else {
                TVRadioPlaceholderArtwork()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(TVColor.cardBorder, lineWidth: 1)
        }
        .task(id: logoIdentity) {
            let identity = logoIdentity
            guard let data = station.logoData else {
                logo = nil
                return
            }
            let decoded = await Task.detached(priority: .utility) {
                UIImage(data: data)
            }.value
            guard !Task.isCancelled, identity == logoIdentity else { return }
            logo = decoded
        }
    }
}

private struct TVRadioPlaceholderArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height), 1)

            ZStack {
                TVColor.brandSecondary

                LinearGradient(
                    colors: [TVColor.brand.opacity(0.84), TVColor.brand.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .stroke(.white.opacity(0.10), lineWidth: max(1, side * 0.008))
                    .frame(width: side * 0.82, height: side * 0.82)

                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: max(1, side * 0.009))
                    .frame(width: side * 0.58, height: side * 0.58)

                Image(systemName: "radio.fill")
                    .font(.system(size: side * 0.31, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 艺术家卡片(圆形)

struct TVArtistCard: View {
    let artist: TVArtist
    var size: CGFloat = 180
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(ring: false, action: action) { focused in
            VStack(spacing: 12) {
                TVArtistArtworkView(artist: artist, size: size)
                    .tvFocusRing(focused, radius: size / 2, scale: 1.04, lift: 0)
                Text(artist.name).tvFont(.cardTitle)
                    .foregroundStyle(TVColor.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: size + 32)
            }
        }
        .accessibilityLabel(Text(artist.name))
        .accessibilityValue(Text(PMString("ext.tv.search.artistMeta", artist.songCount)))
    }
}

// MARK: - 空态

struct TVEmptyState: View {
    let icon: String
    let title: String
    var subtitle: String = PMString("ext.tv.components.emptySubtitle")
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 80)).foregroundStyle(TVColor.textGhost)
            Text(title).tvFont(.sectionTitle).foregroundStyle(TVColor.text)
            if !subtitle.isEmpty {
                Text(subtitle).tvFont(.caption).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: 720)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 胶囊按钮(播放 / 随机 / 喜欢)

struct TVPillButton: View {
    enum Style { case solid, glass }
    let title: String
    let systemImage: String
    var style: Style = .glass
    var isSelected = false
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.04, lift: 6, action: action) { _ in
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 22, weight: .semibold))
                Text(title).tvFont(.button, weight: style == .solid ? .bold : .semibold)
                    .lineLimit(1)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .foregroundStyle(style == .solid ? TVColor.onBrand : TVColor.text)
            .background(style == .solid ? AnyShapeStyle(TVColor.brand)
                                        : AnyShapeStyle(TVColor.surfaceStrong))
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

enum TVRemoteTransportCommand: Equatable {
    case togglePlayback
    case nextTrack
    case seek
}

struct TVRemoteTransportModifier: ViewModifier {
    var shortcutsEnabled: Bool
    var onCommand: (TVRemoteTransportCommand) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var assistiveNavigation = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning

    private var capturesPresses: Bool {
        shortcutsEnabled && isVisible && scenePhase == .active && !assistiveNavigation
    }

    func body(content: Content) -> some View {
        content
            .background {
                TVRemoteTransportBridge(enabled: capturesPresses, onCommand: onCommand)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .onPlayPauseCommand {
                // The UIKit recognizers arbitrate single/double/long presses.
                // Keep the native single-press route when shortcuts are unavailable.
                if !capturesPresses { onCommand(.togglePlayback) }
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
                refreshAssistiveNavigation()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.switchControlStatusDidChangeNotification)) { _ in
                refreshAssistiveNavigation()
            }
    }

    private func refreshAssistiveNavigation() {
        assistiveNavigation = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }
}

private struct TVRemoteTransportBridge: UIViewRepresentable {
    let enabled: Bool
    let onCommand: (TVRemoteTransportCommand) -> Void

    func makeCoordinator() -> TVRemoteTransportCoordinator { TVRemoteTransportCoordinator() }

    func makeUIView(context: Context) -> TVRemoteTransportAnchor {
        let view = TVRemoteTransportAnchor()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: TVRemoteTransportAnchor, context: Context) {
        context.coordinator.configure(enabled: enabled, onCommand: onCommand)
        view.attachToHostingView()
    }

    static func dismantleUIView(_ view: TVRemoteTransportAnchor, coordinator: TVRemoteTransportCoordinator) {
        coordinator.detach()
    }
}

private final class TVRemoteTransportAnchor: UIView {
    weak var coordinator: TVRemoteTransportCoordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachToHostingView()
    }

    func attachToHostingView() {
        guard window != nil else { coordinator?.detach(); return }
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController {
                // The hosting view contains the focused controls. An invisible
                // background view does not receive their remote presses.
                coordinator?.attach(to: controller)
                return
            }
            responder = current.next
        }
    }
}

@MainActor
final class TVRemoteTransportCoordinator: NSObject, UIGestureRecognizerDelegate {
    private(set) var enabled = false
    private weak var controller: UIViewController?
    private var onCommand: (TVRemoteTransportCommand) -> Void = { _ in }
    private(set) lazy var singlePress = UITapGestureRecognizer(target: self, action: #selector(singlePressed))
    private(set) lazy var doublePress = UITapGestureRecognizer(target: self, action: #selector(doublePressed))
    private(set) lazy var longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))

    override init() {
        super.init()
        doublePress.numberOfTapsRequired = 2
        longPress.minimumPressDuration = 0.7
        for gesture in recognizers {
            gesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
            gesture.allowedTouchTypes = []
            gesture.delaysTouchesBegan = true
            gesture.cancelsTouchesInView = true
            gesture.delegate = self
            gesture.isEnabled = false
        }
        singlePress.require(toFail: doublePress)
        singlePress.require(toFail: longPress)
        doublePress.require(toFail: longPress)
    }

    private var recognizers: [UIGestureRecognizer] { [singlePress, doublePress, longPress] }

    func configure(enabled: Bool, onCommand: @escaping (TVRemoteTransportCommand) -> Void) {
        self.onCommand = onCommand
        self.enabled = enabled
        for gesture in recognizers { gesture.isEnabled = enabled && controller != nil }
    }

    func attach(to controller: UIViewController) {
        guard self.controller !== controller else { return }
        detach()
        self.controller = controller
        for gesture in recognizers {
            controller.view.addGestureRecognizer(gesture)
            gesture.isEnabled = enabled
        }
    }

    func detach() {
        for gesture in recognizers {
            gesture.isEnabled = false
            gesture.view?.removeGestureRecognizer(gesture)
        }
        controller = nil
    }

    private var canHandleCommand: Bool {
        guard enabled, let controller,
              controller.isViewLoaded, controller.view.window != nil,
              !controller.isBeingDismissed, controller.presentedViewController == nil,
              !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning else { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        canHandleCommand && press.type == .playPause
    }

    func perform(_ command: TVRemoteTransportCommand) {
        guard canHandleCommand else { return }
        onCommand(command)
    }

    @objc private func singlePressed(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        perform(.togglePlayback)
    }

    @objc private func doublePressed(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        perform(.nextTrack)
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        perform(.seek)
    }
}
#endif
