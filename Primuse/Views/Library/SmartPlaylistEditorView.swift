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

/// 单行规则编辑: 字段 picker + 操作符 picker + 值输入。
/// 字段切换后操作符自动 reset 为该字段的第一个支持选项, 避免 type-incompatible
/// 残留 (e.g. text 字段切到 integer 后还留着 contains)。
private struct SmartPlaylistRuleEditorRow: View {
    @Binding var rule: SmartPlaylistRule

    private var supportedOps: [SmartPlaylistOperator] {
        SmartPlaylistOperator.allCases.filter { $0.supports(rule.field.valueKind) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $rule.field) {
                    ForEach(SmartPlaylistField.allCases, id: \.self) { f in
                        Text(fieldLabel(f)).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: rule.field) { _, newField in
                    // 切换字段后, 如果当前 op 跟新字段类型不兼容, 重置成第一个支持的。
                    if !rule.op.supports(newField.valueKind) {
                        rule.op = SmartPlaylistOperator.allCases.first(where: { $0.supports(newField.valueKind) }) ?? .equals
                    }
                }

                Picker("", selection: $rule.op) {
                    ForEach(supportedOps, id: \.self) { o in
                        Text(opLabel(o)).tag(o)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            valueInput
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var valueInput: some View {
        switch rule.field.valueKind {
        case .text:
            if rule.field == .isInPlaylist {
                playlistPicker
            } else {
                TextField("smart_value_placeholder", text: $rule.value)
                    .textInputAutocapitalization(.never)
            }
        case .integer, .double:
            if rule.op == .between {
                HStack {
                    BetweenInput(value: $rule.value)
                }
            } else {
                TextField("smart_value_placeholder", text: $rule.value)
                    .keyboardType(.decimalPad)
            }
        case .date:
            // value 编辑成相对天数 ── "最近 N 天" 是最常见场景。手动 ISO8601
            // 用户基本不会输入。直接给 stepper 改 days 数字。
            DateValueEditor(value: $rule.value)
        }
    }

    @ViewBuilder
    private var playlistPicker: some View {
        // isInPlaylist 用 picker 选 library 里现有 playlist。
        // 这里没有直接拿 library, 用 NotificationCenter / Environment 都可以;
        // 简化起见用一个 helper view 注入 library。
        SmartPlaylistPicker(value: $rule.value)
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
        HStack {
            Text("smart_date_recent_days")
            Spacer()
            Stepper(value: Binding(
                get: { days },
                set: { value = "days:\($0)" }
            ), in: 1...3650) {
                Text("\(days)")
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
            .textFieldStyle(.roundedBorder)

            Text("─")

            TextField("max", text: Binding(
                get: { hi },
                set: { value = "\(lo)|\($0)" }
            ))
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Playlist picker for isInPlaylist rule

private struct SmartPlaylistPicker: View {
    @Binding var value: String
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        Picker("smart_value_playlist", selection: $value) {
            Text("smart_value_playlist_none").tag("")
            ForEach(library.playlists) { p in
                Text(p.name).tag(p.id)
            }
        }
        .pickerStyle(.menu)
    }
}
