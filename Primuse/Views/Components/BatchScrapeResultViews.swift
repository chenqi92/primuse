import PrimuseKit
import SwiftUI

extension View {
    /// 批量刮削（整库、专辑、艺人、多选）做完时的提示条。歌单发起的由歌单页自己说，这里不重复；
    /// 有没完成的歌时提示条带「查看」，点开列出是哪几首、哪一部分、为什么。挂在根视图上，全 App 一份。
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
