import SwiftUI
import PrimuseKit

/// 电视专辑页 / 艺人页右栏顶上的「关于这张专辑」「关于这位艺人」。
/// 按下生成或展开全文;长按可以重新生成或删除。编辑在 iPhone、iPad 或 Mac 上做,随曲库同步过来。
struct TVLibraryInsightBlock: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(TVStore.self) private var tvStore

    /// 只用名字认出是哪张专辑/哪位艺人;曲目、风格在按下生成时才由 `details` 收集。
    let subject: LibraryInsightSubject
    let details: () -> LibraryInsightSubject

    @State private var isExpanded = false

    private var store: LibraryInsightStore { .shared }

    private var canAskAI: Bool {
        intelligence.isLibraryInsightAvailable
            || intelligence.libraryInsightNeedsRemoteConsent
            || intelligence.shouldExposeRemoteConfiguration
    }

    var body: some View {
        let insight = store.record(for: subject, in: tvStore.library)
        if LibraryInsightStore.isIntroducible(subject), insight != nil || canAskAI {
            VStack(alignment: .leading, spacing: 14) {
                TVEyebrow(text: (subject.kind == .album ? String(localized: "library_insight_album_title") : String(localized: "library_insight_artist_title")))
                TVFocusButton(radius: 18, scale: 1.02, lift: 4, action: { primaryAction(insight) }) { _ in
                    content(insight)
                        .padding(26)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .contextMenu {
                    if let insight, !store.isGenerating(subject) {
                        // 自己写的简介在电视上不给一键覆盖。
                        if !(insight.isUserEdited && insight.hasContent), canAskAI {
                            Button {
                                generate()
                            } label: {
                                Label(String(localized: "library_insight_regenerate"), systemImage: "arrow.clockwise")
                            }
                        }
                        Button(role: .destructive) {
                            store.remove(subject, library: tvStore.library)
                        } label: {
                            Label(String(localized: "library_insight_remove"), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.bottom, 18)
        }
    }

    @ViewBuilder
    private func content(_ insight: LibraryInsightRecord?) -> some View {
        if store.isGenerating(subject) {
            HStack(spacing: 14) {
                ProgressView()
                Text(String(localized: "library_insight_generating"))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
            }
        } else if let failure = store.failure(for: subject) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: LibraryInsightStore.message(for: failure))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text((failure == .needsConsent ? String(localized: "library_insight_allow_and_generate") : String(localized: "library_insight_retry")))
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(TVColor.text)
            }
        } else if let insight {
            VStack(alignment: .leading, spacing: 12) {
                if insight.hasContent {
                    if !insight.summary.isEmpty {
                        Text(verbatim: insight.summary)
                            .tvFont(.body)
                            .foregroundStyle(TVColor.text)
                            .lineLimit(isExpanded ? nil : 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !insight.tags.isEmpty {
                        Text(verbatim: insight.tags.joined(separator: " · "))
                            .tvFont(.caption, weight: .semibold)
                            .foregroundStyle(TVColor.textMuted)
                            .lineLimit(1)
                    }
                } else {
                    Text((subject.kind == .album ? String(localized: "library_insight_unknown_album") : String(localized: "library_insight_unknown_artist")))
                        .tvFont(.body)
                        .foregroundStyle(TVColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: LibraryInsightStore.footer(for: insight))
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text((subject.kind == .album ? String(localized: "library_insight_prompt_album") : String(localized: "library_insight_prompt_artist")))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Label(String(localized: "library_insight_generate"), systemImage: "sparkles")
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(TVColor.text)
            }
        }
    }

    private func primaryAction(_ insight: LibraryInsightRecord?) {
        guard !store.isGenerating(subject) else { return }
        if let failure = store.failure(for: subject) {
            if failure == .needsConsent {
                do {
                    try intelligence.grantRemoteConsent()
                } catch {
                    return
                }
            }
            guard store.retryDate(for: subject) == nil else { return }
            generate()
            return
        }
        if let insight, insight.hasContent {
            isExpanded.toggle()
        } else if canAskAI {
            generate()
        }
    }

    private func generate() {
        isExpanded = false
        let full = details()
        Task { await store.generate(full, library: tvStore.library, intelligence: intelligence) }
    }
}
