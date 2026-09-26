#if os(iOS)
import SwiftUI
import PrimuseKit

// 首启引导里两页「怎么用」：添加音乐源的三步，和播放页上几个常用入口。
//
// 上半部分是照真实界面画的小样，下半部分是逐条说明，两者同步高亮。小样里的
// 标题、按钮名和提示语直接取真实界面用的那批文案 key，所以每种语言里看到的
// 字和 App 里一致。真实界面改版时这里要跟着改，对应的真实视图是：
// SourcesView（音乐源列表）、AddSourceView + SourceAddressRowView（单地址表单）、
// ConnectorDirectoryBrowserView + DirectoryCheckRow（选目录）、NowPlayingView（播放页）。

// MARK: - 添加音乐源

struct OnboardingSourcesGuidePage: View {
    /// 翻到这一页时才自动轮播、才让提示光圈动起来。
    let isActive: Bool

    @State private var step = 0
    /// 用户点了某一步后换一个值，让轮播从那一步重新计时。
    @State private var restartToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animatesHotspot: Bool { isActive && !reduceMotion }

    var body: some View {
        OnboardingGuideLayout(
            title: String(localized: "onboarding_guide_sources_title"),
            subtitle: nil,
            footer: String(localized: "onboarding_guide_sources_footer")
        ) {
            OnboardingGuidePhone {
                ZStack {
                    switch step {
                    case 0:
                        sourcesListScreen.pmFadeTransition(motion: .pageSwitch)
                    case 1:
                        addressScreen.pmFadeTransition(motion: .pageSwitch)
                    default:
                        foldersScreen.pmFadeTransition(motion: .pageSwitch)
                    }
                }
            }
        } steps: {
            ForEach(0..<3, id: \.self) { index in
                OnboardingGuideStepRow(
                    marker: .number(index + 1),
                    text: stepText(index),
                    isCurrent: step == index
                ) {
                    select(index)
                }
            }
        }
        .task(id: "\(isActive)-\(reduceMotion)-\(restartToken)") {
            guard isActive, !reduceMotion else { return }
            while true {
                do { try await Task.sleep(for: .seconds(2.8)) } catch { return }
                pmWithAnimation(.pageSwitch) { step = (step + 1) % 3 }
            }
        }
    }

    private func select(_ index: Int) {
        pmWithAnimation(.pageSwitch) { step = index }
        restartToken += 1
    }

    private func stepText(_ index: Int) -> String {
        switch index {
        case 0:
            let path = "\(String(localized: "settings_title")) › \(String(localized: "sources_title"))"
            return String(format: String(localized: "onboarding_guide_sources_step1 %@"), path)
        case 1:
            return String(localized: "onboarding_guide_sources_step2")
        default:
            return String(format: String(localized: "onboarding_guide_sources_step3 %@"), String(localized: "done"))
        }
    }

    /// 第一步：设置 › 音乐源，还没有任何音乐源时的样子，右上角的 + 就是入口。
    private var sourcesListScreen: some View {
        VStack(spacing: 0) {
            OnboardingGuideNavBar(
                leading: "‹ \(String(localized: "settings_title"))",
                title: String(localized: "sources_title")
            ) {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                        .onboardingGuideHotspot(cornerRadius: 11, animates: animatesHotspot)
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.45))
                Text(String(localized: "no_sources"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(String(localized: "no_sources_desc"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                Label(String(localized: "add_source"), systemImage: "plus.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: .capsule)
                    .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
    }

    /// 第二步：以群晖为例，只填一个地址；下面那行说明用的是表单里真实的解读文案。
    private var addressScreen: some View {
        let address = "192.168.1.10"
        let reading = String(
            format: String(localized: "source_address_reading_auto %@ %@"),
            address,
            "5001"
        )
        let readingLine = "\(String(localized: "source_connection_local")) · \(reading)"

        return VStack(spacing: 0) {
            OnboardingGuideNavBar(
                leading: String(localized: "cancel"),
                title: MusicSourceType.synology.displayName
            ) {
                Text("Next")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "source_address_section"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: address)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    Text(readingLine)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10))
                .onboardingGuideHotspot(cornerRadius: 10, animates: animatesHotspot)

                VStack(spacing: 0) {
                    OnboardingGuideFormRow(label: String(localized: "username"), value: "admin")
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.leading, 10)
                    OnboardingGuideFormRow(label: String(localized: "password"), value: "••••••••")
                }
                .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10))
                .padding(.top, 8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
    }

    /// 第三步：勾选放音乐的文件夹。群晖默认的共享文件夹就叫 music / photo / video。
    private var foldersScreen: some View {
        VStack(spacing: 0) {
            OnboardingGuideNavBar(
                leading: String(localized: "cancel"),
                title: MusicSourceType.synology.displayName
            ) {
                Text(String(localized: "done"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
                    .onboardingGuideHotspot(cornerRadius: 8, animates: animatesHotspot)
            }

            VStack(spacing: 0) {
                OnboardingGuideFolderRow(name: "music", isSelected: true)
                folderDivider
                OnboardingGuideFolderRow(name: "photo", isSelected: false)
                folderDivider
                OnboardingGuideFolderRow(name: "video", isSelected: false)
            }
            .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 0.5)
                Label(selectedText, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
        }
    }

    private var selectedText: String {
        "1 \(String(localized: "directories_selected"))"
    }

    private var folderDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 34)
    }
}

// MARK: - 播放页

struct OnboardingPlayerGuidePage: View {
    let isActive: Bool

    @State private var focus = 0
    @State private var restartToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animatesHotspot: Bool { isActive && !reduceMotion }

    /// 与播放页真实按钮一一对应：底部一排的歌词、AirPlay、队列，标题旁的「…」。
    private static let symbols = ["quote.bubble", "airplayaudio", "list.bullet", "ellipsis"]

    var body: some View {
        OnboardingGuideLayout(
            title: String(localized: "onboarding_guide_player_title"),
            subtitle: String(localized: "onboarding_guide_player_subtitle"),
            footer: nil
        ) {
            OnboardingGuidePhone { playerScreen }
        } steps: {
            ForEach(0..<Self.symbols.count, id: \.self) { index in
                OnboardingGuideStepRow(
                    marker: .symbol(Self.symbols[index]),
                    text: itemText(index),
                    isCurrent: focus == index
                ) {
                    pmWithAnimation(.selection) { focus = index }
                    restartToken += 1
                }
            }
        }
        .task(id: "\(isActive)-\(reduceMotion)-\(restartToken)") {
            guard isActive, !reduceMotion else { return }
            while true {
                do { try await Task.sleep(for: .seconds(2.6)) } catch { return }
                pmWithAnimation(.selection) { focus = (focus + 1) % Self.symbols.count }
            }
        }
    }

    private func itemText(_ index: Int) -> String {
        switch index {
        case 0: return String(localized: "onboarding_guide_player_lyrics")
        case 1: return String(localized: "onboarding_guide_player_airplay")
        case 2: return String(localized: "onboarding_guide_player_queue")
        default: return String(localized: "onboarding_guide_player_more")
        }
    }

    private var playerScreen: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 112, height: 112)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 16)

            // 标题与艺术家用占位条，右侧是真实界面里的收藏和「…」。
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 92, height: 8)
                    Capsule()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 60, height: 7)
                }
                Spacer(minLength: 0)
                Image(systemName: "heart")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                playerIcon(3, size: 12)
            }

            VStack(spacing: 3) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 3)
                    Capsule()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 72, height: 3)
                }
                HStack {
                    Text(verbatim: "1:24")
                    Spacer(minLength: 0)
                    Text(verbatim: "-2:28")
                }
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }

            HStack {
                Image(systemName: "shuffle").font(.system(size: 11))
                Spacer(minLength: 0)
                Image(systemName: "backward.fill").font(.system(size: 14))
                Spacer(minLength: 0)
                Image(systemName: "pause.fill").font(.system(size: 22))
                Spacer(minLength: 0)
                Image(systemName: "forward.fill").font(.system(size: 14))
                Spacer(minLength: 0)
                Image(systemName: "repeat").font(.system(size: 11))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)

            HStack(spacing: 10) {
                playerIcon(0, size: 12)
                playerIcon(1, size: 12)
                playerIcon(2, size: 12)
                Spacer(minLength: 0)
                Text(verbatim: "FLAC")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    private func playerIcon(_ index: Int, size: CGFloat) -> some View {
        Image(systemName: Self.symbols[index])
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(focus == index ? 0.95 : 0.6))
            .frame(width: 24, height: 24)
            .onboardingGuideHotspot(
                cornerRadius: 12,
                animates: animatesHotspot,
                isOn: focus == index
            )
    }
}

// MARK: - 共用部件

/// 两页共用的版式：标题、说明、小样、步骤、脚注。放进竖向滚动里，
/// 小屏机型（如 iPhone SE）放不下时可以往下滑，而不是把小样挤扁。
private struct OnboardingGuideLayout<Screen: View, Steps: View>: View {
    let title: String
    let subtitle: String?
    let footer: String?
    let screen: Screen
    let steps: Steps

    init(
        title: String,
        subtitle: String?,
        footer: String?,
        @ViewBuilder screen: () -> Screen,
        @ViewBuilder steps: () -> Steps
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.screen = screen()
        self.steps = steps()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.72))
                }

                screen

                VStack(alignment: .leading, spacing: 4) {
                    steps
                }

                if let footer {
                    Text(footer)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        #if os(iOS)
        // iPhone Duo：引导页整屏居中后，标题从页顶开始，别让它落进竖排状态栏与摄像头那块遮挡区。
        // 没有遮挡区时传 nil，保持系统默认的边距。
        .contentMargins(.top, occlusionClearance > 0 ? occlusionClearance : nil, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { proxy in
            // 只看贴着上沿的遮挡区;遮挡区在下半屏时(外屏横握摄像头在右下角)不把标题往下推。
            max(0, CGFloat(OcclusionAvoidancePolicy.topEdge(
                of: PMReservedRegions.activeOcclusions(in: proxy),
                height: Double(proxy.size.height)
            )))
        } action: { lowest in
            occlusionClearance = lowest
        }
        #endif
    }

    @State private var occlusionClearance: CGFloat = 0
}

/// 手机屏幕的小样。固定深色，跟引导页的深色底融在一起；内容只是示意，
/// 读屏跳过它，说明交给下面的步骤文字。
private struct OnboardingGuidePhone<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: 248, height: 280)
            .background(Color(white: 0.085))
            .clipShape(.rect(cornerRadius: 30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
    }
}

/// 小样里的导航栏：左边返回/取消，中间标题，右边按钮。
private struct OnboardingGuideNavBar<Trailing: View>: View {
    let leading: String
    let title: String
    let trailing: Trailing

    init(leading: String, title: String, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 66)

            HStack(spacing: 0) {
                Text(leading)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .padding(.top, 6)
    }
}

private struct OnboardingGuideFormRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

/// 对应真实的 DirectoryCheckRow：左边圆形勾选，蓝色文件夹，右边进入下一级的箭头。
private struct OnboardingGuideFolderRow: View {
    let name: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.accentColor : Color.gray.opacity(0.5))
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.blue)
            Text(verbatim: name)
                .font(.system(size: 11))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

private struct OnboardingGuideStepRow: View {
    enum Marker {
        case number(Int)
        case symbol(String)
    }

    let marker: Marker
    let text: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                markerView
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(isCurrent ? 0.96 : 0.58))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(isCurrent ? 0.1 : 0), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pmAnimation(.selection, value: isCurrent)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private var markerView: some View {
        switch marker {
        case .number(let number):
            Text(verbatim: "\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isCurrent ? Color.black : Color.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(isCurrent ? 0.95 : 0.14), in: .circle)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.white.opacity(0.6))
                .frame(width: 22, height: 22)
        }
    }
}

/// 小样里「点这里」的提示：一圈主题色描边，外面再扩散一圈光晕。
/// 光晕靠 TimelineView 按时间算，不走动画事务，翻页时不会被带着一起动。
private struct OnboardingGuideHotspot: ViewModifier {
    let cornerRadius: CGFloat
    let animates: Bool
    let isOn: Bool

    private static let period: Double = 1.4

    func body(content: Content) -> some View {
        content.overlay {
            if isOn {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    if animates {
                        TimelineView(.animation) { context in
                            let elapsed = context.date.timeIntervalSinceReferenceDate
                            let phase = elapsed.truncatingRemainder(dividingBy: Self.period) / Self.period
                            let scale = CGFloat(1 + 0.35 * phase)
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.7 * (1 - phase)), lineWidth: 2)
                                .scaleEffect(scale)
                        }
                    }
                }
                .padding(-4)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

private extension View {
    func onboardingGuideHotspot(cornerRadius: CGFloat, animates: Bool, isOn: Bool = true) -> some View {
        modifier(OnboardingGuideHotspot(cornerRadius: cornerRadius, animates: animates, isOn: isOn))
    }
}
#endif
