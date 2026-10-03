import SwiftUI
import PrimuseKit

/// 电视专辑页 / 艺人页右栏顶上的「关于这张专辑」「关于这位艺人」。
/// 有简介时像影片介绍页那样直接是风格、几行摘录和来源,不套卡片,按下打开全文;
/// 还没有时是一张「生成简介」卡片。长按可以重新生成或删除。编辑在 iPhone、iPad 或 Mac 上做,随曲库同步过来。
struct TVLibraryInsightBlock: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(TVStore.self) private var tvStore

    /// 只用名字认出是哪张专辑/哪位艺人;曲目、风格在按下生成时才由 `details` 收集。
    let subject: LibraryInsightSubject
    let details: () -> LibraryInsightSubject

    @State private var showsReader = false
    @State private var excerptHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var store: LibraryInsightStore { .shared }

    private var canAskAI: Bool {
        intelligence.isLibraryInsightAvailable
            || intelligence.libraryInsightNeedsRemoteConsent
            || intelligence.shouldExposeRemoteConfiguration
    }

    var body: some View {
        let insight = store.record(for: subject, in: tvStore.library)
        let showsSynopsis = insight?.hasContent == true
        if LibraryInsightStore.isIntroducible(subject), insight != nil || canAskAI {
            VStack(alignment: .leading, spacing: 14) {
                if !showsSynopsis {
                    TVEyebrow(text: (subject.kind == .album ? String(localized: "library_insight_album_title") : String(localized: "library_insight_artist_title")))
                }
                TVFocusButton(radius: 18, scale: 1.02, lift: 4, action: { primaryAction(insight) }) { focused in
                    Group {
                        if let insight, showsSynopsis {
                            synopsis(insight, focused: focused)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 20)
                        } else {
                            content(insight)
                                .padding(26)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 摘录平时直接压在底图上,焦点到了才托起一层底。
                    .background(
                        TVColor.surface.opacity(showsSynopsis && !focused ? 0 : 1),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                }
                .fullScreenCover(isPresented: $showsReader) {
                    TVLibraryInsightReader(subject: subject)
                        .environment(tvStore)
                }
                .contextMenu {
                    if let insight, !store.isGenerating(subject) {
                        // 自己写的简介在电视上不给一键覆盖。
                        if !insight.isWorthKeeping, canAskAI {
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
            #if DEBUG
            .task { await debugSeedIfRequested() }
            #endif
        }
    }

    #if DEBUG
    /// 截图用:`TV_INSIGHT_DEBUG=1` 给打开的专辑 / 艺人写一段示例简介(已有的不覆盖),
    /// `=reader` 另在两秒后打开全文面板。
    private func debugSeedIfRequested() async {
        guard let mode = ProcessInfo.processInfo.environment["TV_INSIGHT_DEBUG"] else { return }
        if store.record(for: subject, in: tvStore.library) == nil {
            store.saveEdit(
                subject,
                summary: """
                    Recorded over one long winter, this album trades the band's early guitar sound for analog synths \
                    and drum machines. The songs move from late-night city drives to quiet bedroom confessions, and \
                    the closing track stretches past nine minutes.

                    Critics at the time were divided, but it has since become the record most fans start with.
                    """,
                tags: ["Synth-pop", "New wave", "1980s"],
                aiDraft: nil,
                library: tvStore.library
            )
        }
        guard mode == "reader" else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        showsReader = true
    }
    #endif

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
                Text((subject.kind == .album ? String(localized: "library_insight_unknown_album") : String(localized: "library_insight_unknown_artist")))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: LibraryInsightStore.footer(for: insight))
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
                // 按下就重新问一次(换了服务或提示词之后可能就认识了)。
                if canAskAI {
                    Label(String(localized: "library_insight_regenerate"), systemImage: "sparkles")
                        .tvFont(.caption, weight: .semibold)
                        .foregroundStyle(TVColor.text)
                }
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

    /// 风格一行、四行摘录、来源一行;重新生成中或刚失败时来源那行换成状态。
    private func synopsis(_ insight: LibraryInsightRecord, focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !insight.tags.isEmpty {
                Text(verbatim: insight.tags.joined(separator: " · "))
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
            }
            if !insight.summary.isEmpty {
                Text(verbatim: insight.summary)
                    .tvFont(.body)
                    .foregroundStyle(TVColor.text)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { excerptHeight = $0 }
                    .background(alignment: .topLeading) {
                        // 不限行数时有多高:比摘录高才露出「更多」。
                        Text(verbatim: insight.summary)
                            .tvFont(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    }
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Group {
                    if store.isGenerating(subject) {
                        Text(String(localized: "library_insight_generating"))
                    } else if let failure = store.failure(for: subject) {
                        Text(verbatim: LibraryInsightStore.message(for: failure))
                    } else {
                        Text(verbatim: LibraryInsightStore.footer(for: insight))
                    }
                }
                .tvFont(.meta)
                .foregroundStyle(TVColor.textFaint)
                .lineLimit(1)
                Spacer(minLength: 0)
                // 焦点态不增删元素:没截断时只是透明占位。
                Text(String(localized: "more"))
                    .tvFont(.meta, weight: .semibold)
                    .foregroundStyle(focused ? TVColor.text : TVColor.textMuted)
                    .opacity(fullHeight > excerptHeight + 1 ? 1 : 0)
            }
        }
    }

    private func primaryAction(_ insight: LibraryInsightRecord?) {
        if let insight, insight.hasContent {
            showsReader = true
            return
        }
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
        if canAskAI {
            generate()
        }
    }

    private func generate() {
        let full = details()
        Task { await store.generate(full, library: tvStore.library, intelligence: intelligence) }
    }
}

/// 简介全文:居中面板,跟点评编辑同一种弹框。Menu 或「完成」关掉。
private struct TVLibraryInsightReader: View {
    @Environment(TVStore.self) private var tvStore
    @Environment(\.dismiss) private var dismiss

    let subject: LibraryInsightSubject

    private var store: LibraryInsightStore { .shared }

    var body: some View {
        let insight = store.record(for: subject, in: tvStore.library)
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            card(insight)
                .padding(.horizontal, 90)
                .padding(.vertical, 60)
        }
        .onExitCommand { dismiss() }
    }

    private var title: String {
        subject.kind == .album ? subject.albumTitle : subject.artistName
    }

    private func card(_ insight: LibraryInsightRecord?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: subject.kind == .album
                ? String(localized: "library_insight_album_title")
                : String(localized: "library_insight_artist_title"))
            Text(verbatim: title)
                .tvFont(.pageTitle)
                .foregroundStyle(TVColor.text)
                .lineLimit(2)
                .padding(.top, 10)
            if subject.kind == .album, !subject.artistName.isEmpty {
                Text(verbatim: subject.artistName)
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
                    .padding(.top, 6)
            }
            if let insight, !insight.tags.isEmpty {
                Text(verbatim: insight.tags.joined(separator: " · "))
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
                    .padding(.top, 14)
            }
            Rectangle().fill(TVColor.divider)
                .frame(height: 1)
                .padding(.top, 26).padding(.bottom, 28)

            if let insight, !insight.summary.isEmpty {
                // 自己写的简介可能比 AI 的长,面板放不下时字缩小一些,不出滚动。
                Text(verbatim: insight.summary)
                    .tvFont(.body)
                    .lineSpacing(6)
                    .foregroundStyle(TVColor.text)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: 560, alignment: .topLeading)
            }
            if let insight {
                Text(verbatim: LibraryInsightStore.footer(for: insight))
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
                    .padding(.top, 22)
            }

            HStack {
                Spacer(minLength: 0)
                TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: { dismiss() }) { focused in
                    Text(String(localized: "done"))
                        .tvFont(.button)
                        .foregroundStyle(TVColor.text)
                        .padding(.horizontal, 30).padding(.vertical, 16)
                        .frame(minWidth: 220)
                        .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.top, 32)
        }
        .padding(.horizontal, 64).padding(.vertical, 52)
        .frame(maxWidth: 1400, alignment: .leading)
        .tvPanel(radius: 26)
    }
}
