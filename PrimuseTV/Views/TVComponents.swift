#if os(tvOS)
import SwiftUI
import PrimuseKit
import UIKit

// MARK: - 弹层收起后换页

/// 全屏弹层(专辑页、艺人页、文件夹、有声书、播客节目)里开始播放,弹层收起后才切到播放页。
///
/// 弹层收起时 UIKit 要把焦点送回下面那一页里打开它的卡片,这次焦点更新排在下一次 CA 提交
/// 之后才做。要是同一拍里就把整页换成播放页,焦点系统量那张卡片的位置时 SwiftUI 会先把
/// 没提交的换页做掉,卡片在焦点更新进行到一半时被拆掉,UIKit 断言
/// `_focusEnvironmentWillDisappear` 直接闪退(91、101 两份闪退样本都是这条栈)。
/// 所以等焦点落定 —— 收到一次焦点更新完成的通知 —— 再换页;通知一直不来就按时限换。
@MainActor
enum TVModalHandoff {
    static func afterFocusSettles(
        timeout: Duration = .milliseconds(300),
        _ action: @escaping () -> Void
    ) {
        let pending = Pending(action)
        pending.observer = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { pending.finish(via: "focus") }
        }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            pending.finish(via: "timeout")
        }
    }

    @MainActor
    private final class Pending {
        var observer: NSObjectProtocol?
        private var action: (() -> Void)?
        #if DEBUG
        private let startedAt = Date()
        #endif

        init(_ action: @escaping () -> Void) {
            self.action = action
        }

        func finish(via reason: String) {
            guard let action else { return }
            self.action = nil
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            #if DEBUG
            plog("TV modal handoff via=\(reason) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            #endif
            // 通知是那次焦点更新收尾时发的,还在它的调用栈里;换页再让一拍。
            Task { @MainActor in action() }
        }
    }
}

/// 单层输入框。tvOS 的 `TextField` / `SecureField` 自带一层胶囊底框,且**无法去掉**
/// (`.textFieldStyle(.plain)` 在 tvOS 上不生效),外面再画一层就成了「大框套小框」。
/// 所以这里不画底框,只统一三件事:宽度撑满、字号固定、行高有下限。
///
/// 字号必须由我们定死:交给系统决定时,同一个表单里相邻两格会出现一格约 40pt、
/// 另一格约 20pt 的情况(主机很大、端口很小),两处调用的代码完全一样也复现。
/// 与其继续追系统那套内在尺寸,不如把字号和行高都固定下来,相邻输入框由构造方式
/// 保证一致。行高取字号的 2 倍,保证胶囊底框不会紧贴文字、内容仍然上下居中。
struct TVTextFieldBox<Field: View>: View {
    var mono: Bool = false
    @ViewBuilder var field: () -> Field

    @ScaledMetric(wrappedValue: TVFont.input.size, relativeTo: .body) private var fontSize: CGFloat

    var body: some View {
        field()
            .font(.system(size: fontSize, weight: .regular, design: mono ? .monospaced : .default))
            .frame(maxWidth: .infinity, minHeight: fontSize * 2, alignment: .leading)
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
    /// 卡片要各自联网取图的行(播客单集)打开:只建出看得见的卡片,不然整排一起开始下载,
    /// 慢网络上屏幕里那几张反而排在后面。
    var loadsLazily = false
    /// 标题上面压一道细线(首页排成杂志版面时,一排一个栏目)。
    var rule = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if rule {
                Rectangle()
                    .fill(TVColor.text.opacity(0.18))
                    .frame(height: 1)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label).tvFont(.sectionTitle).foregroundStyle(TVColor.text)
                if let sub { Text(sub).tvFont(.caption).foregroundStyle(TVColor.textFaint) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if loadsLazily {
                        LazyHStack(alignment: .top, spacing: 28) { content() }
                    } else {
                        HStack(alignment: .top, spacing: 28) { content() }
                    }
                }
                // 为首尾卡片的焦点描边和放大保留空间。
                .padding(.vertical, 30)
                .padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - 专辑卡片

/// 要从这台 Apple TV 的曲库里移除的一张专辑或一首歌。
struct TVLibraryRemovalRequest: Equatable {
    let title: String
    let songIDs: [String]
}

/// 移除前先确认:只动这台 Apple TV 的曲库,网盘、服务器上的文件不动。
struct TVLibraryRemovalConfirmation: ViewModifier {
    @Environment(TVStore.self) private var store
    @Binding var request: TVLibraryRemovalRequest?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            String(
                format: String(localized: "tv_remove_from_device_confirm_title_format"),
                request?.title ?? ""
            ),
            isPresented: Binding(
                get: { request != nil },
                set: { if !$0 { request = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("song_remove_from_device", role: .destructive) {
                if let request { store.removeSongsFromThisDevice(request.songIDs) }
                request = nil
            }
            Button("cancel", role: .cancel) { request = nil }
        } message: {
            Text("tv_remove_from_device_confirm_message")
        }
    }
}

struct TVAlbumCard: View {
    @State private var pendingMedleyIDs: [String]?
    @State private var pendingRemoval: TVLibraryRemovalRequest?
    /// 按下打开专辑页时那一下「掀开 CD 盒」(见 `TVJewelCaseMotion`)。
    @State private var casePhase = CasePhase.closed
    @State private var openingTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: TVAlbum
    var width: CGFloat = 240
    var titleOverride: String? = nil
    var subtitleOverride: String? = nil
    /// 开始播放之后调用(一般是切到播放页)。
    var action: () -> Void = {}
    var onFocusChanged: (Bool) -> Void = { _ in }
    /// 给了就由按下封面打开专辑页(先看曲目再点歌),整张播放挪进长按菜单;
    /// 不给则保持按下即播放整张专辑。
    var onOpen: (() -> Void)? = nil
    /// 父视图的焦点绑定(见 `TVFocusButton`):回到资料库时把焦点放回上次那张卡片。
    var focusBinding: FocusState<String?>.Binding? = nil
    var focusID: String? = nil
    @Environment(TVStore.self) private var store

    /// closed:平时;ready:盒子里面刚建好、盖子还合着;open:盖子掀开、盘滑出来。
    private enum CasePhase { case closed, ready, open }

    var body: some View {
        TVFocusButton(ring: false,
                      action: {
                          if let onOpen {
                              openCase(then: onOpen)
                          } else {
                              store.play(album: album)
                              action()
                          }
                      },
                      onFocusChanged: onFocusChanged,
                      focusBinding: focusBinding,
                      focusID: focusID) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVArtworkView(album: album, size: width)
                    .overlay {
                        Color.black.opacity(casePhase == .open ? TVJewelCaseMotion.lidShade : 0)
                    }
                    .tvCardFocus(focused, radius: TVRadius.cover)
                    // 封面就是盒盖:铰链在左边,掀开时右沿朝人转过来,露出底下的盒子和盘。
                    .rotation3DEffect(
                        .degrees(casePhase == .open ? TVJewelCaseMotion.lidAngle : 0),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .leading,
                        perspective: TVJewelCaseMotion.lidPerspective
                    )
                    .animation(TVJewelCaseMotion.lid, value: casePhase)
                    .background {
                        if casePhase != .closed {
                            TVJewelCaseInterior(
                                album: album,
                                size: width,
                                discOut: casePhase == .open,
                                discFace: TVAlbumDiscArtwork.cachedFace(forAlbumID: album.id)
                            )
                        }
                    }
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
        .contextMenu {
            if onOpen != nil {
                // 整张播放:按碟号、曲目号排队,不管当前开没开随机。
                Button("album_play_whole", systemImage: "play.fill") {
                    guard store.playResolvedQueue(
                        songIDs: store.songIDs(forAlbum: album.id),
                        shuffled: false
                    ) else { return }
                    action()
                }
                Button("shuffle", systemImage: "shuffle") {
                    guard store.playResolvedQueue(
                        songIDs: store.songIDs(forAlbum: album.id),
                        shuffled: true
                    ) else { return }
                    action()
                }
            }
            Button("medley_play_selection", systemImage: "shuffle") {
                pendingMedleyIDs = store.songIDs(forAlbum: album.id)
            }
            .disabled(!store.canPlayMedley(songIDs: store.songIDs(forAlbum: album.id)))
            Button("song_remove_from_device", systemImage: "minus.circle", role: .destructive) {
                pendingRemoval = TVLibraryRemovalRequest(
                    title: titleOverride ?? album.title,
                    songIDs: store.songIDs(forAlbum: album.id)
                )
            }
        }
        .modifier(TVMedleyConfirmation(pendingIDs: $pendingMedleyIDs, onStarted: action))
        .modifier(TVLibraryRemovalConfirmation(request: $pendingRemoval))
        .accessibilityLabel(Text(titleOverride ?? album.title))
        .accessibilityValue(Text(subtitleOverride ?? album.artist))
        // 掀开的盖子会伸到左边那张卡片上面。
        .zIndex(casePhase == .closed ? 0 : 2)
        .onDisappear {
            openingTask?.cancel()
            openingTask = nil
            casePhase = .closed
        }
    }

    /// 先掀开盒子再打开专辑页;专辑页盖住以后悄悄合上,回来时卡片还是原样。
    /// 「减弱动态效果」打开时直接打开。掀开的那一下再按不会重复打开。
    private func openCase(then onOpen: @escaping () -> Void) {
        guard openingTask == nil else { return }
        guard !reduceMotion else {
            onOpen()
            return
        }
        openingTask = Task { @MainActor in
            defer { openingTask = nil }
            // 先在合着的盖子底下建好盒子和盘,下一帧再掀,盘才有滑出来的过程。
            casePhase = .ready
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            casePhase = .open
            try? await Task.sleep(for: TVJewelCaseMotion.handoff)
            guard !Task.isCancelled else { return }
            #if DEBUG
            // 截图用:TV_DEBUG_CASE_OPEN=1 让盒子停在掀开的样子,不进专辑页。
            if ProcessInfo.processInfo.environment["TV_DEBUG_CASE_OPEN"] == "1" { return }
            #endif
            onOpen()
            try? await Task.sleep(for: .milliseconds(900))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { casePhase = .closed }
        }
    }
}

// MARK: - 歌曲卡片(用所属专辑封面)

struct TVSongCard: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    var ordinal: Int? = nil
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
                    .tvCardFocus(focused, radius: TVRadius.cover)
                VStack(alignment: .leading, spacing: 6) {
                    if let reason {
                        Label(reason, systemImage: "sparkles")
                            .tvFont(.caption, weight: .semibold)
                            .foregroundStyle(TVColor.brand)
                            .lineLimit(1, reservesSpace: true)
                            .opacity(reason.isEmpty ? 0 : 1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let ordinal {
                            TVSongOrdinal(number: ordinal, largestNumber: ordinal)
                        }
                        Text(verbatim: song.title).tvFont(.cardTitle)
                            .foregroundStyle(TVColor.text).lineLimit(2, reservesSpace: true)
                    }
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
    /// 卡片所在那一排 / 那一格实际显示的台(首页只放前几个,资料库可能按文件夹筛过)。
    /// 长按菜单的首尾判断和挪动都只在它们之间算;不给就按电视上的全部电台。
    var siblingIDs: [String]? = nil
    /// 持有这一排卡片的父视图的焦点绑定(按电台 id),删除后由父视图把焦点交给邻居。
    var focusBinding: FocusState<String?>.Binding? = nil
    /// 长按「删除」:确认弹层由持有这一排的父视图弹(`TVRadioDeleteConfirmationHost`)。
    /// 确认后这张卡片就不在了,挂在卡片自己身上的弹层没人接得住焦点。
    let onDelete: (RadioStation) -> Void
    /// 重命名面板弹出 / 关闭。只报给 TVRoot 登记,关闭后系统自己把焦点还给这张卡片。
    var onModalPresentationChanged: (Bool) -> Void = { _ in }
    var onFocusChanged: (Bool) -> Void = { _ in }
    var action: () -> Void = {}
    @State private var showsRename = false

    private var isFirstInRow: Bool {
        guard let siblingIDs else { return store.radioStations.first?.id == station.id }
        return siblingIDs.first == station.id
    }

    private var isLastInRow: Bool {
        guard let siblingIDs else { return store.radioStations.last?.id == station.id }
        return siblingIDs.last == station.id
    }

    var body: some View {
        TVFocusButton(
            ring: false, action: play, onFocusChanged: onFocusChanged,
            focusBinding: focusBinding, focusID: station.id
        ) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVRadioArtworkView(station: station, size: width, radius: TVRadius.cover, store: store)
                    .tvCardFocus(focused, radius: TVRadius.cover)
                VStack(alignment: .leading, spacing: 6) {
                    Text(station.name)
                        .tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2, reservesSpace: true)
                    Text(station.tvPlaybackSubtitle)
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
        // 长按:音乐源镜像的台由服务端管理,只给播放。
        .contextMenu {
            Button(action: play) {
                Label(PMString("ext.tv.radio.play"), systemImage: "play.fill")
            }
            if store.canManageRadioStation(station) {
                // 首页那排最后一张卡不给「向后移」:挪出前几个就不在首页了,焦点会掉回顶栏。
                let isFirst = isFirstInRow
                let isLast = isLastInRow
                if !isFirst {
                    Button {
                        store.moveRadioStation(id: station.id, by: -1, within: siblingIDs)
                    } label: {
                        Label(PMString("ext.tv.radio.moveEarlier"), systemImage: "arrow.backward")
                    }
                }
                if !isLast {
                    Button {
                        store.moveRadioStation(id: station.id, by: 1, within: siblingIDs)
                    } label: {
                        Label(PMString("ext.tv.radio.moveLater"), systemImage: "arrow.forward")
                    }
                }
                if !isFirst {
                    Button {
                        store.moveRadioStationToTop(id: station.id, within: siblingIDs)
                    } label: {
                        Label(PMString("ext.tv.radio.moveToTop"), systemImage: "arrow.up.to.line")
                    }
                }
                // 订阅来的台名字归清单管,改了下次刷新也会被还原。
                if !station.isSubscribed {
                    Button {
                        showsRename = true
                    } label: {
                        Label(PMString("ext.tv.radio.rename"), systemImage: "pencil")
                    }
                }
                Button(role: .destructive) {
                    onDelete(station)
                } label: {
                    Label(PMString("ext.tv.radio.delete"), systemImage: "trash")
                }
            }
        }
        .fullScreenCover(isPresented: $showsRename) {
            TVRadioRenameView(station: station)
                .environment(store)
        }
        .onChange(of: showsRename) { _, shows in onModalPresentationChanged(shows) }
        .onDisappear {
            if showsRename { onModalPresentationChanged(false) }
        }
    }

    private func play() {
        TVSiriMediaInteractionDonor.donate(station: station)
        store.play(station)
        action()
    }
}

struct TVRadioArtworkView: View {
    let station: RadioStation
    let size: CGFloat
    var radius: CGFloat = TVRadius.cover
    /// 按值传入,不读 `@Environment`:这个视图挂在带 `.contextMenu` 的按钮 label 里,
    /// 那种位置可能被系统挪到独立的宿主里渲染,读环境对象会直接崩。
    let store: TVStore

    @State private var logo: UIImage?

    /// 缩略图的目标像素(电视 4K 是 2 倍屏)。
    private var pixelSize: Int { max(1, Int((size * 2).rounded(.up))) }

    /// 台标来源、音乐源与凭据、显示尺寸任何一样变了都重新取图:冷启动后凭据才到、
    /// 在电视上改了凭据,占位卡片不用重建就会补上台标。普通电台和没有封面引用的
    /// 镜像台指纹恒为 0,不观察音乐源相关的状态。
    private var loadKey: Int {
        var hasher = Hasher()
        hasher.combine(TVRadioLogoLoader.identity(for: station))
        hasher.combine(store.radioLogoSourceFingerprint(for: station))
        hasher.combine(pixelSize)
        return hasher.finalize()
    }

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
        // 换 key 时 `.task(id:)` 会取消旧任务,过期结果靠 `Task.isCancelled` 丢弃。
        .task(id: loadKey) {
            let targetPixels = pixelSize
            let data = await TVRadioLogoLoader.data(for: station) { [store] id in
                store.radioLogoSourceContext(sourceID: id)
            }
            guard !Task.isCancelled else { return }
            guard let data else {
                logo = nil
                return
            }
            let decoded = await Task.detached(priority: .utility) {
                TVRadioLogoLoader.thumbnail(from: data, maxPixelSize: targetPixels)
            }.value
            guard !Task.isCancelled else { return }
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
    var onFocusChanged: (Bool) -> Void = { _ in }
    /// 父视图的焦点绑定(见 `TVFocusButton`):回到资料库时把焦点放回上次那张卡片。
    var focusBinding: FocusState<String?>.Binding? = nil
    var focusID: String? = nil

    var body: some View {
        TVFocusButton(ring: false, action: action, onFocusChanged: onFocusChanged,
                      focusBinding: focusBinding, focusID: focusID) { focused in
            VStack(spacing: 12) {
                TVArtistArtworkView(artist: artist, size: size)
                    .tvCardFocus(focused, radius: size / 2)
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
    var actionTitle: String? = nil
    var actionIcon: String = "plus"
    /// 操作按钮的外部焦点绑定(见 `TVFocusButton`):整页换成空态后,父视图还能把焦点放到这颗按钮上。
    var focusBinding: FocusState<String?>.Binding? = nil
    var focusID: String? = nil
    var action: () -> Void = {}
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 80)).foregroundStyle(TVColor.textGhost)
            Text(title).tvFont(.sectionTitle).foregroundStyle(TVColor.text)
            if !subtitle.isEmpty {
                Text(subtitle).tvFont(.caption).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: 720)
            }
            if let actionTitle {
                TVPillButton(
                    title: actionTitle,
                    systemImage: actionIcon,
                    style: .solid,
                    focusBinding: focusBinding,
                    focusID: focusID,
                    action: action
                )
                .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 胶囊按钮(播放 / 随机 / 喜欢)

/// 页面顶部筛选行的一颗胶囊(资料库的专辑 / 歌曲 / 艺人…、电台的全部 / 文件夹…)。
/// 只管外观,焦点由外面的按钮决定:资料库用自己的 `@FocusState` 路由筛选行,
/// 电台用 `TVFocusButton`(删台后要把焦点交给「添加」)。两页的筛选行因此一样大。
struct TVFilterChipLabel: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var isFocused = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .tvFont(.caption, weight: isSelected ? .semibold : .regular)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 64)
            .padding(.horizontal, 18)
            // 焦点反白优先于「选中」的主题色:选中的那颗本身就带色,只靠描边看不出焦点在不在它上面。
            .foregroundStyle(isFocused ? TVColor.onFocusFill : (isSelected ? TVColor.onBrand : TVColor.text))
            .background(isFocused ? TVColor.focusFill : (isSelected ? TVColor.brand : TVColor.card),
                        in: .rect(cornerRadius: 14))
            .tvFocusRing(isFocused, radius: 14, scale: 1.04, lift: 0)
    }
}

struct TVPillButton: View {
    enum Style { case solid, glass }
    let title: String
    let systemImage: String
    var style: Style = .glass
    var isSelected = false
    /// 父视图的焦点绑定(见 `TVFocusButton`)。
    var focusBinding: FocusState<String?>.Binding? = nil
    var focusID: String? = nil
    var action: () -> Void = {}
    /// 外面挂了 `.disabled` 时系统不再让它获得焦点,外观也要跟着变成不可用:
    /// 否则一颗看着能点的实心按钮会被方向键直接跳过。写法与音乐源表单的提交按钮一致。
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        TVFocusButton(
            radius: 14, scale: 1.04, lift: 6, action: action,
            focusBinding: focusBinding, focusID: focusID
        ) { focused in
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 22, weight: .semibold))
                Text(title).tvFont(.button, weight: style == .solid ? .bold : .semibold)
                    .lineLimit(1)
                    // 窄面板里一颗长文案的按钮自己就比一行宽时，先把字缩一点再考虑截断。
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .foregroundStyle(foreground(focused: focused))
            .background(background(focused: focused))
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// 获得焦点时反白(实心的主按钮也一样),一排按钮里一眼看出停在哪颗上。
    private func foreground(focused: Bool) -> Color {
        guard isEnabled else { return TVColor.textGhost }
        if focused { return TVColor.onFocusFill }
        return style == .solid ? TVColor.onBrand : TVColor.text
    }

    private func background(focused: Bool) -> AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(TVColor.surface) }
        if focused { return AnyShapeStyle(TVColor.focusFill) }
        return style == .solid ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surfaceStrong)
    }
}

/// 专辑 / 艺人页的「喜欢」：只放一颗心，和旁边的药丸按钮同高同底色。
struct TVFavoriteIconButton: View {
    let isLiked: Bool
    let action: () -> Void

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.04, lift: 6, action: action) { focused in
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isLiked ? TVColor.brand : (focused ? TVColor.onFocusFill : TVColor.text))
                .frame(width: 36, height: 36)
                .padding(18)
                .background(focused ? TVColor.focusFill : TVColor.surfaceStrong)
        }
        .accessibilityLabel(Text(isLiked ? "library_favorite_unlike" : "library_favorite_like"))
        .accessibilityAddTraits(isLiked ? [.isButton, .isSelected] : .isButton)
    }
}

/// 一排药丸按钮：各按完整宽度从左往右排，这一行放不下就折到下一行。德语这类长文案、
/// 或者本来就窄的左栏里，按钮换行，而不是把字截成「Alle wiederg…」。
struct TVButtonFlow: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Item {
        var index: Int
        var size: CGSize
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width {
                // 一颗按钮自己就比一行宽：只给一行的宽度，字按 minimumScaleFactor 缩。
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if !current.items.isEmpty, current.width + spacing + size.width > width {
                lines.append(current)
                current = Line()
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append(Item(index: index, size: size))
        }
        if !current.items.isEmpty { lines.append(current) }
        return lines
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

/// 从播放页回来重开的详情页、或刚重建的页面:把焦点放到记住的那一项。覆盖层呈现完、
/// 那一行建出来之前设的焦点会被丢掉,没落上就隔一会儿再设(机器忙、刚换了语言时呈现会慢,
/// 模拟器上实测过一秒半还没呈现完),最多等三秒多;落上一次就停,不再跟用户抢焦点。
private struct TVFocusRestore: ViewModifier {
    let target: String?
    let binding: FocusState<String?>.Binding
    let reveal: () -> Void
    let onSettled: () -> Void

    func body(content: Content) -> some View {
        content.task(id: target) {
            guard let target else { return }
            for attempt in 0..<8 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 350_000_000 : 300_000_000)
                guard !Task.isCancelled else { return }
                // 懒加载的列表只为看得见的那一段建视图:那一行在屏幕外时先滚过去,它才存在、焦点才放得上。
                reveal()
                try? await Task.sleep(nanoseconds: 50_000_000)
                binding.wrappedValue = target
                try? await Task.sleep(nanoseconds: 150_000_000)
                if binding.wrappedValue == target { break }
            }
            guard !Task.isCancelled else { return }
            #if DEBUG
            plog("TV focus restore target=\(target) result=\(binding.wrappedValue == target ? "ok" : "missed")")
            #endif
            onSettled()
        }
    }
}

extension View {
    /// 见 `TVFocusRestore`。`target` 为 nil 时什么也不做;放完(或等不到那一行)调 `onSettled`,
    /// 一次性的落点在这里清掉,免得那一行以后重建时又把焦点拽回去。
    /// `reveal`:把那一行滚进可见范围(滚动容器的 `ScrollViewProxy.scrollTo`),每次设焦点前调。
    func tvRestoresFocus(
        to target: String?,
        in binding: FocusState<String?>.Binding,
        reveal: @escaping () -> Void = {},
        onSettled: @escaping () -> Void = {}
    ) -> some View {
        modifier(TVFocusRestore(target: target, binding: binding, reveal: reveal, onSettled: onSettled))
    }
}

/// Apple TV 长列表的分页容器。
///
/// 遥控器只能一行一行挪焦点,所以一次把整份列表交给 `ForEach` 没有任何收益:
/// 焦点引擎要为每一行建立候选并参与每次方向键的几何搜索,行数上千时上下键
/// 和 Menu 键会一起失去响应。这里先渲染一页,焦点挪到末尾附近再续下一页,
/// 行数上限与续页距离见 `TVLongListPagingPolicy`。
///
/// `row` 拿到的第三个参数必须接到行自身的焦点回调上(`TVFocusButton` 的
/// `onFocusChanged`),否则焦点走到已渲染的末尾就再也续不上页。
struct TVPagedList<Item, ID: Hashable, Row: View>: View {
    private struct Entry: Identifiable {
        let id: ID
        let index: Int
        let item: Item
    }

    private let items: [Item]
    private let id: KeyPath<Item, ID>
    private let alignment: HorizontalAlignment
    private let spacing: CGFloat
    private let row: (Int, Item, @escaping (Bool) -> Void) -> Row

    @State private var renderedRowCount: Int

    /// `revealing`:首次渲染就要覆盖到的那一行 (打开时要滚过去的当前章节之类)。
    init(
        _ items: [Item],
        id: KeyPath<Item, ID>,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat = 10,
        revealing: Int? = nil,
        @ViewBuilder row: @escaping (Int, Item, @escaping (Bool) -> Void) -> Row
    ) {
        self.items = items
        self.id = id
        self.alignment = alignment
        self.spacing = spacing
        self.row = row
        _renderedRowCount = State(initialValue: TVLongListPagingPolicy.initialLimit(
            revealing: revealing, totalCount: items.count
        ))
    }

    var body: some View {
        let total = items.count
        let shown = TVLongListPagingPolicy.clamped(limit: renderedRowCount, totalCount: total)
        let entries = items.prefix(shown).enumerated().map {
            Entry(id: $1[keyPath: id], index: $0, item: $1)
        }
        LazyVStack(alignment: alignment, spacing: spacing) {
            ForEach(entries) { entry in
                row(entry.index, entry.item) { focused in
                    guard focused else { return }
                    renderedRowCount = TVLongListPagingPolicy.limit(
                        after: shown, focusedRow: entry.index, totalCount: total
                    )
                }
            }
        }
    }
}

extension TVPagedList where Item: Identifiable, ID == Item.ID {
    init(
        _ items: [Item],
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat = 10,
        revealing: Int? = nil,
        @ViewBuilder row: @escaping (Int, Item, @escaping (Bool) -> Void) -> Row
    ) {
        self.init(items, id: \.id, alignment: alignment, spacing: spacing, revealing: revealing, row: row)
    }
}

/// `TVPagedList` 的网格版:先渲染一页格子,焦点挪到末尾附近再续。上千个电台、
/// 流派的网格交给焦点引擎时,方向键同样会变迟钝。渲染到的格数凑满整行,
/// 最后一行不会只露出半行让焦点往下落空。
///
/// `cell` 拿到的第三个参数同样必须接到格子自身的焦点回调上。
struct TVPagedGrid<Item: Identifiable, Cell: View>: View {
    private struct Entry: Identifiable {
        let id: Item.ID
        let index: Int
        let item: Item
    }

    private let items: [Item]
    private let columns: [GridItem]
    private let alignment: HorizontalAlignment
    private let spacing: CGFloat?
    private let cell: (Int, Item, @escaping (Bool) -> Void) -> Cell

    @State private var renderedCount: Int

    /// `revealing`:首次渲染就要覆盖到的那一格 (从播放页回来要放回焦点的那张卡片)。
    init(
        _ items: [Item],
        columns: [GridItem],
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        revealing: Int? = nil,
        @ViewBuilder cell: @escaping (Int, Item, @escaping (Bool) -> Void) -> Cell
    ) {
        self.items = items
        self.columns = columns
        self.alignment = alignment
        self.spacing = spacing
        self.cell = cell
        _renderedCount = State(initialValue: TVLongListPagingPolicy.initialLimit(
            revealing: revealing, totalCount: items.count
        ))
    }

    var body: some View {
        let total = items.count
        let shown = TVLongListPagingPolicy.wholeRows(
            TVLongListPagingPolicy.clamped(limit: renderedCount, totalCount: total),
            columns: columns.count,
            totalCount: total
        )
        let entries = items.prefix(shown).enumerated().map {
            Entry(id: $1.id, index: $0, item: $1)
        }
        LazyVGrid(columns: columns, alignment: alignment, spacing: spacing) {
            ForEach(entries) { entry in
                cell(entry.index, entry.item) { focused in
                    guard focused else { return }
                    renderedCount = TVLongListPagingPolicy.limit(
                        after: shown, focusedRow: entry.index, totalCount: total
                    )
                }
            }
        }
    }
}

/// 「正在播放」那一行的跳动音柱:播放时四根柱子按各自的节奏起落(两条不同频率的正弦叠在一起,
/// 不像单一往复那么机械),暂停时落成高低错落的一排静止。「减弱动态效果」打开时也静止。
struct TVNowPlayingBars: View {
    var isPlaying: Bool
    var color: Color = TVColor.brand
    var barWidth: CGFloat = 5
    var height: CGFloat = 24

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let restingLevels: [Double] = [0.45, 0.8, 0.6, 0.35]
    private static let speeds: [Double] = [2.3, 3.4, 2.8, 3.9]
    private static let phases: [Double] = [0, 1.3, 2.5, 0.7]

    var body: some View {
        let animates = isPlaying && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: barWidth * 0.7) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: height * Self.level(index, time: time, animates: animates))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .animation(.easeOut(duration: 0.25), value: animates)
        .accessibilityHidden(true)
    }

    private static func level(_ index: Int, time: TimeInterval, animates: Bool) -> CGFloat {
        guard animates else { return restingLevels[index] }
        let primary = sin(time * speeds[index] * .pi + phases[index])
        let secondary = sin(time * speeds[index] * 1.9 + phases[index] * 2)
        return CGFloat(min(1, max(0.18, 0.56 + 0.3 * primary + 0.14 * secondary)))
    }
}

#endif
