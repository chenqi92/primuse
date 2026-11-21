import PrimuseKit
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension View {
    /// 批量刮削（整库、专辑、艺人、多选）做完时的提示条。歌单发起的由歌单页自己说，这里不重复；
    /// 有没完成的歌时提示条带「查看」，点开列出是哪几首、哪一部分、为什么。开始前要把歌词写进音频
    /// 文件时的确认也由这里弹（用系统弹框，盖得住设置页这类弹出层）。挂在根视图上，全 App 一份。
    func batchScrapeCompletionFeedback() -> some View {
        modifier(BatchScrapeCompletionFeedbackModifier())
    }

    /// 弹出一轮批量刮削的结果：按部分的计数和没完成的歌。
    func batchScrapeResultSheet(_ report: Binding<BatchScrapeResultReport?>) -> some View {
        sheet(item: report) { report in
            BatchScrapeResultSheet(completion: report.completion)
        }
    }
}

/// 让一次完成结果能当 `sheet(item:)` 的条目。
struct BatchScrapeResultReport: Identifiable {
    let completion: MusicScraperService.BatchScrapeCompletion
    var id: UUID { completion.runID }
}

extension MusicScraperService.BatchScrapeCompletion {
    /// 提示条放不下全部几行、或者有没完成的歌时，给一个「查看」。
    var offersDetails: Bool {
        hasFailureDetails || summaryLines.count > 4
    }

    var feedbackSymbol: String {
        if hasAnyFailure { return appliedAnything ? "exclamationmark.triangle.fill" : "xmark.circle.fill" }
        return appliedAnything ? "checkmark.circle.fill" : "info.circle.fill"
    }

    var feedbackTint: Color {
        if hasAnyFailure { return appliedAnything ? .orange : .red }
        return appliedAnything ? .green : .secondary
    }
}

private struct BatchScrapeCompletionFeedbackModifier: ViewModifier {
    @Environment(MusicScraperService.self) private var scraperService
    @State private var report: BatchScrapeResultReport?

    private static let toastKey = "batchScrape.completion"

    func body(content: Content) -> some View {
        content
            .onChange(of: scraperService.completionRevision) { _, _ in
                present()
            }
            .onChange(of: scraperService.pendingLyricsEmbeddingConfirmation?.id, initial: true) { _, _ in
                if let confirmation = scraperService.pendingLyricsEmbeddingConfirmation {
                    let service = scraperService
                    BatchLyricsEmbeddingConfirmationPresenter.present(confirmation) { choice in
                        service.resolveLyricsEmbeddingConfirmation(choice)
                    }
                }
            }
            .batchScrapeResultSheet($report)
    }

    private func present() {
        guard let completion = scraperService.lastCompletion,
              completion.originPlaylistID == nil else { return }
        let action = completion.offersDetails
            ? PMToastItem.Action(title: String(localized: "scrape_tally_view_details")) {
                report = BatchScrapeResultReport(completion: completion)
            }
            : nil
        PMToastPresenter.shared.show(PMToastItem(
            key: Self.toastKey,
            message: completion.summaryText,
            systemImage: completion.feedbackSymbol,
            tint: completion.feedbackTint,
            duration: action == nil ? 5 : 8,
            action: action
        ))
    }
}

/// 设置页里上一轮批量刮削的结果：按部分的几行，有没完成的歌或放不下时给「查看」。
struct BatchScrapeLastResultRow: View {
    let completion: MusicScraperService.BatchScrapeCompletion
    @State private var report: BatchScrapeResultReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("scrape_tally_last_result")
                .font(.subheadline.weight(.medium))
            Text(verbatim: completion.summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if completion.offersDetails {
                Button("scrape_tally_view_details") {
                    report = BatchScrapeResultReport(completion: completion)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .batchScrapeResultSheet($report)
    }
}

/// 一轮批量刮削的结果：上面是按部分的计数，下面列出没完成的歌。
struct BatchScrapeResultSheet: View {
    let completion: MusicScraperService.BatchScrapeCompletion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(completion.summaryLines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                    }
                }
                if completion.hasFailureDetails {
                    Section {
                        ForEach(completion.tally.failures) { entry in
                            BatchScrapeFailureRow(entry: entry)
                        }
                    } header: {
                        Text("scrape_tally_failures_header")
                    } footer: {
                        if completion.tally.omittedFailureCount > 0 {
                            Text(verbatim: String(format: String(localized: "scrape_tally_failures_omitted_format"),
                                                  completion.tally.omittedFailureCount))
                        }
                    }
                }
            }
            .navigationTitle(Text("scrape_tally_result_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
    }
}

private struct BatchScrapeFailureRow: View {
    let entry: BatchScrapeFailureEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: entry.title)
                .font(.body)
                .lineLimit(2)
            Text(verbatim: BatchScrapeSummaryText.description(of: entry))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let detail = entry.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// 批量刮削开始前「会把歌词写进音频文件」的确认。用系统弹框：设置页、专辑页这些入口可能在弹出层里，
/// 挂在根视图上的 SwiftUI 弹框盖不住它们。找不到能弹的地方时按「这次不写进音频文件」继续，不悄悄嵌入。
@MainActor
enum BatchLyricsEmbeddingConfirmationPresenter {
    static func present(
        _ confirmation: MusicScraperService.LyricsEmbeddingConfirmation,
        resolve: @escaping @MainActor @Sendable (MusicScraperService.LyricsEmbeddingChoice) -> Void
    ) {
        let title = String(localized: "scrape_tally_embed_confirm_title")
        let message = String(format: String(localized: "scrape_tally_embed_confirm_message_format"), confirmation.songCount)
        let embedTitle = String(localized: "scrape_tally_embed_confirm_embed")
        let skipTitle = String(localized: "scrape_tally_embed_confirm_skip")
        let cancelTitle = String(localized: "cancel")
        #if os(iOS)
        guard let presenter = topMostViewController() else {
            plog("BatchLyricsEmbeddingConfirmation: no presenter, continuing without embedding lyrics")
            resolve(.skipEmbedding)
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: embedTitle, style: .default) { _ in
            Task { @MainActor in resolve(.embed) }
        })
        alert.addAction(UIAlertAction(title: skipTitle, style: .default) { _ in
            Task { @MainActor in resolve(.skipEmbedding) }
        })
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in
            Task { @MainActor in resolve(.cancel) }
        })
        presenter.present(alert, animated: true)
        #elseif os(macOS)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: embedTitle)
        alert.addButton(withTitle: skipTitle)
        alert.addButton(withTitle: cancelTitle)
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: resolve(.embed)
            case .alertSecondButtonReturn: resolve(.skipEmbedding)
            default: resolve(.cancel)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { handle(response) }
            }
        } else {
            handle(alert.runModal())
        }
        #endif
    }

    #if os(iOS)
    private static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.sorted { lhs, rhs in
            (lhs.activationState == .foregroundActive ? 0 : 1) < (rhs.activationState == .foregroundActive ? 0 : 1)
        }
        var window: UIWindow?
        for scene in ordered {
            if let candidate = scene.keyWindow ?? scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
                window = candidate
                break
            }
        }
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top.viewIfLoaded?.window == nil ? nil : top
    }
    #endif
}
