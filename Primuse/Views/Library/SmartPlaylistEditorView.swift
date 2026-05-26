import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 平台无关的 Form / Card 系背景色 ── iOS 用 systemBackground (跟 List 卡同色),
/// macOS 用 windowBackgroundColor。
private extension Color {
    static var primuseFormCardBackground: Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
}

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
    @State private var ruleGroups: [SmartPlaylistRuleGroup] = []
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
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    private var iosBody: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("smart_playlist_name", text: $name)
                }

                ForEach($ruleGroups) { $group in
                    SmartPlaylistRuleGroupEditor(
                        group: $group,
                        canDelete: ruleGroups.count > 1,
                        onDelete: { removeGroup(id: group.id) }
                    )
                }

                Section {
                    Button {
                        ruleGroups.append(Self.defaultGroup())
                    } label: {
                        Label("smart_rule_group_add", systemImage: "plus.rectangle.on.rectangle")
                    }
                } footer: {
                    Text("smart_rule_group_footer")
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
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
            .onAppear(perform: loadInitialState)
        }
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            macHeader

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    macNameCard

                    ForEach($ruleGroups) { $group in
                        MacSmartRuleGroupCard(
                            group: $group,
                            canDelete: ruleGroups.count > 1,
                            onDelete: { removeGroup(id: group.id) }
                        )
                    }

                    Button {
                        ruleGroups.append(Self.defaultGroup())
                    } label: {
                        Label("smart_rule_group_add", systemImage: "plus.rectangle.on.rectangle")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background(PMColor.brand.opacity(0.12), in: .rect(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(PMColor.brand.opacity(0.20), lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)

                    macSortCard

                    if isEditing {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("delete", systemImage: "trash")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(PMColor.bad)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .frame(height: 38)
                                .background(PMColor.bad.opacity(0.10), in: .rect(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack {
                Text("LIB-05 · Smart Playlist Rule Editor")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                Spacer()
                Button("cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 7))

                Button("save") { save() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(canSave ? PMColor.brand : PMColor.textFaint, in: .rect(cornerRadius: 7))
                    .disabled(!canSave)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 620, height: 680)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PMColor.bg.opacity(0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.24), radius: 28, y: 14)
        .onAppear(perform: loadInitialState)
        .alert("smart_playlist_delete_confirm", isPresented: $showDeleteConfirm) {
            Button("cancel", role: .cancel) {}
            Button("delete", role: .destructive) {
                if let existing {
                    library.deleteSmartPlaylist(id: existing.id)
                }
                dismiss()
            }
        }
    }

    private var macHeader: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [PMColor.brand, Color(red: 0.46, green: 0.30, blue: 0.92)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(isEditing ? "编辑智能歌单" : "新建智能歌单")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text("规则组 · 排序 · 上限 · 自动生成动态歌单")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 26, height: 26)
                    .background(PMColor.glassBtn, in: .circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var macNameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("smart_playlist_name")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(PMColor.textMuted)
            TextField("smart_playlist_name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(PMColor.card.opacity(0.72), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
        }
        .padding(14)
        .background(PMColor.bgElev.opacity(0.84), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var macSortCard: some View {
        VStack(spacing: 0) {
            macSortRow("smart_sort_field") {
                Picker("smart_sort_field", selection: $sortField) {
                    ForEach(SmartPlaylistSortField.allCases, id: \.self) { f in
                        Text(sortFieldLabel(f)).tag(f)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            if sortField != .random {
                Rectangle().fill(PMColor.divider).frame(height: 0.5).padding(.leading, 14)
                macSortRow("smart_sort_direction") {
                    Picker("smart_sort_direction", selection: $sortDirection) {
                        Text("smart_sort_ascending").tag(SmartPlaylistSortDirection.ascending)
                        Text("smart_sort_descending").tag(SmartPlaylistSortDirection.descending)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5).padding(.leading, 14)
            macSortRow("smart_limit") {
                TextField("smart_limit_placeholder", text: $limitText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(width: 96, height: 28)
                    .background(PMColor.card.opacity(0.74), in: .rect(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }
            }
        }
        .background(PMColor.bgElev.opacity(0.84), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func macSortRow<Content: View>(_ title: LocalizedStringKey,
                                           @ViewBuilder control: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
            Spacer()
            control()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
    #endif

    private func save() {
        var smart = existing ?? SmartPlaylist(name: "")
        smart.name = name.trimmingCharacters(in: .whitespaces)
        let cleanedGroups = ruleGroups
            .map { group -> SmartPlaylistRuleGroup in
                var g = group
                g.rules = g.rules.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                return g
            }
            .filter { !$0.rules.isEmpty }
        smart.ruleGroups = cleanedGroups.isEmpty ? nil : cleanedGroups
        if let firstIncluded = cleanedGroups.first(where: { !$0.isExcluded }) {
            smart.rules = firstIncluded.rules
            smart.combinator = firstIncluded.combinator
        } else {
            smart.rules = []
            smart.combinator = .and
        }
        smart.sortField = sortField
        smart.sortDirection = sortDirection
        smart.limit = Int(limitText.trimmingCharacters(in: .whitespaces))
        library.saveSmartPlaylist(smart)
        dismiss()
    }

    private func removeGroup(id: String) {
        ruleGroups.removeAll { $0.id == id }
        if ruleGroups.isEmpty {
            ruleGroups = [Self.defaultGroup()]
        }
    }

    private static func defaultGroup() -> SmartPlaylistRuleGroup {
        SmartPlaylistRuleGroup(
            rules: [
                SmartPlaylistRule(
                    field: .title,
                    op: .contains,
                    value: ""
                )
            ],
            combinator: .and
        )
    }

    private func loadInitialState() {
        if let existing {
            name = existing.name
            ruleGroups = existing.effectiveRuleGroups
            if ruleGroups.isEmpty {
                ruleGroups = [Self.defaultGroup()]
            }
            sortField = existing.sortField
            sortDirection = existing.sortDirection
            limitText = existing.limit.map(String.init) ?? ""
        } else if ruleGroups.isEmpty {
            ruleGroups = [Self.defaultGroup()]
        }
    }

    private func sortFieldLabel(_ f: SmartPlaylistSortField) -> String {
        String(localized: LocalizedStringResource(stringLiteral: "smart_sort_field_\(f.rawValue)"))
    }
}

// MARK: - Rule editor row

private struct SmartPlaylistRuleGroupEditor: View {
    @Binding var group: SmartPlaylistRuleGroup
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        Section {
            Toggle("smart_rule_group_exclude", isOn: $group.isExcluded)

            if group.rules.count >= 2 {
                Picker("smart_combinator", selection: $group.combinator) {
                    Text("smart_combinator_and").tag(SmartPlaylistCombinator.and)
                    Text("smart_combinator_or").tag(SmartPlaylistCombinator.or)
                }
                .pickerStyle(.segmented)
            }

            ForEach($group.rules) { $rule in
                SmartPlaylistRuleEditorRow(rule: $rule)
            }
            .onDelete { offsets in
                group.rules.remove(atOffsets: offsets)
            }

            Button {
                group.rules.append(SmartPlaylistRule(
                    field: .title,
                    op: .contains,
                    value: ""
                ))
            } label: {
                Label("smart_rule_add", systemImage: "plus.circle")
            }

            if canDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("smart_rule_group_delete", systemImage: "trash")
                }
            }
        } header: {
            Label(
                group.isExcluded ? "smart_rule_group_excluded" : "smart_rule_group",
                systemImage: group.isExcluded ? "minus.circle" : "line.3.horizontal.decrease.circle"
            )
        } footer: {
            if group.rules.count >= 2 {
                Text(group.combinator == .and
                     ? "smart_combinator_and_desc"
                     : "smart_combinator_or_desc")
            }
        }
    }
}

#if os(macOS)
private struct MacSmartRuleGroupCard: View {
    @Binding var group: SmartPlaylistRuleGroup
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if group.rules.count >= 2 {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
                HStack {
                    Text("smart_combinator")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PMColor.text)
                    Spacer()
                    Picker("smart_combinator", selection: $group.combinator) {
                        Text("smart_combinator_and").tag(SmartPlaylistCombinator.and)
                        Text("smart_combinator_or").tag(SmartPlaylistCombinator.or)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            VStack(alignment: .leading, spacing: 10) {
                ForEach($group.rules) { $rule in
                    let ruleID = rule.id
                    HStack(alignment: .top, spacing: 10) {
                        SmartPlaylistRuleEditorRow(rule: $rule)
                            .padding(12)
                            .background(PMColor.card.opacity(0.70), in: .rect(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                            }

                        if group.rules.count > 1 {
                            Button {
                                deleteRule(id: ruleID)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(PMColor.bad)
                                    .frame(width: 26, height: 26)
                                    .background(PMColor.bad.opacity(0.10), in: .circle)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        group.rules.append(SmartPlaylistRule(field: .title, op: .contains, value: ""))
                    } label: {
                        Label("smart_rule_add", systemImage: "plus.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(PMColor.brand.opacity(0.12), in: .rect(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)

                    if canDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("smart_rule_group_delete", systemImage: "minus.circle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(PMColor.bad)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(PMColor.bad.opacity(0.08), in: .rect(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
            .padding(14)
        }
        .background(PMColor.bgElev.opacity(0.84), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: group.isExcluded ? "minus.circle" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(group.isExcluded ? PMColor.bad : PMColor.brand)
                .frame(width: 26, height: 26)
                .background((group.isExcluded ? PMColor.bad : PMColor.brand).opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.isExcluded ? "smart_rule_group_excluded" : "smart_rule_group")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(group.rules.count >= 2
                     ? (group.combinator == .and ? "smart_combinator_and_desc" : "smart_combinator_or_desc")
                     : "smart_rule_group_footer")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("smart_rule_group_exclude", isOn: $group.isExcluded)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(PMColor.brand)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func deleteRule(id: String) {
        group.rules.removeAll { $0.id == id }
        if group.rules.isEmpty {
            group.rules = [SmartPlaylistRule(field: .title, op: .contains, value: "")]
        }
    }
}
#endif

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
        Self.supportedOps(for: rule.field)
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
                    if !Self.supportedOps(for: f).contains(rule.op) {
                        rule.op = Self.defaultOperator(for: f)
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
            .fill(Color.primuseFormCardBackground)
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

    private static func supportedOps(for field: SmartPlaylistField) -> [SmartPlaylistOperator] {
        if field == .isInPlaylist {
            return [.equals, .notEquals]
        }
        if field.valueKind == .date {
            return [.equals, .notEquals, .greaterThan, .lessThan]
        }
        return SmartPlaylistOperator.allCases.filter { $0.supports(field.valueKind) }
    }

    private static func defaultOperator(for field: SmartPlaylistField) -> SmartPlaylistOperator {
        switch field.valueKind {
        case .text:
            return field == .isInPlaylist ? .equals : .contains
        case .integer, .double, .date:
            return .equals
        }
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
            .fill(Color.primuseFormCardBackground)
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
                    .fill(Color.primuseFormCardBackground)
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
            .fill(Color.primuseFormCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    )
}
