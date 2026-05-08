import SwiftUI

/// 更新提示居中弹框 ── 走主流软件 (微信 / 小红书 / 抖音) 的简洁更新提示风格:
/// 不展示 release notes 长文 (用户进 App Store 自己看), 焦点放在"有新版"和
/// "立即更新"决策上。
///
/// 视觉跟 app 风格搭配 ── 用主题 accentColor 单色, 不再用紫蓝渐变 icon。
struct UpdateBannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppUpdateChecker.self) private var checker

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { /* 屏蔽外部点击 ── 强制做选择 */ }

            if let update = checker.availableUpdate {
                cardContent(update: update)
                    .frame(maxWidth: 300)
                    .padding(.horizontal, 32)
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .background(BackgroundClearView())
        .onChange(of: checker.availableUpdate) { _, newValue in
            if newValue == nil { dismiss() }
        }
    }

    @ViewBuilder
    private func cardContent(update: AppUpdateChecker.UpdateInfo) -> some View {
        VStack(spacing: 0) {
            // App icon ── 圆角方形 (跟 iOS app icon 一致), accentColor 主调,
            // 内部一个音符 + 向上箭头, 暗示"音乐 app 升级"。
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 76, height: 76)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 12, y: 4)
                Image(systemName: "music.note")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, Color.accentColor)
                    .offset(x: 22, y: -22)
            }
            .padding(.top, 28)
            .padding(.bottom, 18)

            // 标题: 猿音 + 版本号
            Text(String(format: String(localized: "update_modal_title_format"), update.version))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // 副标题: 一行话邀请, 不展开 release notes
            Text("update_modal_subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 28)

            // 主按钮: 立即更新
            Button {
                checker.openAppStore()
            } label: {
                Text("update_banner_now")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.horizontal, 20)
            .padding(.top, 22)

            // 次按钮: 稍后提醒
            Button {
                checker.snooze()
            } label: {
                Text("update_banner_later")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 4)

            // 跳过此版本: 弱链接样式藏底部 (高级用户能找到, 一般用户看不到)
            Button {
                checker.skipCurrentVersion()
            } label: {
                Text("update_banner_skip")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
    }
}

private struct BackgroundClearView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
