#if os(tvOS)
import SwiftUI
import PrimuseKit
import UIKit

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
                HStack(spacing: 22) { content() }
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
    var width: CGFloat = 200
    var titleOverride: String? = nil
    var subtitleOverride: String? = nil
    var action: () -> Void = {}
    @Environment(TVStore.self) private var store

    var body: some View {
        TVFocusButton(radius: TVRadius.cover, scale: 1.10, lift: 10,
                      action: { store.play(album: album); action() }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                TVArtworkView(album: album, size: width)
                VStack(alignment: .leading, spacing: 6) {
                    Text(titleOverride ?? album.title)
                        .tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text).lineLimit(2)
                    Text(subtitleOverride ?? album.artist)
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                .padding(.top, 12).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

// MARK: - 歌曲卡片(用所属专辑封面)

struct TVSongCard: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    var width: CGFloat = 200
    var reason: String? = nil
    var action: () -> Void = {}

    var body: some View {
        let album = store.albumOf(song)
        TVFocusButton(radius: TVRadius.cover, scale: 1.10, lift: 10,
                      action: { store.play(song); action() }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", songID: song.id, coverRef: song.coverRef,
                              tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: width)
                VStack(alignment: .leading, spacing: 6) {
                    if let reason, !reason.isEmpty {
                        Label(reason, systemImage: "sparkles")
                            .tvFont(.caption, weight: .semibold)
                            .foregroundStyle(TVColor.brand)
                            .lineLimit(1)
                    }
                    Text(song.title).tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text).lineLimit(2)
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
        TVFocusButton(radius: TVRadius.cover, scale: 1.10, lift: 10,
                      action: {
                          TVSiriMediaInteractionDonor.donate(station: station)
                          store.play(station)
                          action()
                      }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                TVRadioArtworkView(station: station, size: width, radius: TVRadius.cover)
                VStack(alignment: .leading, spacing: 6) {
                    Text(station.name)
                        .tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2)
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
        TVFocusButton(radius: size / 2 + 8, scale: 1.08, lift: 10, action: action) { _ in
            VStack(spacing: 12) {
                TVCoverArt(tint: artist.tint, tint2: artist.tint2, glyph: artist.glyph,
                           size: size, radius: size / 2)
                Text(artist.name).tvFont(.cardTitle)
                    .foregroundStyle(TVColor.text).lineLimit(2).frame(width: size + 20)
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
