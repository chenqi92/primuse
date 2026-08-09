import PrimuseKit
import SwiftUI

/// 让用户手动挑一个字符编码重解标签文本。
///
/// 自动修复只在有把握时动手 —— 猜错会把好数据改坏, 所以它宁可漏。漏掉的那些
/// 就落到这里: 乱码是"看一眼就能判断对不对"的问题, 人来选比启发式可靠。
///
/// 方案是整批应用的。同一首歌的各字段几乎总是同一个编码写的, 所以选一次
/// 标题/艺术家/专辑/流派一起改, 而不是让用户逐字段折腾四遍。
struct EncodingFixPicker: View {
    let fixes: [TextEncodingRepair.EncodingFix]
    /// 与 `fix.fields` 同序的当前值, 用来只展示真正发生变化的字段。
    let originalFields: [String]
    let onPick: (TextEncodingRepair.EncodingFix) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if fixes.isEmpty {
                    emptyState
                } else {
                    fixList
                }
            }
            .navigationTitle(String(localized: "encoding_fix_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 520)
        #endif
    }

    private var emptyState: some View {
        ContentUnavailableView(
            String(localized: "encoding_fix_empty_title"),
            systemImage: "character.cursor.ibeam",
            description: Text(String(localized: "encoding_fix_empty_message"))
        )
    }

    private var fixList: some View {
        List {
            Section {
                ForEach(fixes) { fix in
                    Button {
                        onPick(fix)
                    } label: {
                        row(for: fix)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(String(localized: "encoding_fix_section_header"))
            } footer: {
                Text(String(localized: "encoding_fix_footer"))
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
    }

    private func row(for fix: TextEncodingRepair.EncodingFix) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(fix.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            // 只列出真正被这套方案改动的字段, 避免同一行里重复展示没变的值。
            // 两个字段可能重解成同一个串, 所以按位置而不是内容做 id。
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(changedPreviews(for: fix).enumerated()), id: \.offset) { _, preview in
                    Text(preview)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func changedPreviews(for fix: TextEncodingRepair.EncodingFix) -> [String] {
        var previews: [String] = []
        for (index, value) in fix.fields.enumerated() {
            guard index < originalFields.count else { break }
            guard value != originalFields[index] else { continue }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            previews.append(value)
        }
        return previews
    }
}
