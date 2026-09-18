import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 轻量更新卡片。使用用户当前选择的真实 App 图标，把信息收敛成：
/// 新版本 → 版本变化 → 更新摘要 → 主操作。普通更新不是强制升级，因此
/// 关闭按钮和点击遮罩都等同于「稍后提醒」，不会把用户困在弹框中。
struct UpdateBannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppUpdateChecker.self) private var checker
    @Environment(\.pmHeightClass) private var heightClass
    @State private var isNotesExpanded = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture { checker.snooze() }

            if let update = checker.availableUpdate {
                cardContent(update: update)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 22)
                    // 手机横屏下卡片会占满整个可用高度,不贴着上下边缘。
                    .padding(.vertical, heightClass.value(0, compact: 12))
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .background(BackgroundClearView())
        .onChange(of: checker.availableUpdate) { _, newValue in
            if newValue == nil { dismiss() }
            isNotesExpanded = false
        }
    }

    @ViewBuilder
    private func cardContent(update: AppUpdateChecker.UpdateInfo) -> some View {
        ZStack(alignment: .topTrailing) {
            // 折叠态的卡片本身就有四百多点高,手机横屏放不下,「立即更新 / 稍后 /
            // 跳过」会被挤出屏幕又滚不到。放得下就照旧按内容定高,放不下才滚 ——
            // 竖屏与 iPad 走的仍是第一支,布局分毫不变。
            ViewThatFits(in: .vertical) {
                cardBody(update: update)

                ScrollView {
                    cardBody(update: update)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            closeButton
        }
        #if os(iOS)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 28))
        #else
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 28))
        #endif
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.14), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 34, y: 14)
    }

    private var closeButton: some View {
        Button {
            checker.snooze()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.thinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(14)
        .accessibilityLabel(Text("close"))
    }

    @ViewBuilder
    private func cardBody(update: AppUpdateChecker.UpdateInfo) -> some View {
        VStack(spacing: 0) {
            updateHero

            Text(String(format: String(localized: "update_modal_title_format"), update.version))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text("update_modal_subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 28)

            versionTransition(to: update.version)
                .padding(.top, versionTopSpacing)

            if let notes = update.releaseNotes,
               !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                releaseNotesCard(notes)
                    .padding(.horizontal, 20)
                    .padding(.top, notesTopSpacing)
            }

            Button {
                checker.openAppStore()
                // Returning from the App Store should not immediately show
                // the same prompt again if the user postponed installation.
                checker.snooze()
            } label: {
                HStack(spacing: 8) {
                    Text("update_banner_now")
                        .font(.body.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.accentColor, in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, primaryActionTopSpacing)
            .shadow(color: Color.accentColor.opacity(0.24), radius: 10, y: 4)

            HStack(spacing: 14) {
                Button("update_banner_later") {
                    checker.snooze()
                }

                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1, height: 12)

                Button("update_banner_skip") {
                    checker.skipCurrentVersion()
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(.top, footerTopSpacing)
            .padding(.bottom, footerBottomSpacing)
        }
    }

    private var updateHero: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color.accentColor.opacity(0.04),
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: heroGlowSide, height: heroGlowSide)
                .blur(radius: 28)
                .offset(x: -84, y: heroGlowOffsetY)

            appIcon
                .frame(width: heroIconSide, height: heroIconSide)
                .clipShape(RoundedRectangle(cornerRadius: heroIconCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: heroIconCornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.20), radius: 14, y: 7)
        }
        .frame(height: heroHeight)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var appIcon: some View {
        #if os(iOS)
        let iconService = AppIconService.shared
        let option = iconService.options.first { $0.id == iconService.currentIconID }
            ?? iconService.options[0]
        Image(option.previewAsset)
            .resizable()
            .scaledToFill()
        #else
        ZStack {
            Color.accentColor
            Image(systemName: "music.note")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
        }
        #endif
    }

    private func versionTransition(to newVersion: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "v\(checker.installedVersion)")
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Text(verbatim: "v\(newVersion)")
                .foregroundStyle(Color.accentColor)
        }
        .font(.caption.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func releaseNotesCard(_ notes: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                Text("update_whats_new")
                    .font(.subheadline.weight(.semibold))

                if isNotesExpanded {
                    ScrollView {
                        releaseNotesText(notes)
                            .padding(.trailing, 4)
                    }
                    .frame(maxHeight: heightClass.value(220, compact: 110))
                    .scrollIndicators(.visible)
                } else {
                    releaseNotesText(notes)
                        .lineLimit(collapsedNotesLineLimit)
                }

                if releaseNotesNeedExpansion(notes) {
                    Button {
                        pmWithAnimation(.list) {
                            isNotesExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isNotesExpanded ? "update_show_less" : "update_show_more")
                            Image(systemName: isNotesExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 3)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
        #else
        .background(Color(NSColor.controlBackgroundColor), in: .rect(cornerRadius: 14))
        #endif
    }

    /// 手机横屏下整张卡要收一档 —— 头图、内边距、折叠态摘要各让出一点,
    /// 「立即更新 / 稍后 / 跳过」才留得在首屏里。竖屏与 iPad 取的都是原值。
    private var heroHeight: CGFloat { heightClass.value(132, compact: 72) }
    private var heroIconSide: CGFloat { heightClass.value(82, compact: 52) }
    private var heroIconCornerRadius: CGFloat { heightClass.value(19, compact: 13) }
    private var heroGlowSide: CGFloat { heightClass.value(128, compact: 88) }
    private var heroGlowOffsetY: CGFloat { heightClass.value(-36, compact: -22) }
    private var versionTopSpacing: CGFloat { heightClass.value(14, compact: 8) }
    private var notesTopSpacing: CGFloat { heightClass.value(18, compact: 10) }
    private var primaryActionTopSpacing: CGFloat { heightClass.value(20, compact: 12) }
    private var footerTopSpacing: CGFloat { heightClass.value(15, compact: 10) }
    private var footerBottomSpacing: CGFloat { heightClass.value(20, compact: 14) }
    private var collapsedNotesLineLimit: Int { heightClass.pick(4, compact: 2) }

    private func releaseNotesText(_ notes: String) -> some View {
        Text(notes)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func releaseNotesNeedExpansion(_ notes: String) -> Bool {
        notes.count > 180 || notes.filter(\.isNewline).count >= 4
    }
}

#if os(iOS)
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
#else
/// macOS 上 sheet 默认是不透明窗口背景, 不需要透明背景 trick。
private struct BackgroundClearView: View {
    var body: some View { Color.clear }
}
#endif
