import SwiftUI
import PrimuseKit

#if os(macOS)
private struct MacOnboardingProtocolGroup: Identifiable {
    var title: String
    var items: [String]
    var id: String { title }
}
#endif

/// 首启引导。iOS 只展示具体能力：
/// 「音乐源 → 元数据增强 → 播放体验 → 个性化」。
/// 设置页也能以 feature-guide 模式重新打开。
/// 任何路径关闭后都把 `primuse.hasSeenOnboarding` 写 true，后续启动不再弹。
///
/// 设计理由:
/// - 用户装上 app 啥都没,直接进资料库会看到空状态,容易直接卸载
/// - App Store 审核员也是同样体验,1.2(a) "Information Needed" 跟这个有关
/// - 类似 Apple Music / Cider 都有 onboarding,用户接受度高
struct OnboardingView: View {
    var isFeatureGuide = false

    @AppStorage("primuse.hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @State private var pageIndex = 0
    @State private var presentAddSource = false
    @Environment(\.dismiss) private var dismiss

    private var pageCount: Int {
        #if os(macOS)
        3
        #else
        4
        #endif
    }

    var body: some View {
        content
            .modifier(OnboardingAddSourceCoverModifier(
                presentAddSource: $presentAddSource,
                finish: finish
            ))
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        macBody
        #else
        ZStack {
            // 保留深色沉浸感，但让光晕跟随用户当前主题色，不把品牌锁死为深紫色。
            Color(red: 0.018, green: 0.022, blue: 0.035)
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.50),
                    Color.accentColor.opacity(0.10),
                    .clear,
                ],
                center: .topLeading,
                startRadius: 10,
                endRadius: 520
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    .clear,
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 420
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .clear,
                    Color.black.opacity(0.34),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack {
                Spacer()

                TabView(selection: $pageIndex) {
                    sourcesPage.tag(0)
                    metadataPage.tag(1)
                    experiencePage.tag(2)
                    personalizationPage.tag(3)
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
                .frame(maxHeight: .infinity)

                pageDots
                    .padding(.bottom, 8)

                bottomButtons
                    .padding(.horizontal, 32)
                    .padding(.bottom, 36)
            }
        }
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        ZStack {
            AmbientBackdrop(
                accent: Color(red: 0.79, green: 0.39, blue: 0.26),
                darkAccent: Color(red: 0.15, green: 0.29, blue: 0.43),
                strength: 0.72
            )
            .ignoresSafeArea()

            Color(red: 0.055, green: 0.050, blue: 0.044)
                .opacity(0.56)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                macTitleBar
                macStepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 56)
                    .padding(.vertical, 20)
                macFooter
            }
        }
        .foregroundStyle(Color(red: 0.95, green: 0.93, blue: 0.91))
        .frame(minWidth: 720, minHeight: 560)
    }

    private var macTitleBar: some View {
        HStack(spacing: 14) {
            PMWindowTrafficLights(closeOnly: true)
            Spacer()
            Text(String(format: String(localized: "onboarding_mac_step_format"), pageIndex + 1))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    @ViewBuilder
    private var macStepContent: some View {
        switch pageIndex {
        case 0:
            macWelcomePage
        case 1:
            macProtocolsPage
        default:
            macAddSourcePage
        }
    }

    private var macFooter: some View {
        HStack(spacing: 12) {
            Button {
                if pageIndex > 0 {
                    withAnimation(.easeInOut(duration: 0.2)) { pageIndex -= 1 }
                } else {
                    finish()
                }
            } label: {
                Text(pageIndex > 0
                     ? String(localized: "onboarding_mac_back")
                     : String(localized: "onboarding_mac_skip"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(height: 32)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { idx in
                    Capsule()
                        .fill(idx == pageIndex ? Color.white.opacity(0.92) : Color.white.opacity(0.30))
                        .frame(width: idx == pageIndex ? 24 : 6, height: 6)
                }
            }

            Spacer()

            Button {
                if pageIndex < pageCount - 1 {
                    withAnimation(.easeInOut(duration: 0.2)) { pageIndex += 1 }
                } else if isFeatureGuide {
                    finish()
                } else {
                    presentAddSource = true
                }
            } label: {
                Text(pageIndex == pageCount - 1
                     ? String(localized: isFeatureGuide ? "done" : "onboarding_mac_done")
                     : String(localized: "onboarding_mac_continue"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(height: 32)
                    .padding(.horizontal, 20)
                    .background(PMColor.brand, in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 56)
        .padding(.top, 20)
        .padding(.bottom, 32)
    }

    private var macWelcomePage: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Text(verbatim: "猿")
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 110, height: 110)
                .background {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [PMColor.brand, Color.black.opacity(0.62)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: PMColor.brand.opacity(0.5), radius: 36, y: 12)
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                        }
                }

            Text(String(localized: "onboarding_mac_welcome_title"))
                .font(.system(size: 40, weight: .bold))
                .multilineTextAlignment(.center)

            Text(String(localized: "onboarding_mac_welcome_desc"))
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 480)

            macGlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "onboarding_mac_privacy_title"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(String(localized: "onboarding_mac_privacy_desc"))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(4)
                }
                .frame(maxWidth: 480, alignment: .leading)
            }
            .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var macProtocolsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "onboarding_mac_sources_title"))
                .font(.system(size: 32, weight: .bold))
                .padding(.bottom, 8)

            Text(String(localized: "onboarding_mac_sources_desc"))
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.70))
                .padding(.bottom, 26)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(macProtocolGroups) { group in
                    macProtocolCard(group)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var macAddSourcePage: some View {
        VStack {
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                Text(String(localized: "onboarding_mac_add_first_title"))
                    .font(.system(size: 32, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)

                Text(String(localized: "onboarding_mac_add_first_desc"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.70))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)

                macGlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "onboarding_mac_connect_smb"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.62))

                        macSourceField(label: String(localized: "onboarding_mac_field_server"), value: "smb://10.0.0.4", monospaced: true)
                        macSourceField(label: String(localized: "onboarding_mac_field_share"), value: "Music", monospaced: true)
                        macSourceField(label: String(localized: "onboarding_mac_field_username"), value: "pan", monospaced: true)
                        macSourceField(label: String(localized: "onboarding_mac_field_password"), value: "••••••••", monospaced: false)

                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(PMColor.brand, in: .rect(cornerRadius: 3))
                            Text(String(localized: "onboarding_mac_keychain_note"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.70))
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                }
            }
            .frame(maxWidth: 520)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var macProtocolGroups: [MacOnboardingProtocolGroup] {
        [
            MacOnboardingProtocolGroup(title: String(localized: "onboarding_mac_group_local"), items: ["SMB / CIFS", "WebDAV", "SFTP", "FTP", "NFS", "S3", "UPnP / DLNA"]),
            MacOnboardingProtocolGroup(title: String(localized: "onboarding_mac_group_media_server"), items: ["Jellyfin", "Emby", "Plex", "Synology Audio Station", "QNAP", "UGREEN UGOS · API pending", "fnOS · API pending"]),
            MacOnboardingProtocolGroup(title: String(localized: "onboarding_mac_group_cloud"), items: ["123 Pan", "Baidu Pan", "Aliyun Drive", "Google Drive", "OneDrive", "Dropbox"]),
            MacOnboardingProtocolGroup(title: String(localized: "onboarding_mac_group_other"), items: ["Apple Music", String(localized: "onboarding_mac_source_local_file")]),
        ]
    }

    private func macProtocolCard(_ group: MacOnboardingProtocolGroup) -> some View {
        macGlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(group.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .textCase(.uppercase)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(group.items, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.86))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 23)
                            .background(Color.white.opacity(0.08), in: .capsule)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        }
    }

    private func macSourceField(label: String, value: String, monospaced: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.70))
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                }
        }
    }

    private func macGlassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(Color.white.opacity(0.075), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            }
    }
    #endif

    private var sourcesPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive.fill.badge.icloud")
                .font(.system(size: 80, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 12)

            Text(String(localized: "onboarding_sources_title"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            // 简短的支持类型清单 —— 不列出所有协议,挑用户最容易认识的
            VStack(alignment: .leading, spacing: 12) {
                onboardingRow("server.rack", "onboarding_sources_nas")
                onboardingRow("icloud.fill", "onboarding_sources_cloud")
                onboardingRow("applelogo", "onboarding_sources_apple_music")
                onboardingRow("network", "onboarding_sources_network")
            }
            .padding(.horizontal, 32)

            Text(String(localized: "onboarding_sources_footer"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 24)
        }
    }

    private var metadataPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 80, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 12)

            Text(String(localized: "onboarding_metadata_title"))
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                onboardingRow("photo.on.rectangle.angled", "onboarding_metadata_details")
                onboardingRow("puzzlepiece.extension.fill", "onboarding_metadata_providers")
                onboardingRow("slider.horizontal.3", "onboarding_metadata_settings")
            }
            .padding(.horizontal, 32)

            Text(String(localized: "onboarding_metadata_footer"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 24)
        }
    }

    private var experiencePage: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 80, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 12)

            Text(String(localized: "onboarding_experience_title"))
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                onboardingRow("music.note.tv.fill", "onboarding_experience_media")
                onboardingRow("airplayaudio", "onboarding_experience_devices")
                onboardingRow("chart.bar.xaxis", "onboarding_experience_insights")
            }
            .padding(.horizontal, 32)

            Text(String(localized: "onboarding_experience_footer"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 24)
        }
    }

    private var personalizationPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 80, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 12)

            Text(String(localized: "onboarding_personalization_title"))
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                onboardingRow("app.badge.fill", "onboarding_personalization_icon")
                onboardingRow("rectangle.3.group.fill", "onboarding_personalization_home")
                onboardingRow("star.square.on.square.fill", "onboarding_personalization_quick")
            }
            .padding(.horizontal, 32)

            Text(String(localized: "onboarding_personalization_footer"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 24)
        }
    }

    private func onboardingRow(_ icon: String, _ key: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 32)
            Text(String(localized: String.LocalizationValue(stringLiteral: key)))
                .font(.body)
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.leading)
            Spacer()
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { idx in
                Circle()
                    .fill(idx == pageIndex ? Color.white : Color.white.opacity(0.32))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var bottomButtons: some View {
        let isLastPage = pageIndex == pageCount - 1

        return VStack(spacing: 12) {
            Button {
                if !isLastPage {
                    withAnimation(.easeInOut(duration: 0.25)) { pageIndex += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(isLastPage ? String(localized: "done") : String(localized: "onboarding_next"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            }

            // 始终保留副按钮的固定高度。最后一页仅隐藏内容，不改变 footer
            // 高度，避免“完成”按钮突然向下跳。
            Button {
                finish()
            } label: {
                Text("close")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .opacity(isLastPage ? 0 : 1)
            .allowsHitTesting(!isLastPage)
            .accessibilityHidden(isLastPage)
        }
    }

    private func finish() {
        hasSeenOnboarding = true
        dismiss()
    }
}


/// macOS 没有 fullScreenCover, 用 sheet 替代显示 AddSourceView; iOS 上保持
/// 原 fullScreenCover 行为, 让 onboarding 后的资料库添加流程占满全屏。
private struct OnboardingAddSourceCoverModifier: ViewModifier {
    @Binding var presentAddSource: Bool
    var finish: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $presentAddSource) { sheetContent }
        #else
        content.sheet(isPresented: $presentAddSource) { sheetContent }
        #endif
    }

    private var sheetContent: some View {
        NavigationStack {
            SourceTypeSelectionView { source in
                AppServices.shared.sourcesStore.add(source)
                presentAddSource = false
                finish()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "skip")) {
                        presentAddSource = false
                        finish()
                    }
                }
            }
        }
    }
}
