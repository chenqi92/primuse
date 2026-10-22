import CoreText
import SwiftUI
import PrimuseKit
#if os(macOS)
import AppKit
#endif

// 歌词与有声内容文稿共用的字体:可选的几种、按需下载、导入自己的字体、字体块选择(#332)。
// 歌词那一侧经环境值 `lyricsTypeface` 从各窗口的根注入,iOS / macOS / tvOS 三个 target 都编这个文件;
// 导入字体的文件读写与注册在 PlayerTextFontImport.swift(只有 iPhone / iPad / Mac)。

/// 选中的字体:内置的一种,或用户导入的一种(按 PostScript 名认)。存进设置的是 `rawValue`,
/// 内置字体与只有内置字体时存的一样,导入的是 `imported:<PostScript 名>`(规则在 Kit 的 `PlayerTextFontSelection`)。
enum PlayerTextFont: Hashable, Identifiable {
    case builtin(Builtin)
    case imported(postScriptName: String)

    static let system = PlayerTextFont.builtin(.system)

    /// 全部内置字体,按选择器里的先后。
    static let builtins: [PlayerTextFont] = Builtin.allCases.map { PlayerTextFont.builtin($0) }

    /// 认不出来的(空的、别的版本加的内置字体)返回 nil,调用方退回系统字体。
    init?(rawValue: String) {
        switch PlayerTextFontSelection(rawValue: rawValue) {
        case let .builtin(name)?:
            guard let builtin = Builtin(rawValue: name) else { return nil }
            self = .builtin(builtin)
        case let .imported(postScriptName)?:
            self = .imported(postScriptName: postScriptName)
        case nil:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case let .builtin(builtin): builtin.rawValue
        case let .imported(postScriptName): PlayerTextFontSelection.imported(postScriptName: postScriptName).rawValue
        }
    }

    var id: String { rawValue }

    /// `isAvailable` 为 false(还没下好、下载失败、导入的字体这台设备上没有或还没注册好)时用系统字体。
    /// 字号是定死的,和系统字体那几档一样不再跟着系统的「更大字体」放大(各处的字号由自己的字号设置管)。
    func font(size: CGFloat, weight: Font.Weight = .regular, isAvailable: Bool = true) -> Font {
        guard isAvailable else { return .system(size: size, weight: weight) }
        switch self {
        case let .builtin(builtin):
            return builtin.font(size: size, weight: weight)
        case let .imported(postScriptName):
            // 同一家族导入了几种字重时由系统按字重就近取;只有一种时就是它。
            return .custom(postScriptName, fixedSize: size).weight(weight)
        }
    }

    /// 内置的按语言叫(西文字体用本名);导入的用读出来的名字,这台设备没有这个字体时只能写 PostScript 名。
    @MainActor
    var localizedTitle: String {
        switch self {
        case let .builtin(builtin):
            builtin.localizedTitle
        case let .imported(postScriptName):
            PlayerTextFontLibrary.shared.importedEntry(containing: postScriptName)?.title ?? postScriptName
        }
    }

    @MainActor
    var title: Text { Text(verbatim: localizedTitle) }

    /// 字体块上的样字:中文字体写「字」,日文「あ」,韩文「가」,其余 Aa。
    @MainActor
    var sample: String {
        switch self {
        case let .builtin(builtin):
            builtin.sampleScript.sample
        case let .imported(postScriptName):
            (PlayerTextFontLibrary.shared.importedEntry(containing: postScriptName)?.sampleScript ?? .latin).sample
        }
    }
}

extension PlayerTextFont {
    /// 选择器里的分组。字体多了,一排横滑太长,按用途分成几行。
    enum Category: CaseIterable {
        case common, handwriting, japaneseKorean, decorative

        var title: String {
            switch self {
            case .common: String(localized: "transcript_reader_font_group_common")
            case .handwriting: String(localized: "transcript_reader_font_group_handwriting")
            case .japaneseKorean: String(localized: "transcript_reader_font_group_cjk")
            case .decorative: String(localized: "transcript_reader_font_group_decorative")
            }
        }

        /// 西文花体只有字母,中文照样是系统字体,在组下面写明。
        var footnote: String? {
            self == .decorative ? String(localized: "transcript_reader_font_group_decorative_footer") : nil
        }

        var fonts: [Builtin] { Builtin.allCases.filter { $0.category == self } }
    }

    /// 内置的字体,全是系统自带或苹果按需下载的,不打包进 App。中文的几种排在前面(同 Apple 图书):
    /// 苹方系统自带;宋体、楷体、圆体与手写、书法那几种在 iOS 上要按需下载,下好之前与下载失败时先用系统字体显示。
    /// 西文花体在 iOS 上大多预装(Phosphate、Luminari 要下载),Mac 上都预装,电视上基本没有(电视只列装着的)。
    enum Builtin: String, CaseIterable {
        case system, pingFang, songti, kaiti, yuanti, serif, rounded, georgia, palatino, charter, iowan
        case wawa, hanziPen, hannotate, xingkai, libian, weibei, baoli, yuppy, lantinghei
        case klee, toppanMidashi, nanumBrush, nanumPen
        case partyLET, zapfino, phosphate, chalkduster, markerFelt, snellRoundhand, luminari

        var category: Category {
            switch self {
            case .system, .pingFang, .songti, .kaiti, .yuanti, .serif, .rounded, .georgia, .palatino, .charter, .iowan:
                .common
            case .wawa, .hanziPen, .hannotate, .xingkai, .libian, .weibei, .baoli, .yuppy, .lantinghei:
                .handwriting
            case .klee, .toppanMidashi, .nanumBrush, .nanumPen:
                .japaneseKorean
            case .partyLET, .zapfino, .phosphate, .chalkduster, .markerFelt, .snellRoundhand, .luminari:
                .decorative
            }
        }

        /// 按名字取的字体的 PostScript 名:显示、下载、「装没装着」都认它。
        var postScriptName: String? {
            switch self {
            case .pingFang: "PingFangSC-Regular"
            case .songti: "STSongti-SC-Regular"
            case .kaiti: "STKaitiSC-Regular"
            case .yuanti: "STYuanti-SC-Regular"
            case .wawa: "DFWaWaSC-W5"
            case .hanziPen: "HanziPenSC-W3"
            case .hannotate: "HannotateSC-W5"
            case .xingkai: "STXingkaiSC-Light"
            case .libian: "STLibianSC-Regular"
            case .weibei: "WeibeiSC-Bold"
            case .baoli: "STBaoliSC-Regular"
            case .yuppy: "YuppySC-Regular"
            case .lantinghei: "FZLTTHK--GBK1-0"
            case .klee: "Klee-Medium"
            case .toppanMidashi: "ToppanBunkyuMidashiGothicStdN-ExtraBold"
            case .nanumBrush: "NanumBrush"
            case .nanumPen: "NanumPen"
            case .partyLET: "PartyLetPlain"
            case .zapfino: "Zapfino"
            case .phosphate: "Phosphate-Inline"
            case .chalkduster: "Chalkduster"
            case .markerFelt: "MarkerFelt-Wide"
            case .snellRoundhand: "SnellRoundhand"
            case .luminari: "Luminari-Regular"
            case .system, .serif, .rounded, .georgia, .palatino, .charter, .iowan: nil
            }
        }

        /// 同一家族里粗的那一面,和常规的一起下载(或激活):歌词当前行、章节名用半粗以上时
        /// 系统按字重在家族里就近取到它,没下好就只剩常规那一面可取。
        var companionPostScriptNames: [String] {
            switch self {
            case .hanziPen: ["HanziPenSC-W5"]
            case .hannotate: ["HannotateSC-W7"]
            case .xingkai: ["STXingkaiSC-Bold"]
            case .klee: ["Klee-Demibold"]
            case .snellRoundhand: ["SnellRoundhand-Bold"]
            default: []
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

        /// 只用这一面、不跟着字重换的。兰亭黑这一项就是「特粗」,同家族更细的几档不取。
        var ignoresWeight: Bool { self == .lantinghei }

        var sampleScript: PlayerTextFontSampleScript {
            switch category {
            case .common:
                postScriptName == nil ? .latin : .han
            case .handwriting:
                .han
            case .japaneseKorean:
                self == .nanumBrush || self == .nanumPen ? .hangul : .kana
            case .decorative:
                .latin
            }
        }

        /// 苹方每一档字重是单独的字体名,按名字取;只有一面的字体(兰亭黑·特粗)按名字取那一面;
        /// 其余字体用字重修饰,家族里没有那一档时由系统就近匹配(娃娃体、魏碑这类只有一档的就是它本身)。
        func font(size: CGFloat, weight: Font.Weight) -> Font {
            switch self {
            case .system:
                return .system(size: size, weight: weight)
            case .pingFang:
                return .custom(PlayerTextFont.pingFangPostScriptName(for: weight), fixedSize: size)
            case .serif:
                return .system(size: size, weight: weight, design: .serif)
            case .rounded:
                return .system(size: size, weight: weight, design: .rounded)
            default:
                let font = Font.custom(postScriptName ?? familyName ?? "", fixedSize: size)
                return ignoresWeight ? font : font.weight(weight)
            }
        }

        /// 系统那几种与中文、日文、韩文字体按语言叫,西文字体是字体本身的名字,不翻译。
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
            case .wawa: String(localized: "transcript_reader_font_wawa")
            case .hanziPen: String(localized: "transcript_reader_font_hanzipen")
            case .hannotate: String(localized: "transcript_reader_font_hannotate")
            case .xingkai: String(localized: "transcript_reader_font_xingkai")
            case .libian: String(localized: "transcript_reader_font_libian")
            case .weibei: String(localized: "transcript_reader_font_weibei")
            case .baoli: String(localized: "transcript_reader_font_baoli")
            case .yuppy: String(localized: "transcript_reader_font_yuppy")
            case .lantinghei: String(localized: "transcript_reader_font_lantinghei")
            case .klee: String(localized: "transcript_reader_font_klee")
            case .toppanMidashi: String(localized: "transcript_reader_font_toppan_midashi")
            case .nanumBrush: String(localized: "transcript_reader_font_nanum_brush")
            case .nanumPen: String(localized: "transcript_reader_font_nanum_pen")
            case .partyLET: "Party LET"
            case .zapfino: "Zapfino"
            case .phosphate: "Phosphate"
            case .chalkduster: "Chalkduster"
            case .markerFelt: "Marker Felt"
            case .snellRoundhand: "Snell Roundhand"
            case .luminari: "Luminari"
            }
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
}

/// 按需下载的内置字体与用户导入的字体。宋体、楷体、圆体与手写、书法那几种在 iOS 上不预装,选了才去系统字体库里下;
/// 下过的字体每次启动后也要再走一遍同一个接口才能用(这次很快,不再联网)。导入的字体启动时在后台注册一遍,
/// 只在本 App 里生效。
@MainActor
@Observable
final class PlayerTextFontLibrary {
    enum State: Equatable {
        case available
        case needsDownload
        case downloading(Double)
        /// 内置字体下载失败;导入的字体这台设备上注册不上。
        case failed
        /// 导入的字体这台设备上没有(在别的设备上导入、选中值随 iCloud 同步过来的)。
        case unavailable
    }

    static let shared = PlayerTextFontLibrary()

    /// 下载中、失败与这次启动里下好的。字体块上的进度与标记读它。
    private var states: [String: State] = [:]
    /// 这次启动里下好(或激活好)的字体名、注册好的导入字体,只在字体真正能用时变。歌词那几棵树的根经
    /// `isAvailable` 读的是它:下载进度一跳一跳时不跟着重算。
    var activatedNames: Set<String> = []
    /// 查过的「这台设备上现在有没有」。每次都去系统字体库里找一遍不便宜,歌词又重画得勤。
    @ObservationIgnored private var installedCache: [String: Bool] = [:]

    /// 用户导入的字体,一个家族一项(选择器「我导入的」那一组)。
    var importedFonts: [ImportedFontEntry] = []
    /// 启动时读完、注册完导入的字体之前是 false:这一小会儿里选中的导入字体先画系统字体,不报「这台设备没有」。
    var importedFontsLoaded = false
    /// 正在导入(拷文件、注册)。导入按钮转圈,不重复发起。
    var isImporting = false
    /// 导入目录里每个文件读出来的每个字体,`importedFonts` 由它排出来。
    @ObservationIgnored var importedFaces: [ImportedFontFace] = []

    private init() {
        #if os(iOS) || os(macOS)
        loadImportedFonts()
        #else
        // 电视上没有导入入口:同步过来的导入字体一律按「这台设备没有」、画系统字体。
        importedFontsLoaded = true
        #endif
    }

    func state(of font: PlayerTextFont) -> State {
        switch font {
        case let .builtin(builtin):
            guard let name = builtin.postScriptName else { return .available }
            if let state = states[name] { return state }
            return isInstalledCached(name) ? .available : .needsDownload
        case let .imported(name):
            if activatedNames.contains(name) { return .available }
            // 还在启动时注册的那一小会儿不报缺(环境里先是系统字体,注册好就换上)。
            guard importedFontsLoaded else { return .available }
            return importedEntry(containing: name) == nil ? .unavailable : .failed
        }
    }

    func isAvailable(_ font: PlayerTextFont) -> Bool {
        switch font {
        case let .builtin(builtin):
            guard let name = builtin.postScriptName else { return true }
            return activatedNames.contains(name) || isInstalledCached(name)
        case let .imported(name):
            return activatedNames.contains(name)
        }
    }

    /// 这台设备上现在就能显示的几种内置字体(电视上用:那边没有下载、导入入口,西文字体也未必都装着)。
    func installedFonts() -> [PlayerTextFont] {
        PlayerTextFont.Builtin.allCases.filter { builtin in
            if builtin.postScriptName != nil { return isAvailable(.builtin(builtin)) }
            if let family = builtin.familyName {
                if let cached = installedCache[family] { return cached }
                let installed = Self.hasFamily(family)
                installedCache[family] = installed
                return installed
            }
            return true
        }
        .map { PlayerTextFont.builtin($0) }
    }

    /// 包含这个字体的导入项(同一家族的几种字重并成一项)。
    func importedEntry(containing postScriptName: String) -> ImportedFontEntry? {
        importedFonts.first { $0.contains(postScriptName: postScriptName) }
    }

    /// 选择器里代表这个选中值的那一项:导入的字体按家族列一项,选中的是同家族的另一种字重时也落在这一项上。
    func pickerFont(for font: PlayerTextFont) -> PlayerTextFont {
        guard case let .imported(name) = font, let entry = importedEntry(containing: name) else { return font }
        return .imported(postScriptName: entry.postScriptName)
    }

    /// 选中的字体用不上时写在字体那一行下面的话;下载中、要下载与能用时没有。
    func failureMessage(for font: PlayerTextFont) -> String? {
        guard state(of: font) == .failed else { return nil }
        switch font {
        case .builtin: return String(localized: "transcript_reader_font_download_failed")
        case .imported: return String(localized: "transcript_reader_font_imported_failed")
        }
    }

    /// 还不能用就去下载(或激活已经下过的)。正在下的不重复发起;失败过的再点一次重试。
    /// 导入的字体不在这里:启动时已经在后台注册。
    func prepare(_ font: PlayerTextFont) {
        guard case let .builtin(builtin) = font, let name = builtin.postScriptName else { return }
        switch state(of: font) {
        case .available, .downloading, .unavailable:
            return
        case .needsDownload, .failed:
            break
        }
        states[name] = .downloading(0)
        let names = [name] + builtin.companionPostScriptNames
        Task {
            let succeeded = await Self.activate(postScriptNames: names) { fraction in
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

    /// 系统的进度回调在 CoreText 自己的队列上跑,所以这里不带主线程隔离。第一个名字是主字体,
    /// 成没成按它算;后面的是同家族粗的那一面,一起要下来。
    private nonisolated static func activate(
        postScriptNames: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        guard let primary = postScriptNames.first else { return false }
        let descriptors = postScriptNames.map { name in
            CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute as String: name] as CFDictionary)
        }
        let once = PlayerTextFontActivation()
        return await withCheckedContinuation { continuation in
            let started = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(
                descriptors as CFArray,
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
                        continuation.resume(returning: PlayerTextFontLibrary.isInstalled(primary))
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
final class PlayerTextFontActivation: @unchecked Sendable {
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

/// 歌词用哪种字体,连同它此刻能不能用:要下载的字体下好之前、导入的字体注册好之前是 false,
/// 先用系统字体,能用了整棵树换上。逐字歌词的测量缓存认它(`LyricsFlowMeasurementKey`),换了字体就重新量。
struct LyricsTypeface: Equatable {
    var family: PlayerTextFont = .system
    var isAvailable = true

    static let system = LyricsTypeface()

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        family.font(size: size, weight: weight, isAvailable: isAvailable)
    }

    /// 真正画出来的是不是系统字体(没选别的,或选的还没下好、这台设备没有)。
    var drawsSystemFont: Bool { family == .system || !isAvailable }
}

extension EnvironmentValues {
    /// 歌词的字体,由 `LyricsTypefaceProvider` 在各窗口的根上按设置注入;没注入的地方(取证页、离屏渲染)是系统字体。
    @Entry var lyricsTypeface: LyricsTypeface = .system
}

/// 把设置里选的歌词字体放进环境。挂在每个窗口的根上:iPhone / iPad / Mac 主窗口、外接屏,
/// Mac 的桌面歌词、歌词岛、迷你播放器这些独立窗口,以及电视。选了要下载的字体时顺手去下
/// (或激活这台设备下过的),下好之前环境里先是系统字体;导入的字体同样等启动时注册好再换上。
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
    /// 要半粗以上时在家族里换粗的那一面;家族里没有(娃娃体、魏碑、Party LET 这类只有一档的)时
    /// `NSFontManager` 原样返回这一面,不会退回系统字体。
    @MainActor
    func nsFont(size: CGFloat, weight: Font.Weight) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: Self.appKitWeight(weight))
        guard !drawsSystemFont else { return system }
        let isBold = [Font.Weight.semibold, .bold, .heavy, .black].contains(weight)
        switch family {
        case .builtin(.system):
            return system
        case .builtin(.pingFang):
            return NSFont(name: PlayerTextFont.pingFangPostScriptName(for: weight), size: size) ?? system
        case .builtin(.serif), .builtin(.rounded):
            let design: NSFontDescriptor.SystemDesign = family == .builtin(.serif) ? .serif : .rounded
            return system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case let .builtin(builtin):
            let name = builtin.postScriptName ?? builtin.familyName ?? ""
            return Self.named(name, size: size, bold: isBold && !builtin.ignoresWeight) ?? system
        case let .imported(postScriptName):
            return Self.named(postScriptName, size: size, bold: isBold) ?? system
        }
    }

    @MainActor
    private static func named(_ name: String, size: CGFloat, bold: Bool) -> NSFont? {
        guard let base = NSFont(name: name, size: size) else { return nil }
        return bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
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
/// 按组排的字体块:常用、手写与书法、日文与韩文、西文花体各一排横滑,最后是「我导入的」和导入按钮。
/// 每块用那种字体写个样字,要下载的标朵云、下载中画一圈进度、失败标个感叹号。点一块就选中它,
/// 还没下的顺手开始下;失败过的再点一次重试。导入的字体长按(Mac 右键)可以删除。
struct PlayerTextFontPicker: View {
    @Binding var selection: String
    /// 样字的字重,跟用它的地方一样(文稿照所选字重,歌词是半粗)。
    var sampleWeight: Font.Weight = .regular

    @State private var showsImporter = false
    @State private var pendingImportURLs: [URL] = []
    @State private var showsMissingExplanation = false

    private var library: PlayerTextFontLibrary { .shared }

    private var selectedFont: PlayerTextFont {
        library.pickerFont(for: PlayerTextFont(rawValue: selection) ?? .system)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            missingImportedNote
            ForEach(PlayerTextFont.Category.allCases, id: \.self) { category in
                group(title: category.title, footnote: category.footnote) {
                    ForEach(category.fonts, id: \.self) { builtin in
                        chip(.builtin(builtin))
                    }
                }
            }
            group(
                title: String(localized: "transcript_reader_font_group_imported"),
                footnote: Self.importedFootnote
            ) {
                ForEach(library.importedFonts) { entry in
                    chip(.imported(postScriptName: entry.postScriptName))
                        .contextMenu {
                            Button(role: .destructive) {
                                library.removeImportedFont(entry)
                            } label: {
                                Label("delete", systemImage: "trash")
                            }
                        }
                }
                importChip
            }
        }
        .padding(.vertical, 4)
        #if os(macOS)
        // Mac 上可以直接把字体文件拖到这一片导入。
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !library.isImporting else { return false }
            pendingImportURLs = files
            return true
        }
        #endif
        .modifier(PlayerTextFontImportModifier(
            isPresented: $showsImporter,
            pendingURLs: $pendingImportURLs
        ) { font in
            selection = font.rawValue
        })
    }

    private func group<Chips: View>(
        title: String,
        footnote: String?,
        @ViewBuilder chips: () -> Chips
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    chips()
                }
                .padding(.vertical, 2)
            }
            if let footnote {
                Text(verbatim: footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chip(_ font: PlayerTextFont) -> some View {
        let isSelected = font == selectedFont
        let state = library.state(of: font)
        return Button {
            selection = font.rawValue
            library.prepare(font)
        } label: {
            VStack(spacing: 4) {
                Text(verbatim: font.sample)
                    .font(font.font(size: 22, weight: sampleWeight, isAvailable: state == .available))
                    .lineLimit(1)
                    // Zapfino 这类花体的行高大得多,样字一律占同样高,一排字体块才齐。
                    .frame(height: 30)
                font.title
                    .font(.caption)
                    .lineLimit(1)
            }
            .modifier(PlayerTextFontChipStyle(isSelected: isSelected))
            .overlay(alignment: .topTrailing) {
                Self.stateBadge(state)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(Self.stateAccessibilityText(state))
    }

    /// 「我导入的」最后一块:选字体文件(.ttf / .otf / .ttc,可以多选)。
    private var importChip: some View {
        Button {
            beginImport()
        } label: {
            VStack(spacing: 4) {
                Group {
                    if library.isImporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                    }
                }
                .frame(height: 30)
                Text("transcript_reader_font_import")
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.accentColor)
            .modifier(PlayerTextFontChipStyle(isSelected: false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(library.isImporting)
    }

    /// 选中的是别的设备上导入、随 iCloud 同步过来的字体,这台设备没有:看得出来,点了说明怎么办。
    @ViewBuilder
    private var missingImportedNote: some View {
        if case let .imported(name) = selectedFont, library.state(of: selectedFont) == .unavailable {
            Button {
                showsMissingExplanation = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(verbatim: String(format: String(localized: "transcript_reader_font_imported_missing_format"), name))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .alert(Text("transcript_reader_font_imported_missing_title"), isPresented: $showsMissingExplanation) {
                Button("transcript_reader_font_import") {
                    beginImport()
                }
                Button("transcript_reader_font_use_system") {
                    selection = PlayerTextFont.system.rawValue
                }
                Button("cancel", role: .cancel) {}
            } message: {
                Text("transcript_reader_font_imported_missing_message")
            }
        }
    }

    private func beginImport() {
        #if os(macOS)
        let urls = PlayerTextFontImportPanel.chooseFiles()
        if !urls.isEmpty { pendingImportURLs = urls }
        #else
        showsImporter = true
        #endif
    }

    private static var importedFootnote: String {
        #if os(macOS)
        String(localized: "transcript_reader_font_imported_footer_mac")
        #else
        String(localized: "transcript_reader_font_imported_footer")
        #endif
    }

    /// 要下载的标朵云,下载中画一圈进度,失败标个感叹号,这台设备没有的导入字体标个问号。
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
        case .unavailable:
            Image(systemName: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(5)
        }
    }

    static func stateAccessibilityText(_ state: PlayerTextFontLibrary.State) -> Text {
        switch state {
        case .available: Text(verbatim: "")
        case .needsDownload: Text("transcript_reader_font_needs_download")
        case .downloading: Text("transcript_reader_font_downloading")
        case .failed: Text("transcript_reader_font_download_failed")
        case .unavailable: Text("transcript_reader_font_unavailable")
        }
    }
}

/// 字体块的底与选中描边。
private struct PlayerTextFontChipStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
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
    }
}
#endif
