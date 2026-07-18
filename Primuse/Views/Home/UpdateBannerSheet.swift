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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
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
                    .padding(.top, 14)

                if let notes = update.releaseNotes,
                   !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    releaseNotesCard(notes)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
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
                .padding(.top, 20)
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
                .padding(.top, 15)
                .padding(.bottom, 20)
            }

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
                .frame(width: 128, height: 128)
                .blur(radius: 28)
                .offset(x: -84, y: -36)

            appIcon
                .frame(width: 82, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.20), radius: 14, y: 7)
        }
        .frame(height: 132)
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
                    .frame(maxHeight: verticalSizeClass == .compact ? 110 : 220)
                    .scrollIndicators(.visible)
                } else {
                    releaseNotesText(notes)
                        .lineLimit(4)
                }

                if releaseNotesNeedExpansion(notes) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
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
