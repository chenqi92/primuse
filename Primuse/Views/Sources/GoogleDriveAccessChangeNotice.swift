import PrimuseKit
import SwiftUI

/// Google Drive 改用 drive.file 权限的提醒文字。生效日按用户的地区格式显示,
/// 标题和概要按 `GoogleDriveAccessChangePolicy.phase` 在「将于」与「已于」之间切换。
enum GoogleDriveAccessChangeText {
    static var effectiveDateText: String {
        GoogleDriveAccessChangePolicy.effectiveDate().formatted(date: .long, time: .omitted)
    }

    static func title(_ phase: GoogleDriveAccessChangePolicy.Phase) -> String {
        let format = switch phase {
        case .upcoming: String(localized: "gdrive_scope_change_title_upcoming")
        case .inEffect: String(localized: "gdrive_scope_change_title_in_effect")
        }
        return String(format: format, effectiveDateText)
    }

    static func summary(_ phase: GoogleDriveAccessChangePolicy.Phase) -> String {
        switch phase {
        case .upcoming: String(localized: "gdrive_scope_change_summary_upcoming")
        case .inEffect: String(localized: "gdrive_scope_change_summary_in_effect")
        }
    }
}

// Apple TV 只共用上面的文案,卡片和详情页各自按电视的焦点交互另写。
#if !os(tvOS)
/// Google Drive 源卡片与授权页上的调整提醒。详情页由提醒自己弹出,
/// 挂到哪一页都不必给宿主视图再加状态。
struct GoogleDriveAccessChangeNotice: View {
    @State private var showsDetails = false

    var body: some View {
        let phase = GoogleDriveAccessChangePolicy.phase()
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: GoogleDriveAccessChangeText.title(phase))
                    .fontWeight(.semibold)
                Text(verbatim: GoogleDriveAccessChangeText.summary(phase))
                    .foregroundStyle(.secondary)
                Button("gdrive_scope_change_learn_more") { showsDetails = true }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .sheet(isPresented: $showsDetails) {
            GoogleDriveAccessChangeDetailView()
        }
    }
}

/// 「了解详情」:变化清单、调整原因、大曲库的替代做法。
struct GoogleDriveAccessChangeDetailView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let phase = GoogleDriveAccessChangePolicy.phase()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text(verbatim: GoogleDriveAccessChangeText.title(phase))
                        } icon: {
                            Image(systemName: "calendar.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                        .font(.headline)
                        Text(verbatim: GoogleDriveAccessChangeText.summary(phase))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    section(String(format: String(localized: "gdrive_scope_change_changes_header"),
                                   GoogleDriveAccessChangeText.effectiveDateText)) {
                        item("checklist", "gdrive_scope_change_item_pick")
                        item("arrow.up.doc", "gdrive_scope_change_item_new_uploads")
                        item("photo.on.rectangle", "gdrive_scope_change_item_sidecars")
                        item("square.and.pencil", "gdrive_scope_change_item_writeback")
                        item("arrow.triangle.2.circlepath", "gdrive_scope_change_item_existing")
                        item("appletv", "gdrive_scope_change_item_tv")
                    }

                    section(String(localized: "gdrive_scope_change_reason_header")) {
                        Text("gdrive_scope_change_reason_policy")
                        Text("gdrive_scope_change_reason_decision")
                    }

                    section(String(localized: "gdrive_scope_change_alternatives_header")) {
                        item("laptopcomputer", "gdrive_scope_change_alt_mac")
                        item("externaldrive.connected.to.line.below", "gdrive_scope_change_alt_webdav")
                        item("shippingbox", "gdrive_scope_change_alt_move")
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .navigationTitle("gdrive_scope_change_sheet_title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 640)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 12, content: content)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func item(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(key)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
