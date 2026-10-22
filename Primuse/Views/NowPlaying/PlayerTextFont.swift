import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#endif

// 歌词与有声内容文稿共用的字体:可选的几种、按需下载、字体块选择(#332)。
// 歌词那一侧经环境值 `lyricsTypeface` 从各窗口的根注入,iOS / macOS / tvOS 三个 target 都编这个文件。

/// 可选的字体。中文的几种排在前面(同 Apple 图书):苹方系统自带;宋体、楷体、圆体在 iOS 上要按需下载,
/// 下好之前与下载失败时先用系统字体显示。
enum PlayerTextFont: String, CaseIterable, Identifiable {
    case system, pingFang, songti, kaiti, yuanti, serif, rounded, georgia, palatino, charter, iowan

    var id: String { rawValue }

    /// 中文字体的 PostScript 名:显示与下载都认它。
    var postScriptName: String? {
        switch self {
        case .pingFang: "PingFangSC-Regular"
        case .songti: "STSongti-SC-Regular"
        case .kaiti: "STKaitiSC-Regular"
        case .yuanti: "STYuanti-SC-Regular"
        default: nil
        }
    }

    /// 西文字体按名字取。不是每台设备都装着(电视上就未必有),电视只列装着的。
    var familyName: String? {
        switch self {
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .charter: "Charter"
        case .iowan: "Iowan Old Style"
        default: nil
        }
    }

    /// `isAvailable` 为 false(还没下好、下载失败)时用系统字体。字号是定死的,和系统字体那几档一样
    /// 不再跟着系统的「更大字体」放大(各处的字号由自己的字号设置管)。苹方每一档字重是单独的字体名,
    /// 按名字取;其余字体用字重修饰,家族里没有那一档时由系统就近匹配。
    func font(size: CGFloat, weight: Font.Weight = .regular, isAvailable: Bool = true) -> Font {
        guard isAvailable else { return .system(size: size, weight: weight) }
        switch self {
        case .system:
            return .system(size: size, weight: weight)
        case .pingFang:
            return .custom(Self.pingFangPostScriptName(for: weight), fixedSize: size)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .rounded:
            return .system(size: size, weight: weight, design: .rounded)
        case .songti, .kaiti, .yuanti, .georgia, .palatino, .charter, .iowan:
            return .custom(postScriptName ?? familyName ?? "", fixedSize: size).weight(weight)
        }
    }

    /// 苹方各档字重的字体名(系统都预装)。最粗只到半粗,更粗的几档也用它。
    static func pingFangPostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: "PingFangSC-Ultralight"
        case .thin: "PingFangSC-Thin"
        case .light: "PingFangSC-Light"
        case .medium: "PingFangSC-Medium"
        case .semibold, .bold, .heavy, .black: "PingFangSC-Semibold"
        default: "PingFangSC-Regular"
        }
    }

    /// 系统那几种与中文字体按语言叫,其余是字体本身的名字。
    var localizedTitle: String {
        switch self {
        case .system: String(localized: "transcript_font_system")
        case .pingFang: String(localized: "transcript_reader_font_pingfang")
        case .songti: String(localized: "transcript_reader_font_songti")
        case .kaiti: String(localized: "transcript_reader_font_kaiti")
        case .yuanti: String(localized: "transcript_reader_font_yuanti")
        case .serif: String(localized: "transcript_font_serif")
        case .rounded: String(localized: "transcript_font_rounded")
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .charter: "Charter"
        case .iowan: "Iowan"
        }
    }

    var title: Text { Text(verbatim: localizedTitle) }

    /// 字体块上的样字:中文字体写一个「字」,其余写 Aa。
    var sample: String { postScriptName == nil ? "Aa" : "\u{5B57}" }
}

/// 按需下载的中文字体。宋体、楷体、圆体在 iOS 上不预装,选了才去系统字体库里下;
/// 下过的字体每次启动后也要再走一遍同一个接口才能用(这次很快,不再联网)。
@MainActor
@Observable
final class PlayerTextFontLibrary {
    enum State: Equatable {
        case available
        case needsDownload
        case downloading(Double)
        case failed
    }

    static let shared = PlayerTextFontLibrary()

    /// 下载中、失败与这次启动里下好的。字体块上的进度与标记读它。
    private var states: [String: State] = [:]
    /// 这次启动里下好(或激活好)的字体名,只在字体真正能用时变。歌词那几棵树的根经 `isAvailable`
    /// 读的是它:下载进度一跳一跳时不跟着重算。
    private var activatedNames: Set<String> = []
    /// 查过的「这台设备上现在有没有」。每次都去系统字体库里找一遍不便宜,歌词又重画得勤。
    @ObservationIgnored private var installedCache: [String: Bool] = [:]

    func state(of font: PlayerTextFont) -> State {
        guard let name = font.postScriptName else { return .available }
        if let state = states[name] { return state }
        return isInstalledCached(name) ? .available : .needsDownload
    }

    func isAvailable(_ font: PlayerTextFont) -> Bool {
        guard let name = font.postScriptName else { return true }
        return activatedNames.contains(name) || isInstalledCached(name)
    }

    /// 这台设备上现在就能显示的几种(电视上用:那边没有下载入口,西文字体也未必都装着)。
    func installedFonts() -> [PlayerTextFont] {
        PlayerTextFont.allCases.filter { font in
            if font.postScriptName != nil { return isAvailable(font) }
            if let family = font.familyName {
                if let cached = installedCache[family] { return cached }
                let installed = Self.hasFamily(family)
                installedCache[family] = installed
                return installed
            }
            return true
        }
    }

    /// 还不能用就去下载(或激活已经下过的)。正在下的不重复发起;失败过的再点一次重试。
    func prepare(_ font: PlayerTextFont) {
        guard let name = font.postScriptName else { return }
        switch state(of: font) {
        case .available, .downloading:
            return
        case .needsDownload, .failed:
            break
        }
        states[name] = .downloading(0)
        Task {
            let succeeded = await Self.activate(postScriptName: name) { fraction in
                Task { @MainActor in self.updateProgress(fraction, for: name) }
            }
            if succeeded {
                installedCache[name] = true
                activatedNames.insert(name)
            }
            states[name] = succeeded ? .available : .failed
        }
    }

    private func updateProgress(_ fraction: Double, for name: String) {
        guard case .downloading = states[name] else { return }
        states[name] = .downloading(fraction)
    }

    private func isInstalledCached(_ postScriptName: String) -> Bool {
        if let cached = installedCache[postScriptName] { return cached }
        let installed = Self.isInstalled(postScriptName)
        installedCache[postScriptName] = installed
        return installed
    }

    nonisolated static func isInstalled(_ postScriptName: String) -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String) == postScriptName
    }

    private nonisolated static func hasFamily(_ familyName: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute as String: familyName] as CFDictionary
        )
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil) else { return false }
        let matchedFamily = CTFontDescriptorCopyAttribute(matched, kCTFontFamilyNameAttribute) as? String
        return matchedFamily == familyName
    }

    /// 系统的进度回调在 CoreText 自己的队列上跑,所以这里不带主线程隔离。
    private nonisolated static func activate(
        postScriptName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontNameAttribute as String: postScriptName] as CFDictionary
        )
        let once = PlayerTextFontActivation()
        return await withCheckedContinuation { continuation in
            let started = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(
                [descriptor] as CFArray,
                nil
            ) { state, parameters in
                switch state {
                case .downloading:
                    let info = parameters as NSDictionary
                    if let percent = info[kCTFontDescriptorMatchingPercentage as String] as? Double {
                        progress(min(max(percent / 100, 0), 1))
                    }
                case .didFinish:
                    if once.claim() {
                        continuation.resume(returning: PlayerTextFontLibrary.isInstalled(postScriptName))
                    }
                default:
                    break
                }
                return true
            }
            if !started, once.claim() {
                continuation.resume(returning: false)
            }
        }
    }
}

/// 下载结束只能报一次:续体恢复两次会直接崩。
private final class PlayerTextFontActivation: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

// MARK: - 歌词字体

/// 歌词用哪种字体,连同它此刻能不能用:要下载的字体下好之前是 false,先用系统字体,下好后整棵树换上。
/// 逐字歌词的测量缓存认它(`LyricsFlowMeasurementKey`),换了字体就重新量。
struct LyricsTypeface: Equatable {
    var family: PlayerTextFont = .system
    var isAvailable = true

    static let system = LyricsTypeface()

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        family.font(size: size, weight: weight, isAvailable: isAvailable)
    }

    /// 真正画出来的是不是系统字体(没选别的,或选的还没下好)。
    var drawsSystemFont: Bool { family == .system || !isAvailable }
}

extension EnvironmentValues {
    /// 歌词的字体,由 `LyricsTypefaceProvider` 在各窗口的根上按设置注入;没注入的地方(取证页、离屏渲染)是系统字体。
    @Entry var lyricsTypeface: LyricsTypeface = .system
}

/// 把设置里选的歌词字体放进环境。挂在每个窗口的根上:iPhone / iPad / Mac 主窗口、外接屏,
/// Mac 的桌面歌词、歌词岛、迷你播放器这些独立窗口,以及电视。选了要下载的字体时顺手去下
/// (或激活这台设备下过的),下好之前环境里先是系统字体。
struct LyricsTypefaceProvider: ViewModifier {
    @AppStorage(PlayerAppearancePreferences.lyricsFontKey)
    private var rawValue = PlayerTextFont.system.rawValue

    func body(content: Content) -> some View {
        let family = PlayerTextFont(rawValue: rawValue) ?? .system
        content
            .environment(\.lyricsTypeface, LyricsTypeface(
                family: family,
                isAvailable: PlayerTextFontLibrary.shared.isAvailable(family)
            ))
            .task(id: family) {
                PlayerTextFontLibrary.shared.prepare(family)
            }
    }
}

#if os(macOS)
extension LyricsTypeface {
    /// 和 `font(size:weight:)` 画出来的同一种字体,给要先用 AppKit 量宽度的地方(歌词岛按字宽定外形)。
    @MainActor
    func nsFont(size: CGFloat, weight: Font.Weight) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: Self.appKitWeight(weight))
        guard !drawsSystemFont else { return system }
        switch family {
        case .system:
            return system
        case .pingFang:
            return NSFont(name: PlayerTextFont.pingFangPostScriptName(for: weight), size: size) ?? system
        case .serif, .rounded:
            let design: NSFontDescriptor.SystemDesign = family == .serif ? .serif : .rounded
            return system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .songti, .kaiti, .yuanti, .georgia, .palatino, .charter, .iowan:
            let name = family.postScriptName ?? family.familyName ?? ""
            guard let base = NSFont(name: name, size: size) else { return system }
            let isBold = [Font.Weight.semibold, .bold, .heavy, .black].contains(weight)
            return isBold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        }
    }

    private static func appKitWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
#endif

#if os(iOS) || os(macOS)
/// 一排横着滑的字体块:每块用那种字体写个样字,要下载的标朵云、下载中画一圈进度、失败标个感叹号。
/// 点一块就选中它,还没下的顺手开始下;失败过的再点一次重试。
struct PlayerTextFontPicker: View {
    @Binding var selection: String
    /// 样字的字重,跟用它的地方一样(文稿照所选字重,歌词是半粗)。
    var sampleWeight: Font.Weight = .regular

    private var library: PlayerTextFontLibrary { .shared }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(PlayerTextFont.allCases) { font in
                    chip(font)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func chip(_ font: PlayerTextFont) -> some View {
        let isSelected = font.rawValue == selection
        let state = library.state(of: font)
        return Button {
            selection = font.rawValue
            library.prepare(font)
        } label: {
            VStack(spacing: 4) {
                Text(verbatim: font.sample)
                    .font(font.font(size: 22, weight: sampleWeight, isAvailable: state == .available))
                font.title
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(minWidth: 64)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .overlay(alignment: .topTrailing) {
                Self.stateBadge(state)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(Self.stateAccessibilityText(state))
    }

    /// 要下载的标朵云,下载中画一圈进度,失败标个感叹号。
    @ViewBuilder
    static func stateBadge(_ state: PlayerTextFontLibrary.State) -> some View {
        switch state {
        case .available:
            EmptyView()
        case .needsDownload:
            Image(systemName: "icloud.and.arrow.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(5)
        case let .downloading(fraction):
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.05, fraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            .padding(5)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(5)
        }
    }

    static func stateAccessibilityText(_ state: PlayerTextFontLibrary.State) -> Text {
        switch state {
        case .available: Text(verbatim: "")
        case .needsDownload: Text("transcript_reader_font_needs_download")
        case .downloading: Text("transcript_reader_font_downloading")
        case .failed: Text("transcript_reader_font_download_failed")
        }
    }
}
#endif
