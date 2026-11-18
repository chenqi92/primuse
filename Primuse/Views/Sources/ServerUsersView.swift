import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - 概览页里的「服务器管理」

/// 音乐服务器概览页里只有管理员账号才看得到的一段:用户、网页后台(#148)。
struct ServerAdminSection: View {
    let source: MusicSource
    let access: ServerAdmin.Access
    let userCount: Int?
    let onOpenUsers: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Button(action: onOpenUsers) {
                SourceNavigationRow(
                    title: String(localized: "server_admin_users"),
                    systemImage: "person.2",
                    value: userCount.map { $0.formatted() }
                )
            }
            .buttonStyle(.plain)
            if let url = webAdminURL {
                Button { openURL(url) } label: {
                    SourceNavigationRow(
                        title: String(localized: "server_admin_open_web"),
                        systemImage: "safari"
                    )
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("server_admin_section")
        } footer: {
            Text(String(format: String(localized: "server_admin_footer_format"), access.username))
        }
    }

    private var webAdminURL: URL? {
        guard let host = source.host, !host.isEmpty else { return nil }
        return NetworkURLBuilder.makeURL(
            host: host,
            defaultScheme: source.useSsl ? "https" : "http",
            port: source.port,
            path: source.basePath
        )
    }
}

// MARK: - 用户列表

struct ServerUsersPage: View {
    let source: MusicSource
    let access: ServerAdmin.Access

    @Environment(SourceManager.self) private var sourceManager
    @State private var users: [ServerAdmin.User] = []
    @State private var libraries: [ServerAdmin.Library]?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var editing: ServerUserEditorTarget?
    @State private var pendingDelete: ServerAdmin.User?
    @State private var errorMessage: String?
    @State private var toasts = PMToastPresenter()

    var body: some View {
        List {
            if let loadError {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("server_admin_load_failed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(loadError).font(.footnote).foregroundStyle(.secondary)
                        Button("retry") { Task { await reload() } }
                            .buttonStyle(.borderless)
                    }
                }
            } else if isLoading && users.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 20)
                }
            } else {
                Section {
                    ForEach(users) { user in
                        Button { editing = .edit(user) } label: {
                            ServerUserRow(user: user, isCurrent: user.id == access.userID, libraries: libraries)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if user.id != access.userID {
                                Button(role: .destructive) { pendingDelete = user } label: {
                                    Label("delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            Button { editing = .edit(user) } label: { Label("edit", systemImage: "pencil") }
                            if user.id != access.userID {
                                Button(role: .destructive) { pendingDelete = user } label: {
                                    Label("delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } footer: {
                    Text("server_admin_users_footer")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("server_admin_users")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = .create } label: {
                    Label("server_admin_add_user", systemImage: "plus")
                }
                .disabled(isLoading && users.isEmpty)
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .sheet(item: $editing) { target in
            ServerUserEditor(
                source: source,
                access: access,
                target: target,
                libraries: libraries,
                onSaved: { message in
                    toasts.show(PMToastItem(
                        key: "server-users", message: message,
                        systemImage: "checkmark.circle.fill", tint: .green
                    ))
                    Task { await reload() }
                }
            )
        }
        .confirmationDialog(
            String(format: String(localized: "server_admin_delete_title_format"), pendingDelete?.userName ?? ""),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) {
                if let user = pendingDelete { delete(user) }
            }
            Button("cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("server_admin_delete_message")
        }
        .alert(
            "source_file_action_failed",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .pmToastHost(toasts)
    }

    private var admin: (any ServerAdminConnector)? {
        sourceManager.connector(for: source) as? any ServerAdminConnector
    }

    private func reload() async {
        guard let admin else {
            loadError = ServerAdminErrorText.message(for: ServerAdmin.Failure.unavailable)
            isLoading = false
            return
        }
        isLoading = true
        do {
            async let loadedUsers = admin.serverAdminUsers()
            async let loadedLibraries = admin.serverAdminLibraries()
            let (fetchedUsers, fetchedLibraries) = try await (loadedUsers, loadedLibraries)
            users = fetchedUsers
            libraries = fetchedLibraries
            loadError = nil
        } catch {
            loadError = ServerAdminErrorText.message(for: error)
        }
        isLoading = false
    }

    private func delete(_ user: ServerAdmin.User) {
        pendingDelete = nil
        guard let admin else { return }
        Task { @MainActor in
            do {
                try await admin.deleteServerAdminUser(id: user.id)
                users.removeAll { $0.id == user.id }
                toasts.show(PMToastItem(
                    key: "server-users",
                    message: String(format: String(localized: "server_admin_deleted_format"), user.userName),
                    systemImage: "trash", tint: .secondary
                ))
            } catch {
                errorMessage = ServerAdminErrorText.message(for: error)
            }
        }
    }
}

private struct ServerUserRow: View {
    let user: ServerAdmin.User
    let isCurrent: Bool
    let libraries: [ServerAdmin.Library]?

    var body: some View {
        HStack(spacing: 12) {
            Text(String(user.userName.prefix(1)).uppercased())
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(avatarColor.gradient, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(user.userName).font(.body.weight(.semibold))
                    if user.isAdmin {
                        ServerUserBadge(text: String(localized: "server_admin_badge_admin"), tint: .teal)
                    }
                    if isCurrent {
                        ServerUserBadge(text: String(localized: "server_admin_badge_current"), tint: .secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let name = user.displayName, !name.isEmpty, name != user.userName { parts.append(name) }
        if user.isDisabled { parts.append(String(localized: "server_admin_disabled")) }
        if let seen = user.lastSeenAt {
            parts.append(String(format: String(localized: "server_admin_last_seen_format"), SourceDateText.relative(seen)))
        } else {
            parts.append(String(localized: "server_admin_never_used"))
        }
        if user.isAdmin || libraries == nil {
            // 管理员看全部;老版本没有多媒体库,不提。
        } else if let assigned = user.libraryIDs, let libraries {
            let names = libraries.filter { assigned.contains($0.id) }.map(\.name)
            if !names.isEmpty { parts.append(names.joined(separator: "、")) }
        }
        return parts.joined(separator: " · ")
    }

    private var avatarColor: Color {
        let palette: [Color] = [.teal, .orange, .indigo, .pink, .green, .blue, .purple]
        let index = abs(user.userName.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        return palette[index]
    }
}

private struct ServerUserBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((tint == .secondary ? Color.secondary : tint).opacity(0.14), in: Capsule())
    }
}

// MARK: - 新建 / 编辑

enum ServerUserEditorTarget: Identifiable {
    case create
    case edit(ServerAdmin.User)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let user): user.id
        }
    }
}

private struct ServerUserEditor: View {
    let source: MusicSource
    let access: ServerAdmin.Access
    let target: ServerUserEditorTarget
    let libraries: [ServerAdmin.Library]?
    let onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager
    @State private var userName = ""
    @State private var displayName = ""
    @State private var email = ""
    @State private var resetsPassword = false
    @State private var password = ServerUserPassword.generate()
    @State private var isAdmin = false
    @State private var selectedLibraries: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// 新建或重置之后给管理员看一次的密码。
    @State private var issuedPassword: String?

    init(
        source: MusicSource, access: ServerAdmin.Access, target: ServerUserEditorTarget,
        libraries: [ServerAdmin.Library]?, onSaved: @escaping (String) -> Void
    ) {
        self.source = source
        self.access = access
        self.target = target
        self.libraries = libraries
        self.onSaved = onSaved
        if case .edit(let user) = target {
            _userName = State(initialValue: user.userName)
            _displayName = State(initialValue: user.displayName ?? "")
            _email = State(initialValue: user.email ?? "")
            _isAdmin = State(initialValue: user.isAdmin)
            // nil 是「全部媒体库」:编辑时全选。
            _selectedLibraries = State(initialValue: Set(user.libraryIDs ?? (libraries ?? []).map(\.id)))
        } else {
            _selectedLibraries = State(initialValue: Set((libraries ?? []).map(\.id)))
        }
    }

    private var editingUser: ServerAdmin.User? {
        if case .edit(let user) = target { return user }
        return nil
    }

    private var isSelf: Bool { editingUser?.id == access.userID }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("server_admin_field_username") {
                        if editingUser == nil {
                            TextField("server_admin_field_username", text: $userName)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text(userName).foregroundStyle(.secondary)
                        }
                    }
                    if access.editsDisplayName {
                        LabeledContent("server_admin_field_name") {
                            TextField("server_admin_field_name", text: $displayName)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if access.editsEmail {
                        LabeledContent("server_admin_field_email") {
                            TextField("server_admin_field_email_placeholder", text: $email)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                #endif
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section {
                    // 改自己的密码服务器要先验旧密码,这里不做,留给网页后台。
                    if editingUser != nil, !isSelf {
                        Toggle("server_admin_reset_password", isOn: $resetsPassword)
                    }
                    if editingUser == nil || resetsPassword {
                        HStack {
                            TextField("server_admin_field_password", text: $password)
                                .font(.body.monospaced())
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            Button {
                                password = ServerUserPassword.generate()
                            } label: {
                                Label("server_admin_generate_password", systemImage: "dice")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("server_admin_generate_password"))
                        }
                    }
                } footer: {
                    if isSelf {
                        Text("server_admin_self_password_footer")
                    }
                }

                Section {
                    Toggle(isOn: $isAdmin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("server_admin_field_admin")
                            Text("server_admin_field_admin_detail").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isSelf)
                } footer: {
                    if isSelf { Text("server_admin_self_admin_footer") }
                }

                if let libraries, !libraries.isEmpty, !isAdmin {
                    Section {
                        ForEach(libraries) { library in
                            Button {
                                if selectedLibraries.contains(library.id) {
                                    selectedLibraries.remove(library.id)
                                } else {
                                    selectedLibraries.insert(library.id)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selectedLibraries.contains(library.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedLibraries.contains(library.id) ? Color.accentColor : Color.secondary)
                                    Text(library.name).foregroundStyle(.primary)
                                    Spacer()
                                    if let total = library.songCount {
                                        Text(String(format: String(localized: "server_admin_library_songs_format"), total))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("server_admin_libraries")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(editorTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("save") { save() }.disabled(!canSave)
                    }
                }
            }
            .alert(
                "server_admin_password_issued_title",
                isPresented: Binding(get: { issuedPassword != nil }, set: { if !$0 { issuedPassword = nil } })
            ) {
                Button("server_admin_copy_password") {
                    copy(issuedPassword ?? "")
                    issuedPassword = nil
                    dismiss()
                }
                Button("done", role: .cancel) {
                    issuedPassword = nil
                    dismiss()
                }
            } message: {
                Text(String(format: String(localized: "server_admin_password_issued_format"), userName, issuedPassword ?? ""))
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var needsPassword: Bool { editingUser == nil || resetsPassword }

    private var editorTitle: LocalizedStringKey {
        editingUser == nil ? "server_admin_add_user" : "server_admin_edit_user"
    }

    private var canSave: Bool {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isSaving else { return false }
        if needsPassword, password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if let libraries, !libraries.isEmpty, !isAdmin, selectedLibraries.isEmpty { return false }
        return true
    }

    private func save() {
        guard canSave,
              let admin = sourceManager.connector(for: source) as? any ServerAdminConnector else { return }
        isSaving = true
        errorMessage = nil
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let newPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let libraryIDs: [String]? = (libraries?.isEmpty == false && !isAdmin) ? selectedLibraries.sorted() : nil
        Task { @MainActor in
            do {
                if let user = editingUser {
                    let draft = ServerAdmin.Draft(
                        userName: user.userName,
                        displayName: shownName.isEmpty ? user.userName : shownName,
                        email: mail,
                        password: resetsPassword ? newPassword : nil,
                        isAdmin: isSelf ? user.isAdmin : isAdmin,
                        libraryIDs: libraryIDs
                    )
                    try await admin.updateServerAdminUser(id: user.id, draft)
                    onSaved(String(format: String(localized: "server_admin_saved_format"), name))
                    if resetsPassword && !isSelf {
                        issuedPassword = newPassword
                    } else {
                        dismiss()
                    }
                } else {
                    try await admin.createServerAdminUser(ServerAdmin.Draft(
                        userName: name,
                        displayName: shownName.isEmpty ? name : shownName,
                        email: mail,
                        password: newPassword,
                        isAdmin: isAdmin,
                        libraryIDs: libraryIDs
                    ))
                    onSaved(String(format: String(localized: "server_admin_created_format"), name))
                    issuedPassword = newPassword
                }
            } catch {
                errorMessage = ServerAdminErrorText.message(for: error)
            }
            isSaving = false
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - 小工具

enum ServerUserPassword {
    /// 12 位,去掉了容易看错的 0/O、1/l/I。
    static func generate() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<12).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }
}

enum ServerAdminErrorText {
    static func message(for error: Error) -> String {
        guard let failure = error as? ServerAdmin.Failure else { return error.localizedDescription }
        switch failure {
        case .unavailable: return String(localized: "server_admin_error_unavailable")
        case .notAdmin: return String(localized: "server_admin_error_not_admin")
        case .authenticationFailed: return String(localized: "server_admin_error_auth")
        case .accountMismatch: return String(localized: "server_admin_error_account_mismatch")
        case .invalidResponse: return String(localized: "server_admin_error_invalid_response")
        case .duplicateName: return String(localized: "server_admin_error_duplicate")
        case .rejected(let message):
            return [String(localized: "server_admin_error_rejected"), message]
                .compactMap { $0 }.joined(separator: "\n")
        }
    }
}
