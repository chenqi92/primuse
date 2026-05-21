import SwiftUI

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
        .padding(.vertical, 32)
    }

    private var illustration: some View {
        EmptyStateGlyph(systemImage: systemImage)
    }
}

private struct EmptyStateGlyph: View {
    let systemImage: String

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
        ZStack {
            Image(systemName: accentSymbol)
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary.opacity(0.28))
                .offset(x: 28, y: -22)

            Image(systemName: systemImage)
                .font(.system(size: 54, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .offset(x: -3, y: 4)
        }
        .frame(width: 112, height: 88)
        .accessibilityHidden(true)
    }
}
