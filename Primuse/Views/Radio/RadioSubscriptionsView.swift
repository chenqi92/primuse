import SwiftUI
import PrimuseKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - 文案

/// 订阅相关的几段拼装文案。列表页、详情页和电台页顶部那一行共用。
@MainActor
enum RadioSubscriptionText {
    /// 「3 小时前」。一分钟以内说「刚刚」—— 相对时间格式器会说「0 秒后」这类怪话。
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 {
            return String(localized: "radio_subscription_just_now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// 「3 小时前更新」，从没更新过就说清楚。
    static func updated(_ date: Date?) -> String {
        guard let date else { return String(localized: "radio_subscription_never_updated") }
        return String(format: String(localized: "radio_subscription_updated %@"), relative(date))
    }

    /// 「新增 3 · 更新 2 · 移除 1 · 保留 1（你整理过的）」。
    static func summary(_ summary: RadioSubscriptionRefreshSummary) -> String {
        var parts: [String] = []
        if summary.added > 0 {
            parts.append(String(format: String(localized: "radio_subscription_result_added %lld"), summary.added))
        }
        if summary.updated > 0 {
            parts.append(String(format: String(localized: "radio_subscription_result_updated %lld"), summary.updated))
        }
        if summary.removed > 0 {
            parts.append(String(format: String(localized: "radio_subscription_result_removed %lld"), summary.removed))
        }
        if summary.kept > 0 {
            parts.append(String(format: String(localized: "radio_subscription_result_kept %lld"), summary.kept))
        }
        var text = parts.isEmpty
            ? String(localized: "radio_subscription_result_unchanged")
            : parts.joined(separator: " · ")
        if summary.truncated {
            text += "\n" + String(
                format: String(localized: "radio_subscription_result_truncated %lld"),
                RadioSubscriptionMergePolicy.maximumEntries
            )
        }
        return text
    }

    /// 电台页顶部那一行：「2 份订阅 · 3 小时前更新」，有问题时换成提醒。
    static func overview(for store: RadioSubscriptionsStore) -> String {
        let count = String(
            format: String(localized: "radio_subscription_count %lld"),
            store.subscriptions.count
        )
        let detail = store.needsAttention
            ? String(localized: "radio_subscription_needs_attention")
            : updated(store.latestRefreshDate)
        return "\(count) · \(detail)"
    }

    /// 订阅电台卡片上替代流地址的那一行：本机认识这份订阅时显示订阅名。
    static func stationSource(_ station: RadioStation) -> String? {
        guard station.isSubscribed else { return nil }
        return RadioSubscriptionsStore.shared.subscription(id: station.subscriptionID)?.name
    }

    /// 编辑页里那句说明：「来自订阅「X」，名称和地址随清单更新」。
    /// 本机不认识这份订阅(别的设备订阅的、定义没同步过来)时不点名。
    static func editorNote(for station: RadioStation) -> String {
        if let name = stationSource(station) {
            return String(format: String(localized: "radio_subscription_editor_note %@"), name)
        }
        return String(localized: "radio_subscription_editor_note_unknown")
    }
}

// MARK: - 电台页顶部的状态行

/// 有订阅时显示一行紧凑状态，点进订阅管理。刷新失败或有待确认的移除时变提醒色。
struct RadioSubscriptionStatusRow: View {
    let action: @MainActor () -> Void

    private var store: RadioSubscriptionsStore { .shared }

    var body: some View {
        if !store.subscriptions.isEmpty {
            let attention = store.needsAttention
            let tint: Color = attention ? .orange : .secondary
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: attention ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text(RadioSubscriptionText.overview(for: store))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.6)
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(tint.opacity(0.12), in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("radio_subscriptions_title"))
            .accessibilityValue(Text(RadioSubscriptionText.overview(for: store)))
        }
    }
}

// MARK: - 批量添加里的订阅卡片

/// 「清单链接」取回清单后，结果表上方那张卡片。外框由调用方按各自平台的样式包。
struct RadioSubscriptionOfferCard: View {
    /// 这个地址已经订阅过了。
    let existingSubscription: RadioSubscription?
    /// 清单里唯一有效条目的数量。
    let entryCount: Int
    @Binding var isOn: Bool
    let onManage: @MainActor () -> Void

    private var exceedsLimit: Bool {
        entryCount > RadioSubscriptionMergePolicy.maximumEntries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let existingSubscription {
                HStack(spacing: 8) {
                    Label("radio_subscription_already_subscribed", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    Spacer(minLength: 8)
                    Button("radio_subscription_manage") { onManage() }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                Text(existingSubscription.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if exceedsLimit {
                Toggle(isOn: .constant(false)) {
                    Label("radio_subscription_toggle", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(true)
                Text(String(
                    format: String(localized: "radio_subscription_too_large %lld %lld"),
                    entryCount,
                    RadioSubscriptionMergePolicy.maximumEntries
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle(isOn: $isOn) {
                    Label("radio_subscription_toggle", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                }
                Text("radio_subscription_toggle_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isOn {
                    Text("radio_subscription_unchecked_note")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 订阅列表

/// 清单订阅管理。iOS 与 macOS 共用这一个页面，以弹页形式出现。
/// 「添加订阅」推进同一个导航栈，而不是再叠一层弹页。
struct RadioSubscriptionsView: View {
    private enum Route: Hashable {
        case subscription(String)
        case add
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(RadioStationsStore.self) private var stationsStore
    @State private var path: [Route] = []

    /// `initialSubscriptionID` 不为空时直接打开那份订阅的详情；`startsAdding` 为真时
    /// 直接进「添加订阅」，返回键回到订阅列表。
    init(initialSubscriptionID: String? = nil, startsAdding: Bool = false) {
        let initial: [Route]
        if let initialSubscriptionID {
            initial = [.subscription(initialSubscriptionID)]
        } else if startsAdding {
            initial = [.add]
        } else {
            initial = []
        }
        _path = State(initialValue: initial)
    }

    private var store: RadioSubscriptionsStore { .shared }
    private var service: RadioSubscriptionService { .shared }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.subscriptions.isEmpty {
                    // 空态与列表是整块替换,交叉淡入会让两块同时占着导航栈的内容位,
                    // 所以走「旧的直接走、新的淡进来」。
                    emptyState.pmAppearFade(.contentAppear)
                } else {
                    subscriptionList.pmAppearFade(.contentAppear)
                }
            }
            .navigationTitle("radio_subscriptions_title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .subscription(let id):
                    RadioSubscriptionDetailView(subscriptionID: id)
                case .add:
                    // 订阅成功或发现早就订阅过，都换成那一份的详情，返回键回到列表。
                    RadioSubscriptionAddView { id in
                        path = [.subscription(id)]
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        path.append(.add)
                    } label: {
                        Label("radio_subscriptions_add", systemImage: "plus")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("radio_subscriptions_empty_title", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("radio_subscriptions_empty_description")
        } actions: {
            Button("radio_subscriptions_add") { path.append(.add) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var subscriptionList: some View {
        List {
            Section {
                ForEach(store.sortedSubscriptions) { subscription in
                    NavigationLink(value: Route.subscription(subscription.id)) {
                        RadioSubscriptionRow(
                            subscription: subscription,
                            status: store.status(for: subscription.id),
                            stationCount: stationsStore.stations(inSubscription: subscription.id).count,
                            isRefreshing: service.isRefreshing(subscription.id)
                        )
                    }
                }
            } footer: {
                Text("radio_subscription_auto_update_footer")
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
    }
}

private struct RadioSubscriptionRow: View {
    let subscription: RadioSubscription
    let status: RadioSubscriptionRefreshStatus
    let stationCount: Int
    let isRefreshing: Bool

    private var detailText: String {
        let count = String(format: String(localized: "radio_subscription_station_count %lld"), stationCount)
        let refreshed = [subscription.lastRefreshedAt, status.lastSuccessAt].compactMap { $0 }.max()
        return "\(count) · \(RadioSubscriptionText.updated(refreshed))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(subscription.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if !status.heldRemovalStationIDs.isEmpty {
                        Text("radio_subscription_pending_badge")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                }
                Text(subscription.displayHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if status.hasFailure, let message = status.lastErrorMessage {
                    Text(String(format: String(localized: "radio_subscription_last_failed %@"), message))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .pmFadeTransition(motion: .control)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 添加订阅

/// 添加一份清单订阅：填地址、取回清单、看一眼里面有哪些电台，然后订阅。
/// 下载、解析、判重和订阅都与批量添加的「清单链接」同一套，只是这里只做订阅这一件事。
struct RadioSubscriptionAddView: View {
    /// 订阅成功，或者发现这个地址早就订阅过时，交给列表页打开那一份的详情。
    let onOpenSubscription: @MainActor (String) -> Void

    @Environment(RadioStationsStore.self) private var stationsStore
    @State private var urlString = ""
    /// 当前结果表是从哪个地址取回的；地址一改就作废。
    @State private var fetchedURL: String?
    @State private var candidates: [RadioImportCandidate] = []
    @State private var selection: Set<RadioImportCandidate.ID> = []
    @State private var groupsAsFolders = false
    @State private var isFetching = false
    @State private var errorMessage: String?
    @State private var insecureHost: String?
    @FocusState private var urlFieldFocused: Bool

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var existingSubscription: RadioSubscription? {
        fetchedURL
            .flatMap(RadioSubscriptionIdentity.subscriptionID(listURL:))
            .flatMap { RadioSubscriptionsStore.shared.subscription(id: $0) }
    }

    /// 清单里唯一有效条目的数量，订阅上限按它算。
    private var uniqueValidEntryCount: Int {
        Set(candidates.compactMap { candidate in
            candidate.status == .invalid ? nil : RadioImportParser.streamIdentityKey(candidate.urlString)
        }).count
    }

    private var exceedsLimit: Bool {
        uniqueValidEntryCount > RadioSubscriptionMergePolicy.maximumEntries
    }

    private var hasManifestGroups: Bool {
        candidates.contains { $0.groupTitle != nil }
    }

    private var canSubscribe: Bool {
        fetchedURL != nil
            && existingSubscription == nil
            && uniqueValidEntryCount > 0
            && !exceedsLimit
            && !isFetching
    }

    var body: some View {
        Form {
            Section {
                TextField(
                    text: $urlString,
                    prompt: Text(verbatim: "https://example.com/radio.m3u")
                ) {
                    Text("radio_subscription_list_url")
                }
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                #endif
                .focused($urlFieldFocused)
                .onSubmit { fetch() }

                Button {
                    fetch()
                } label: {
                    HStack {
                        Label("radio_batch_url_fetch", systemImage: "arrow.down.circle")
                        Spacer()
                        if isFetching {
                            ProgressView()
                                .controlSize(.small)
                                .pmFadeTransition(motion: .control)
                        }
                    }
                }
                .disabled(isFetching || trimmedURL.isEmpty)
            } header: {
                Text("radio_subscription_list_url")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("radio_batch_url_hint")
                    Text("radio_subscription_toggle_footer")
                }
            }

            if fetchedURL != nil {
                resultSections
            }
        }
        .formStyle(.grouped)
        .navigationTitle("radio_subscriptions_add")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("radio_subscription_subscribe_only") { subscribe() }
                    .disabled(!canSubscribe)
            }
        }
        .onChange(of: urlString) { _, _ in
            // 结果表只对应取回它的那个地址；改了地址就收起旧结果，免得订阅错。
            guard fetchedURL != nil else { return }
            clearResults()
        }
        .onAppear {
            if urlString.isEmpty { urlFieldFocused = true }
        }
        .alert(
            String(localized: "radio_batch_error_title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("insecure_http_warning_title", isPresented: Binding(
            get: { insecureHost != nil },
            set: { if !$0 { insecureHost = nil } }
        )) {
            Button("cancel", role: .cancel) { insecureHost = nil }
            Button("insecure_http_continue", role: .destructive) {
                guard let host = insecureHost else { return }
                SSLTrustStore.shared.allowInsecureHTTP(domain: host)
                insecureHost = nil
                fetch()
            }
        } message: {
            Text(String(
                format: String(localized: "insecure_http_warning_message %@"),
                insecureHost ?? ""
            ))
        }
    }

    // MARK: 结果

    @ViewBuilder
    private var resultSections: some View {
        if let existing = existingSubscription {
            Section {
                Label("radio_subscription_already_subscribed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(existing.name)
                    .foregroundStyle(.secondary)
                Button("radio_subscription_manage") { onOpenSubscription(existing.id) }
            }
        } else if exceedsLimit {
            Section {
                Text(String(
                    format: String(localized: "radio_subscription_too_large %lld %lld"),
                    uniqueValidEntryCount,
                    RadioSubscriptionMergePolicy.maximumEntries
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            if hasManifestGroups {
                Section {
                    Toggle("radio_subscription_groups_as_folders", isOn: $groupsAsFolders)
                }
            }

            Section {
                let libraryKeys = Set(stationsStore.stations.compactMap {
                    RadioImportParser.streamIdentityKey($0.streamURL)
                })
                ForEach(candidates) { candidate in
                    candidateRow(candidate, libraryKeys: libraryKeys)
                }
            } header: {
                HStack {
                    Text(String(
                        format: String(localized: "radio_subscription_station_count %lld"),
                        uniqueValidEntryCount
                    ))
                    Spacer()
                    Button("radio_batch_select_playable") { selectAllPlayable() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                .textCase(nil)
            } footer: {
                Text("radio_subscription_unchecked_note")
            }
        }
    }

    /// 订阅只管清单里独一份、可用的条目：已在电台库或清单里重复的、无效的都不能勾。
    private func candidateRow(_ candidate: RadioImportCandidate, libraryKeys: Set<String>) -> some View {
        let isSelected = selection.contains(candidate.id)
        let selectable = candidate.status == .playable
        return Button {
            toggle(candidate)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))

                RadioCandidateLogoView(urlString: candidate.logoURLString, size: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(candidate.urlString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let group = candidate.groupTitle {
                        Label(group, systemImage: "folder")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if let status = statusText(candidate, libraryKeys: libraryKeys) {
                    Text(status)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(candidate.status == .invalid ? Color.red : Color.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (candidate.status == .invalid ? Color.red : Color.orange).opacity(0.14),
                            in: Capsule()
                        )
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .opacity(selectable ? 1 : 0.55)
    }

    private func statusText(_ candidate: RadioImportCandidate, libraryKeys: Set<String>) -> String? {
        switch candidate.status {
        case .playable:
            return nil
        case .invalid:
            return String(localized: "radio_batch_status_invalid")
        case .duplicate:
            let inLibrary = RadioImportParser.streamIdentityKey(candidate.urlString)
                .map { libraryKeys.contains($0) } == true
            return inLibrary
                ? String(localized: "radio_subscription_in_library")
                : String(localized: "radio_batch_status_duplicate")
        }
    }

    // MARK: 动作

    private func fetch() {
        let address = trimmedURL
        guard !address.isEmpty, !isFetching else { return }
        urlFieldFocused = false
        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                let text = try await RadioPlaylistDownloader.fetch(address)
                let parsed = RadioImportParser.parse(text, existing: stationsStore.stations)
                guard !parsed.isEmpty else {
                    clearResults()
                    errorMessage = String(localized: "radio_batch_file_no_entries")
                    return
                }
                candidates = parsed
                selection = Set(parsed.filter(\.isPlayable).map(\.id))
                // 清单自带分组时默认按它建文件夹，这是几百条的清单最省事的整理方式。
                groupsAsFolders = parsed.contains { $0.groupTitle != nil }
                fetchedURL = RadioStationValidation.normalizedURLString(address)
            } catch let error as TrustedHTTPTransportError {
                // 明文 http 的清单地址跟电台流一样，得先问过用户再连。
                guard case .permissionRequired(let host) = error else {
                    errorMessage = error.localizedDescription
                    return
                }
                insecureHost = host
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clearResults() {
        fetchedURL = nil
        candidates = []
        selection = []
        groupsAsFolders = false
    }

    private func toggle(_ candidate: RadioImportCandidate) {
        guard candidate.status == .playable else { return }
        if selection.contains(candidate.id) {
            selection.remove(candidate.id)
        } else {
            selection.insert(candidate.id)
        }
    }

    private func selectAllPlayable() {
        selection = Set(candidates.filter(\.isPlayable).map(\.id))
    }

    /// 首轮合并直接用已经取回的这批候选，不再下载一遍；没勾的可用条目记成排除，
    /// 以后清单更新也不会加进来。
    private func subscribe() {
        guard canSubscribe, let listURL = fetchedURL else { return }
        let excludedKeys = Set(candidates.compactMap { candidate -> String? in
            guard candidate.isPlayable, !selection.contains(candidate.id) else { return nil }
            return RadioImportParser.streamIdentityKey(candidate.urlString)
        })
        guard let result = RadioSubscriptionService.shared.subscribe(
            listURL: listURL,
            candidates: candidates,
            excludedEntryKeys: excludedKeys,
            usesListGroupsAsFolders: groupsAsFolders && hasManifestGroups
        ) else {
            errorMessage = String(localized: "radio_subscription_error_empty")
            return
        }
        let added = result.addedStationIDs.compactMap { stationsStore.station(id: $0) }
        for name in Set(added.compactMap(\.folderName)) {
            stationsStore.createFolder(name)
        }
        onOpenSubscription(result.subscriptionID)
    }
}

// MARK: - 订阅详情

/// 从批量添加页的「管理订阅」直接打开某一份订阅时用的外壳。
struct RadioSubscriptionDetailSheet: View {
    let subscriptionID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RadioSubscriptionDetailView(subscriptionID: subscriptionID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }
}

struct RadioSubscriptionDetailView: View {
    let subscriptionID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(RadioStationsStore.self) private var stationsStore
    @Environment(AudioPlayerService.self) private var player
    @State private var nameDraft = ""
    @State private var showingUnsubscribe = false
    @State private var insecurePrompt: InsecurePrompt?

    /// 明文 http 需要用户先信任主机：要么是清单地址本身，要么是点了播放的电台。
    private enum InsecurePrompt: Identifiable {
        case list(host: String)
        case station(RadioStation, host: String)

        var id: String {
            switch self {
            case .list(let host): return "list:\(host)"
            case .station(let station, _): return "station:\(station.id)"
            }
        }

        var host: String {
            switch self {
            case .list(let host), .station(_, let host): return host
            }
        }
    }

    private var store: RadioSubscriptionsStore { .shared }
    private var service: RadioSubscriptionService { .shared }
    private var subscription: RadioSubscription? { store.subscription(id: subscriptionID) }
    private var status: RadioSubscriptionRefreshStatus { store.status(for: subscriptionID) }
    private var isRefreshing: Bool { service.isRefreshing(subscriptionID) }

    var body: some View {
        Group {
            if let subscription {
                form(for: subscription)
            } else {
                ContentUnavailableView(
                    "radio_subscriptions_empty_title",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
        }
        .navigationTitle(subscription?.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { nameDraft = subscription?.name ?? "" }
        .onDisappear { commitRename() }
        .confirmationDialog(
            String(localized: "radio_subscription_unsubscribe_title"),
            isPresented: $showingUnsubscribe,
            titleVisibility: .visible
        ) {
            Button("radio_subscription_unsubscribe_keep") { unsubscribe(keepStations: true) }
            Button("radio_subscription_unsubscribe_remove", role: .destructive) {
                unsubscribe(keepStations: false)
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("radio_subscription_unsubscribe_message")
        }
        .alert("insecure_http_warning_title", isPresented: Binding(
            get: { insecurePrompt != nil },
            set: { if !$0 { insecurePrompt = nil } }
        )) {
            Button("cancel", role: .cancel) { insecurePrompt = nil }
            Button("insecure_http_continue", role: .destructive) {
                guard let prompt = insecurePrompt else { return }
                insecurePrompt = nil
                SSLTrustStore.shared.allowInsecureHTTP(domain: prompt.host)
                switch prompt {
                case .list: refresh()
                case .station(let station, _): performToggle(station)
                }
            }
        } message: {
            Text(String(
                format: String(localized: "insecure_http_warning_message %@"),
                insecurePrompt?.host ?? ""
            ))
        }
    }

    private func form(for subscription: RadioSubscription) -> some View {
        let held = status.heldRemovalStationIDs
        let stations = stationsStore.stations(inSubscription: subscriptionID)
        return Form {
            Section {
                TextField("radio_name", text: $nameDraft)
                    .onSubmit { commitRename() }
                LabeledContent("radio_subscription_list_url") {
                    Text(subscription.listURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("radio_subscription_copy_url", systemImage: "doc.on.doc") {
                    copyToPasteboard(subscription.listURL)
                }
            }

            if !held.isEmpty {
                Section {
                    Label {
                        Text(String(format: String(localized: "radio_subscription_held %lld"), held.count))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Button("radio_subscription_held_remove", role: .destructive) {
                        Task { await resolveHeld(remove: true) }
                    }
                    .disabled(isRefreshing)
                    Button("radio_subscription_held_keep") {
                        Task { await resolveHeld(remove: false) }
                    }
                    .disabled(isRefreshing)
                }
            }

            Section {
                LabeledContent("radio_subscription_last_updated") {
                    Text(RadioSubscriptionText.updated(
                        [subscription.lastRefreshedAt, status.lastSuccessAt].compactMap { $0 }.max()
                    ))
                }
                if let summary = status.lastSummary {
                    LabeledContent("radio_subscription_last_result") {
                        Text(RadioSubscriptionText.summary(summary))
                            .multilineTextAlignment(.trailing)
                    }
                }
                if status.hasFailure, let message = status.lastErrorMessage {
                    Text(String(format: String(localized: "radio_subscription_last_failed %@"), message))
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    refresh()
                } label: {
                    HStack {
                        Label(
                            status.hasFailure
                                ? String(localized: "radio_subscription_retry")
                                : String(localized: "radio_subscription_refresh_now"),
                            systemImage: "arrow.clockwise"
                        )
                        Spacer()
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .pmFadeTransition(motion: .control)
                        }
                    }
                }
                .disabled(isRefreshing)
            } header: {
                Text("radio_subscription_status_section")
            }

            Section {
                Toggle("radio_subscription_auto_update", isOn: Binding(
                    get: { subscription.autoUpdates },
                    set: { service.setAutoUpdates(id: subscriptionID, $0) }
                ))
            } footer: {
                Text("radio_subscription_auto_update_footer")
            }

            Section {
                Toggle("radio_subscription_groups_as_folders", isOn: Binding(
                    get: { subscription.usesListGroupsAsFolders },
                    set: { service.setUsesListGroupsAsFolders(id: subscriptionID, $0) }
                ))
            } footer: {
                Text("radio_subscription_groups_as_folders_footer")
            }

            Section {
                if stations.isEmpty {
                    Text("radio_subscription_no_stations")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stations) { station in
                        stationRow(station)
                    }
                }
            } header: {
                Text(String(
                    format: String(localized: "radio_subscription_station_count %lld"),
                    stations.count
                ))
            }

            Section {
                Button("radio_subscription_unsubscribe", role: .destructive) {
                    showingUnsubscribe = true
                }
            }
        }
        .formStyle(.grouped)
    }

    private func stationRow(_ station: RadioStation) -> some View {
        let isCurrent = player.currentRadioStation?.id == station.id
        let isPlaying = isCurrent && (player.isPlaying || player.isLoading)
        return Button {
            toggle(station)
        } label: {
            HStack(spacing: 10) {
                RadioStationArtworkView(station: station, size: 36, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(station.playbackSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isPlaying ? Color.red : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .pmAnimation(.control, value: isPlaying)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func commitRename() {
        guard let subscription else { return }
        let name = RadioStationValidation.normalizedName(nameDraft)
        guard !name.isEmpty, name != subscription.name else { return }
        service.rename(id: subscriptionID, to: name)
    }

    private func refresh() {
        Task {
            let outcome = await service.refresh(id: subscriptionID)
            if case .permissionRequired(let host) = outcome {
                insecurePrompt = .list(host: host)
            }
        }
    }

    private func resolveHeld(remove: Bool) async {
        let outcome = await service.resolveHeldRemovals(id: subscriptionID, remove: remove)
        if case .permissionRequired(let host) = outcome {
            insecurePrompt = .list(host: host)
        }
    }

    private func unsubscribe(keepStations: Bool) {
        service.unsubscribe(id: subscriptionID, keepStations: keepStations)
        dismiss()
    }

    private func toggle(_ station: RadioStation) {
        if let url = station.url,
           TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            insecurePrompt = .station(station, host: trustTarget)
            return
        }
        performToggle(station)
    }

    private func performToggle(_ station: RadioStation) {
        if player.currentRadioStation?.id == station.id,
           player.isPlaying || player.isLoading {
            player.pause()
        } else {
            SiriMediaInteractionDonor.donate(station: station)
            Task { await player.play(station: station, within: stationsStore.stations) }
        }
    }

    private func copyToPasteboard(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
