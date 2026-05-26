import SwiftUI
import PrimuseKit

#if os(macOS)
private struct MacOnboardingProtocolGroup: Identifiable {
    var title: String
    var items: [String]
    var id: String { title }
}
#endif

/// 首启引导。3 个 page —— 介绍 + 支持的音乐源 + 隐私承诺 —— 最后一页"开始使用"
/// 跳到 AddSourceView,引导用户立刻添加第一个源。任何路径关闭后都把
/// `primuse.hasSeenOnboarding` 写 true,后续启动不再弹。
///
/// 设计理由:
/// - 用户装上 app 啥都没,直接进资料库会看到空状态,容易直接卸载
/// - App Store 审核员也是同样体验,1.2(a) "Information Needed" 跟这个有关
/// - 类似 Apple Music / Cider 都有 onboarding,用户接受度高
struct OnboardingView: View {
    @AppStorage("primuse.hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @State private var pageIndex = 0
    @State private var presentAddSource = false
    @Environment(\.dismiss) private var dismiss

    private let pageCount = 3

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
            // 跟年度报告 / NowPlayingView 一致的紫蓝 ambient gradient
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.10, blue: 0.42),
                    Color(red: 0.05, green: 0.04, blue: 0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack {
                Spacer()

                TabView(selection: $pageIndex) {
                    welcomePage.tag(0)
                    sourcesPage.tag(1)
                    privacyPage.tag(2)
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
            PMWindowTrafficLights()
            Spacer()
            Text("步骤 \(pageIndex + 1) / 3")
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
                Text(pageIndex > 0 ? "上一步" : "跳过引导")
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
                } else {
                    presentAddSource = true
                }
            } label: {
                Text(pageIndex == pageCount - 1 ? "完成" : "继续")
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

            Text("猿")
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

            Text("欢迎使用猿音 Primuse")
                .font(.system(size: 40, weight: .bold))
                .multilineTextAlignment(.center)

            Text("一个为 NAS / 媒体服务器烧友打造的原生 macOS 播放器。让你的 FLAC、DSD、APE 在一个统一的资料库里安家。")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 480)

            macGlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("隐私承诺")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Primuse 不会上传你的资料库到任何云服务。所有播放历史、统计、设置都只通过你的 iCloud 同步。OAuth 授权一律走系统浏览器,我们绝不嵌 WebView 收集你的密码。")
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
            Text("来自任何地方")
                .font(.system(size: 32, weight: .bold))
                .padding(.bottom, 8)

            Text("Primuse 支持 21 种连接方式 · 你可以加任意多个源,会合并成一个统一的资料库。")
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
                Text("添加你的第一个音乐源")
                    .font(.system(size: 32, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)

                Text("你可以稍后在 Sources 里继续添加更多。")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.70))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)

                macGlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("连接到 SMB · NAS")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.62))

                        macSourceField(label: "服务器", value: "smb://10.0.0.4", monospaced: true)
                        macSourceField(label: "共享", value: "Music", monospaced: true)
                        macSourceField(label: "用户名", value: "pan", monospaced: true)
                        macSourceField(label: "密码", value: "••••••••", monospaced: false)

                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(PMColor.brand, in: .rect(cornerRadius: 3))
                            Text("将凭据保存到 macOS 钥匙串 · 跨 Mac 同步")
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
            MacOnboardingProtocolGroup(title: "本地协议", items: ["SMB / CIFS", "WebDAV", "SFTP", "FTP", "NFS", "S3 兼容", "UPnP / DLNA"]),
            MacOnboardingProtocolGroup(title: "媒体服务器", items: ["Jellyfin", "Emby", "Plex", "Synology Audio Station", "QNAP", "绿联 UGOS", "飞牛 fnOS"]),
            MacOnboardingProtocolGroup(title: "云盘", items: ["百度网盘", "阿里云盘", "Google Drive", "OneDrive", "Dropbox"]),
            MacOnboardingProtocolGroup(title: "其他", items: ["Apple Music", "本地文件 / iCloud Drive"]),
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

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Image(systemName: "music.note.list")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 12)

            VStack(spacing: 12) {
                Text(String(localized: "onboarding_welcome_title"))
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                Text(String(localized: "onboarding_welcome_subtitle"))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 24)
            }
        }
    }

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
                onboardingRow("network", "onboarding_sources_webdav")
                onboardingRow("dot.radiowaves.left.and.right", "onboarding_sources_dlna")
            }
            .padding(.horizontal, 32)

            Text(String(localized: "onboarding_sources_footer"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 24)
        }
    }

    private var privacyPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 80, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 12)

            Text(String(localized: "onboarding_privacy_title"))
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                onboardingRow("eye.slash.fill", "onboarding_privacy_no_tracking")
                onboardingRow("icloud.and.arrow.up.fill", "onboarding_privacy_icloud")
                onboardingRow("server.rack", "onboarding_privacy_local")
            }
            .padding(.horizontal, 32)
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
        VStack(spacing: 12) {
            Button {
                if pageIndex < pageCount - 1 {
                    withAnimation(.easeInOut(duration: 0.25)) { pageIndex += 1 }
                } else {
                    presentAddSource = true
                }
            } label: {
                Text(pageIndex < pageCount - 1
                     ? String(localized: "onboarding_next")
                     : String(localized: "onboarding_add_first_source"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            }

            Button {
                finish()
            } label: {
                Text(String(localized: pageIndex < pageCount - 1
                            ? "skip"
                            : "onboarding_later"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
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
