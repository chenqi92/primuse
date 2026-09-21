import PrimuseKit
import SwiftUI

/// The chapter marks of the item that is playing, as a jump list.
///
/// Only shown when the file actually carries marks, so there is no empty
/// state: the entry point that presents this is hidden otherwise.
struct ChapterListView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.spokenWordChapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        player.seekToChapter(at: index)
                        dismiss()
                    } label: {
                        ChapterRow(
                            chapter: chapter,
                            number: index + 1,
                            isCurrent: index == player.currentChapterIndex
                        )
                    }
                    .buttonStyle(.plain)
                    // buttonStyle(.plain) only reacts to the shape of its
                    // content, so the row's padding would be dead space.
                    .contentShape(Rectangle())
                }
            }
            .listStyle(.plain)
            .navigationTitle("chapters_title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
    }
}

private struct ChapterRow: View {
    let chapter: MediaChapter
    let number: Int
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(minWidth: 26, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(2)
                Text(ChapterTimeFormatter.string(from: chapter.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Chapter positions run to many hours, so the hour component appears only
/// when it is non-zero rather than always padding the string.
enum ChapterTimeFormatter {
    static func string(from time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
