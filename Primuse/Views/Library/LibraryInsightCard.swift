import SwiftUI
import PrimuseKit

/// 专辑页 / 艺人页里的「关于这张专辑」「关于这位艺人」:
/// 点一下让 AI 写一段简介和几个风格标签,结果缓存在本机,随时能重新生成。
struct LibraryInsightCard: View {
    @Environment(MusicIntelligenceService.self) private var intelligence

    /// 只用名字认出是哪张专辑/哪位艺人(缓存键);曲目、风格等在点「生成」时才由 `details` 收集。
    let subject: LibraryInsightSubject
    let details: () -> LibraryInsightSubject
    #if os(iOS)
    var tint: LibraryDetailTintStyle?
    #endif

    @State private var isExpanded = false

    private var store: LibraryInsightStore { .shared }

    private var canAskAI: Bool {
        intelligence.isLibraryInsightAvailable
            || intelligence.libraryInsightNeedsRemoteConsent
            || intelligence.shouldExposeRemoteConfiguration
    }

    var body: some View {
        let insight = store.insight(for: subject)
        if LibraryInsightStore.isIntroducible(subject), insight != nil || canAskAI {
            VStack(alignment: .leading, spacing: 10) {
                header
                content(insight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            #if os(iOS)
            .libraryDetailSection(tint: tint)
            #else
            .pmGlass(cornerRadius: PMRadius.m10)
            #endif
            .pmAnimation(.control, value: store.isGenerating(subject))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(
                subject.kind == .album
                    ? LocalizedStringKey("library_insight_album_title")
                    : LocalizedStringKey("library_insight_artist_title"),
                systemImage: "sparkles"
            )
            .font(.headline)
            Spacer(minLength: 8)
            if store.insight(for: subject) != nil, !store.isGenerating(subject) {
                Menu {
                    Button {
                        generate()
                    } label: {
                        Label("library_insight_regenerate", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canAskAI || store.retryDate(for: subject) != nil)
                    Button(role: .destructive) {
                        store.remove(subject)
                    } label: {
                        Label("library_insight_remove", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                #endif
                .accessibilityLabel(Text("more"))
            }
        }
    }

    @ViewBuilder
    private func content(_ insight: LibraryInsight?) -> some View {
        if store.isGenerating(subject) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("library_insight_generating")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let failure = store.failure(for: subject) {
            failureView(failure)
        } else if let insight {
            if insight.known {
                knownInsight(insight)
            } else {
                Text(subject.kind == .album
                    ? LocalizedStringKey("library_insight_unknown_album")
                    : LocalizedStringKey("library_insight_unknown_artist"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(subject.kind == .album
                    ? LocalizedStringKey("library_insight_prompt_album")
                    : LocalizedStringKey("library_insight_prompt_artist"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: generate) {
                    Label("library_insight_generate", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func knownInsight(_ insight: LibraryInsight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: insight.summary)
                .font(.subheadline)
                .lineSpacing(3)
                .lineLimit(isExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                #if os(macOS)
                .textSelection(.enabled)
                #endif
            if insight.summary.count > 90 {
                Button(isExpanded ? LocalizedStringKey("library_insight_less") : LocalizedStringKey("more")) {
                    isExpanded.toggle()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            if !insight.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(insight.tags, id: \.self) { tag in
                            Text(verbatim: tag)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
            Text(verbatim: String(
                format: String(localized: "library_insight_footer_format"),
                insight.providerName
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func failureView(_ failure: AILibraryContentFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: LibraryInsightStore.message(for: failure))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                switch failure {
                case .needsConsent:
                    Button("library_insight_allow_and_generate") {
                        do {
                            try intelligence.grantRemoteConsent()
                            generate()
                        } catch {
                            store.clearFailure(for: subject)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                case .notConfigured, .builtInNotOffered:
                    if intelligence.shouldExposeRemoteConfiguration {
                        settingsLink
                    }
                case .failed, .noTasteProfile:
                    Button(action: generate) {
                        Label("library_insight_retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.retryDate(for: subject) != nil)
                }
            }
        }
    }

    @ViewBuilder
    private var settingsLink: some View {
        #if os(macOS)
        Button("ai_song_discovery_open_settings") {
            SettingsWindowController.shared.show(tab: .intelligence)
        }
        .controlSize(.small)
        #else
        NavigationLink {
            AISettingsView()
                .minimalNavigationDetail()
        } label: {
            Text("ai_song_discovery_open_settings")
                .font(.subheadline.weight(.semibold))
        }
        #endif
    }

    private func generate() {
        isExpanded = false
        let full = details()
        Task { await store.generate(full, intelligence: intelligence) }
    }
}
