import SwiftUI
import PrimuseKit

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
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)

                pageDots
                    .padding(.bottom, 8)

                bottomButtons
                    .padding(.horizontal, 32)
                    .padding(.bottom, 36)
            }
        }
        .fullScreenCover(isPresented: $presentAddSource) {
            // 加完 source 关掉 onboarding。
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
