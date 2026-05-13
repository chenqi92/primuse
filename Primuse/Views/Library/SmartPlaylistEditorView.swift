import SwiftUI
import PrimuseKit

/// 智能歌单创建 / 编辑器。
///
/// 设计:
/// - 顶部一段 "名称" 编辑
/// - "规则" section: 每条规则一行 (字段 picker + 操作符 picker + 值输入框),
///   底部加 + 按钮新增, 左滑删除
/// - "组合方式" segmented control (AND / OR)
/// - "排序" + "排序方向"
/// - "上限" 数字输入 (可空)
/// - 底部 Save / Delete (编辑模式才有 delete)
struct SmartPlaylistEditorView: View {
    /// 编辑现有时传 existing; 创建新的传 nil。
    let existing: SmartPlaylist?

    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var rules: [SmartPlaylistRule] = []
    @State private var combinator: SmartPlaylistCombinator = .and
    @State private var sortField: SmartPlaylistSortField = .dateAdded
    @State private var sortDirection: SmartPlaylistSortDirection = .descending
    @State private var limitText: String = ""

    @State private var showDeleteConfirm = false

    private var isEditing: Bool { existing != nil }

    /// 简单 validation: 必须有名字才能保存。
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("smart_playlist_name", text: $name)
                }

                Section {
                    ForEach($rules) { $rule in
                        SmartPlaylistRuleEditorRow(rule: $rule)
                    }
                    .onDelete { offsets in
                        rules.remove(atOffsets: offsets)
                    }

                    Button {
                        rules.append(SmartPlaylistRule(
                            field: .title,
                            op: .contains,
                            value: ""
                        ))
                    } label: {
                        Label("smart_rule_add", systemImage: "plus.circle")
                    }
                } header: {
                    Text("smart_rules_section")
                }

                if rules.count >= 2 {
                    Section {
                        Picker("smart_combinator", selection: $combinator) {
                            Text("smart_combinator_and").tag(SmartPlaylistCombinator.and)
                            Text("smart_combinator_or").tag(SmartPlaylistCombinator.or)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("smart_combinator_section")
                    } footer: {
                        Text(combinator == .and
                             ? "smart_combinator_and_desc"
                             : "smart_combinator_or_desc")
                    }
                }

                Section {
                    Picker("smart_sort_field", selection: $sortField) {
                        ForEach(SmartPlaylistSortField.allCases, id: \.self) { f in
                            Text(sortFieldLabel(f)).tag(f)
                        }
                    }
                    if sortField != .random {
                        Picker("smart_sort_direction", selection: $sortDirection) {
                            Text("smart_sort_ascending").tag(SmartPlaylistSortDirection.ascending)
                            Text("smart_sort_descending").tag(SmartPlaylistSortDirection.descending)
                        }
                    }
                    HStack {
                        Text("smart_limit")
                        Spacer()
                        TextField("smart_limit_placeholder", text: $limitText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                } header: {
                    Text("smart_sort_section")
                } footer: {
                    Text("smart_limit_footer")
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("delete")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "smart_playlist_edit" : "smart_playlist_new")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("save") { save() }
                        .disabled(!canSave)
                }
            }
            .alert("smart_playlist_delete_confirm", isPresented: $showDeleteConfirm) {
                Button("cancel", role: .cancel) {}
                Button("delete", role: .destructive) {
                    if let existing {
                        library.deleteSmartPlaylist(id: existing.id)
                    }
                    dismiss()
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    rules = existing.rules
                    combinator = existing.combinator
                    sortField = existing.sortField
                    sortDirection = existing.sortDirection
                    limitText = existing.limit.map(String.init) ?? ""
                }
            }
        }
    }

    private func save() {
        var smart = existing ?? SmartPlaylist(name: "")
        smart.name = name.trimmingCharacters(in: .whitespaces)
        smart.rules = rules
        smart.combinator = combinator
        smart.sortField = sortField
        smart.sortDirection = sortDirection
        smart.limit = Int(limitText.trimmingCharacters(in: .whitespaces))
        library.saveSmartPlaylist(smart)
        dismiss()
    }

    private func sortFieldLabel(_ f: SmartPlaylistSortField) -> String {
        String(localized: LocalizedStringResource(stringLiteral: "smart_sort_field_\(f.rawValue)"))
    }
}

// MARK: - Rule editor row

/// 单条规则编辑行 ── 卡片式视觉。
///
/// 上半: 字段 (带类型图标) + 操作符, 都做成 capsule menu。
/// 下半: 值输入区, 用统一圆角容器, 形态根据字段 valueKind 切换。
///
/// 字段切换时操作符会自动 reset 成该字段类型的第一个支持选项, 避免 type-
/// incompatible 残留 (如 text 切到 integer 后还留着 contains)。
private struct SmartPlaylistRuleEditorRow: View {
    @Binding var rule: SmartPlaylistRule

    private var supportedOps: [SmartPlaylistOperator] {
        SmartPlaylistOperator.allCases.filter { $0.supports(rule.field.valueKind) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 上行: 字段 + 操作符 capsule
            HStack(spacing: 8) {
                fieldMenu
                opMenu
                Spacer(minLength: 0)
            }

            // 下行: 值输入。统一圆角容器, 内部按字段类型变形。
            valueInput
        }
        .padding(.vertical, 6)
    }

    // MARK: 字段 menu (capsule + 类型图标 + 文字 + 三角)

    private var fieldMenu: some View {
        Menu {
            ForEach(SmartPlaylistField.allCases, id: \.self) { f in
                Button {
                    rule.field = f
                    if !rule.op.supports(f.valueKind) {
                        rule.op = SmartPlaylistOperator.allCases.first(where: { $0.supports(f.valueKind) }) ?? .equals
                    }
                } label: {
                    Label(fieldLabel(f), systemImage: fieldIcon(f))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: fieldIcon(rule.field))
                    .font(.caption)
                Text(fieldLabel(rule.field))
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: 操作符 menu (capsule, 浅灰, 跟字段视觉层级区分)

    private var opMenu: some View {
        Menu {
            ForEach(supportedOps, id: \.self) { o in
                Button { rule.op = o } label: {
                    Text(opLabel(o))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(opLabel(rule.op))
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.primary)
        }
    }

    // MARK: 值输入

    @ViewBuilder
    private var valueInput: some View {
        Group {
            switch rule.field.valueKind {
            case .text:
                if rule.field == .isInPlaylist {
                    SmartPlaylistPicker(value: $rule.value)
                } else if rule.field == .fileFormat {
                    // 文件格式 ── 弹 menu 从 AudioFormat.allCases 选, 不让
                    // 用户手打 "FLAC" 大小写错配。
                    SmartFormatPicker(value: $rule.value)
                } else if rule.field == .sourceID {
                    // 音乐源 ── 从已配置的 sources 里挑,把 id 写回 rule.value。
                    SmartSourcePicker(value: $rule.value)
                } else {
                    TextField(String(localized: "smart_value_placeholder"), text: $rule.value)
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(roundedFieldBackground)
                }
            case .integer, .double:
                if rule.op == .between {
                    BetweenInput(value: $rule.value)
                } else {
                    TextField(String(localized: "smart_value_placeholder"), text: $rule.value)
                        .keyboardType(.decimalPad)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(roundedFieldBackground)
                }
            case .date:
                // 日期场景统一为"最近 N 天" stepper, 不暴露原始 ISO8601 输入
                // ── 手输 timestamp 没人会用, 直接给数字步进器更明确。
                DateValueEditor(value: $rule.value)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(roundedFieldBackground)
            }
        }
    }

    private var roundedFieldBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }

    // MARK: 字段 icon / label

    private func fieldIcon(_ f: SmartPlaylistField) -> String {
        switch f {
        case .title: return "music.note"
        case .artistName: return "person.fill"
        case .albumTitle: return "square.stack.fill"
        case .genre: return "guitars"
        case .fileFormat: return "waveform"
        case .sourceID: return "externaldrive"
        case .year: return "calendar"
        case .fileSize: return "doc"
        case .bitRate: return "gauge"
        case .durationSec: return "clock"
        case .dateAdded: return "calendar.badge.plus"
        case .playCount: return "play.circle"
        case .lastPlayedAt: return "clock.arrow.circlepath"
        case .isInPlaylist: return "music.note.list"
        }
    }

    private func fieldLabel(_ f: SmartPlaylistField) -> String {
        String(localized: LocalizedStringResource(stringLiteral: "smart_field_\(f.rawValue)"))
    }

    private func opLabel(_ o: SmartPlaylistOperator) -> String {
        String(localized: LocalizedStringResource(stringLiteral: "smart_op_\(o.rawValue)"))
    }
}

// MARK: - Date value editor

/// 把日期 rule.value 编辑成 "最近 N 天" 形式。存为 "days:N", 引擎解析成 now-N。
private struct DateValueEditor: View {
    @Binding var value: String

    private var days: Int {
        if value.hasPrefix("days:"),
           let n = Int(value.dropFirst("days:".count)) {
            return n
        }
        return 7
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            Text("smart_date_recent_days")
                .font(.subheadline)
            Spacer()
            Stepper(value: Binding(
                get: { days },
                set: { value = "days:\($0)" }
            ), in: 1...3650) {
                HStack(spacing: 4) {
                    Text("\(days)")
                        .monospacedDigit()
                        .fontWeight(.medium)
                    Text(verbatim: "d")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // 第一次编辑时若 value 不是 days: 形式 (旧数据 / 默认空), 初始化为 days:7
            if !value.hasPrefix("days:") {
                value = "days:7"
            }
        }
    }
}

// MARK: - Between input

/// integer / double 字段的 between 操作符: "min|max" 编码成两个独立输入框。
private struct BetweenInput: View {
    @Binding var value: String

    private var parts: (String, String) {
        let split = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let lo = split.first.map(String.init) ?? ""
        let hi = split.count > 1 ? String(split[1]) : ""
        return (lo, hi)
    }

    var body: some View {
        let (lo, hi) = parts
        HStack(spacing: 8) {
            TextField("min", text: Binding(
                get: { lo },
                set: { value = "\($0)|\(hi)" }
            ))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(boxBackground)

            Text(verbatim: "─")
                .foregroundStyle(.secondary)

            TextField("max", text: Binding(
                get: { hi },
                set: { value = "\(lo)|\($0)" }
            ))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(boxBackground)
        }
    }

    private var boxBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }
}

// MARK: - Playlist picker for isInPlaylist rule

private struct SmartPlaylistPicker: View {
    @Binding var value: String
    @Environment(MusicLibrary.self) private var library

    private var selectedName: String {
        if value.isEmpty {
            return String(localized: "smart_value_playlist_none")
        }
        return library.playlists.first(where: { $0.id == value })?.name
            ?? String(localized: "smart_value_playlist_none")
    }

    var body: some View {
        Menu {
            Button { value = "" } label: {
                Label(String(localized: "smart_value_playlist_none"), systemImage: "circle.dashed")
            }
            if !library.playlists.isEmpty {
                Divider()
                ForEach(library.playlists) { p in
                    Button { value = p.id } label: {
                        Label(p.name, systemImage: "music.note.list")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .foregroundStyle(.secondary)
                Text(selectedName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - File format / Source picker

/// 文件格式选择器 ── 从 AudioFormat.allCases 拿。rule.value 存 rawValue
/// (mp3 / flac / wav 等),engine 直接做字符串比较。
private struct SmartFormatPicker: View {
    @Binding var value: String

    private var selectedLabel: String {
        if value.isEmpty {
            return String(localized: "smart_value_format_none")
        }
        return AudioFormat(rawValue: value)?.displayName ?? value
    }

    var body: some View {
        Menu {
            Button { value = "" } label: {
                Label(String(localized: "smart_value_format_none"), systemImage: "circle.dashed")
            }
            Divider()
            ForEach(AudioFormat.allCases, id: \.self) { format in
                Button { value = format.rawValue } label: {
                    Label(format.displayName, systemImage: format.isLossless ? "waveform.badge.checkmark" : "waveform")
                }
            }
        } label: {
            pickerLabel(systemImage: "waveform", text: selectedLabel)
        }
    }
}

/// 音乐源选择器 ── 从 SourcesStore 里拿现存源,rule.value 存 source id。
private struct SmartSourcePicker: View {
    @Binding var value: String
    @Environment(SourcesStore.self) private var sources

    private var selectedLabel: String {
        if value.isEmpty {
            return String(localized: "smart_value_source_none")
        }
        return sources.source(id: value)?.name ?? String(localized: "smart_value_source_none")
    }

    var body: some View {
        Menu {
            Button { value = "" } label: {
                Label(String(localized: "smart_value_source_none"), systemImage: "circle.dashed")
            }
            if !sources.sources.isEmpty {
                Divider()
                ForEach(sources.sources) { src in
                    Button { value = src.id } label: {
                        Label(src.name, systemImage: src.type.iconName)
                    }
                }
            }
        } label: {
            pickerLabel(systemImage: "externaldrive", text: selectedLabel)
        }
    }
}

@MainActor
private func pickerLabel(systemImage: String, text: String) -> some View {
    HStack(spacing: 6) {
        Image(systemName: systemImage).foregroundStyle(.secondary)
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    )
}
