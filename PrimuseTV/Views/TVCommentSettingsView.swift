#if os(tvOS)
import PrimuseKit
import SwiftUI

/// Apple TV「评论服务」设置页：展示经 iCloud 或扫码同步来的评论 API 列表，支持就地启用/停用与管理本机屏蔽记录。
struct TVCommentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = CommentAPIServerStore.shared
    @State private var moderationStore = SongCommentModerationStore.shared
    @State private var showsClearConfirm = false

    static var summary: String {
        let count = CommentAPIServerStore.shared.enabledServers.count
        if count == 0 {
            return String(localized: "comments_server_none")
        }
        return String(format: String(localized: "comments_server_count_format"), count)
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    HStack(alignment: .top, spacing: 40) {
                        VStack(alignment: .leading, spacing: 24) {
                            serversSection
                            if !moderationStore.isEmpty {
                                moderationSection
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        sideNotes
                            .frame(width: 440, alignment: .leading)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
            }
        }
        .foregroundStyle(TVColor.text)
        .onExitCommand { dismiss() }
        .confirmationDialog(
            String(localized: "comments_moderation_clear_confirm"),
            isPresented: $showsClearConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "comments_moderation_clear_all"), role: .destructive) {
                moderationStore.clearAll()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .accessibilityIdentifier("tv.comments.settings")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(String(localized: "comments_service_title")).tvFont(.pageTitle)
            Spacer(minLength: 0)
            TVPillButton(title: String(localized: "done"), systemImage: "xmark") { dismiss() }
        }
        .focusSection()
        .padding(.bottom, 28)
    }

    private var serversSection: some View {
        TVAISection(title: String(localized: "comments_server_list")) {
            if store.servers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "comments_server_none"))
                        .tvFont(.body)
                        .foregroundStyle(TVColor.textMuted)
                    Text(String(localized: "tv_comments_configure_on_phone"))
                        .tvFont(.meta)
                        .foregroundStyle(TVColor.textFaint)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
            } else {
                ForEach(Array(store.servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { TVAIDivider() }
                    TVAIToggleRow(
                        icon: "bubble.left.and.text.bubble.right",
                        title: server.displayTitle,
                        isOn: Binding(
                            get: { server.isEnabled },
                            set: { store.setEnabled($0, id: server.id) }
                        )
                    )
                }
            }
        }
    }

    private var moderationSection: some View {
        TVAISection(title: String(localized: "comments_moderation_section")) {
            TVAIActionRow(
                icon: "trash",
                title: String(localized: "comments_moderation_clear_all")
            ) {
                showsClearConfirm = true
            }
        }
    }

    private var sideNotes: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "tv_comments_configure_on_phone"))
                .tvFont(.meta)
                .foregroundStyle(TVColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "comments_server_privacy_footer"))
                .tvFont(.meta)
                .foregroundStyle(TVColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
#endif
