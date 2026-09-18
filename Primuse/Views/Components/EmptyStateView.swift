import SwiftUI

/// Lightweight pulse shared by full-page loading placeholders. It animates a
/// single container opacity instead of driving every skeleton block on its own,
/// keeping large dashboards inexpensive while still making the loading state
/// feel alive. Reduce Motion keeps the same layout without animation.
struct LoadingSkeletonGroup<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .opacity(reduceMotion ? 0.82 : (isDimmed ? 0.58 : 0.92))
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 1.08).repeatForever(autoreverses: true),
                value: isDimmed
            )
            .onAppear {
                isDimmed = !reduceMotion
            }
            .onChange(of: reduceMotion) { _, newValue in
                isDimmed = !newValue
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Reusable empty-state view for sub-pages (library lists, queue,
/// recently deleted, smart playlist no-match, etc.). Three goals:
///
/// 1. **Visual consistency** — every empty state across the app
///    looks like it came from the same designer instead of N
///    different `ContentUnavailableView` flavors.
/// 2. **Lightweight by default** — empty states render as compact SF
///    Symbol compositions. Search/library/tool surfaces should feel like
///    app UI, not a gallery of one-off posters.
/// 3. **Action-aware** — supports an optional CTA button so views
///    that have a recovery path ("add a source", "create a
///    playlist") get a single tap to fix the empty state.
///
/// Use this in preference to `ContentUnavailableView` whenever the
/// empty state is content-related ("no songs in library", "smart
/// playlist matched nothing"). Keep `ContentUnavailableView.search`
/// for the system-styled search empty state — Apple's version
/// already has the perfect treatment for that one specific case.
struct EmptyStateView: View {
    let titleKey: LocalizedStringKey
    let descriptionKey: LocalizedStringKey?
    let systemImage: String
    let actionLabel: LocalizedStringKey?
    let action: (() -> Void)?

    @Environment(\.pmHeightClass) private var heightClass

    init(
        titleKey: LocalizedStringKey,
        descriptionKey: LocalizedStringKey? = nil,
        systemImage: String,
        actionLabel: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.titleKey = titleKey
        self.descriptionKey = descriptionKey
        self.systemImage = systemImage
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        VStack(spacing: 18) {
            illustration
            VStack(spacing: 6) {
                Text(titleKey)
                    .font(.title3).fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                if let descriptionKey {
                    Text(descriptionKey)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .fontWeight(.medium)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        // 手机横屏纵向只剩三百多点，空态再占 32 的上下留白就会把 CTA 顶出可视区。
        .padding(.vertical, heightClass.value(32, compact: 16))
        // 空态几乎都是「加载完发现没东西」才出现的，组件内部淡一下，全 App 的空态
        // 就都不再是硬切。只动透明度，不影响调用方的布局。
        .pmAppearFade(.contentAppear)
    }

    private var illustration: some View {
        EmptyStateGlyph(systemImage: systemImage)
    }
}

private struct EmptyStateGlyph: View {
    let systemImage: String

    @Environment(\.pmHeightClass) private var heightClass

    private var accentSymbol: String {
        switch systemImage {
        case "magnifyingglass":
            "music.note"
        case "music.note", "music.note.list":
            "waveform"
        case "square.stack":
            "music.note"
        case "music.mic":
            "person.wave.2"
        case "trash":
            "arrow.uturn.backward"
        default:
            "sparkles"
        }
    }

    var body: some View {
        // 手机横屏收一档。字号、偏移、图标框按同一个系数等比缩 —— 只缩图标框的话，
        // 右上角那枚副符号会被挤到框外。
        let scale = heightClass.value(1, compact: 0.75)
        let accentSize: CGFloat = 24 * scale
        let accentOffsetX: CGFloat = 28 * scale
        let accentOffsetY: CGFloat = -22 * scale
        let mainSize: CGFloat = 54 * scale
        let mainOffsetX: CGFloat = -3 * scale
        let mainOffsetY: CGFloat = 4 * scale
        let boxWidth: CGFloat = 112 * scale
        let boxHeight: CGFloat = 88 * scale

        ZStack {
            Image(systemName: accentSymbol)
                .font(.system(size: accentSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary.opacity(0.28))
                .offset(x: accentOffsetX, y: accentOffsetY)

            Image(systemName: systemImage)
                .font(.system(size: mainSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .offset(x: mainOffsetX, y: mainOffsetY)
        }
        .frame(width: boxWidth, height: boxHeight)
        .accessibilityHidden(true)
    }
}
