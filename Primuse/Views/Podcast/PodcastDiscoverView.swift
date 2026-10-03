import PrimuseKit
import SwiftUI

/// 发现:搜索 Apple 播客目录,不搜时看热门榜,可按分类筛。每行右边一个订阅键,点进去先看节目再决定。
///
/// 目录按 App Store 店面的地区查(中国大陆店面的结果由 Apple 按当地要求筛过);
/// 店面允许时,输入的是 RSS 地址就多给一行「用这个地址添加」。
struct PodcastDiscoverView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = PodcastDirectorySearch()
    @State private var genreID: Int?
    @State private var selectedShow: PodcastDirectoryShow?
    @State private var feedPreviewURL: URL?

    private var tint: Color { ListeningSpace.podcast.tint }

    private var trimmedQuery: String { search.trimmedQuery }
    private var typedFeedURL: URL? { search.typedFeedURL }
    private var results: [PodcastDirectoryShow] { search.results }
    private var isSearching: Bool { search.isSearching }
    private var searchError: String? { search.errorMessage }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if trimmedQuery.isEmpty {
                    genreChips
                    PodcastChartSection(genreID: genreID, limit: 50) { selectedShow = $0 }
                        .padding(.horizontal, 16)
                } else {
                    searchResults
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("podcast_discover")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $search.query, prompt: Text("podcast_search_prompt"))
        .task(id: trimmedQuery) { await search.run() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("done") { dismiss() }
            }
        }
        .navigationDestination(item: $selectedShow) { show in
            PodcastShowDetailView(source: .directory(show))
        }
        .navigationDestination(item: $feedPreviewURL) { url in
            PodcastShowDetailView(source: .feed(url))
        }
    }

    // MARK: - Browse

    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: Text("podcast_top_charts"), selected: genreID == nil) { genreID = nil }
                ForEach(PodcastDirectory.genreIDs, id: \.self) { id in
                    chip(title: Text(LocalizedStringKey(PodcastFormat.genreKey(id))), selected: genreID == id) { genreID = id }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(title: Text, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            pmWithAnimation(.selection) { action() }
        } label: {
            title
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary.opacity(0.7)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Search

    @ViewBuilder
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = typedFeedURL {
                Button {
                    feedPreviewURL = url
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.title3)
                            .foregroundStyle(tint)
                            .frame(width: 56, height: 56)
                            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("podcast_add_this_feed")
                                .font(.body.weight(.semibold))
                            Text(url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 68)
            }
            if isSearching && results.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if let searchError, results.isEmpty {
                ContentUnavailableView(
                    "podcast_search_failed",
                    systemImage: "wifi.exclamationmark",
                    description: Text(searchError)
                )
            } else if results.isEmpty, typedFeedURL == nil, !isSearching {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                ForEach(results) { show in
                    PodcastDirectoryRow(show: show) { selectedShow = show }
                    Divider().padding(.leading, 68)
                }
            }
        }
    }
}

/// 播客目录搜索:打字停一下再查,输入目录链接时直接按编号查。发现页与 Mac 播客页共用。
///
/// 目录按 App Store 店面的地区查;店面允许手填地址时,输入的像 RSS 地址就给出 `typedFeedURL`。
@MainActor
@Observable
final class PodcastDirectorySearch {
    var query = ""
    private(set) var results: [PodcastDirectoryShow] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 看起来是地址:有协议,或者像 example.com/feed 这样带点和斜杠。
    var typedFeedURL: URL? {
        let text = trimmedQuery
        guard PodcastAvailabilityService.shared.allowsCustomFeeds,
              PodcastFeedURL.appleDirectoryID(in: text) == nil,
              text.contains("://") || (text.contains(".") && text.contains("/")) else { return nil }
        return PodcastFeedURL.normalized(text)
    }

    /// 放在 `.task(id: trimmedQuery)` 里调:换了关键词旧任务被取消,只留最后一次的结果。
    func run() async {
        let term = trimmedQuery
        guard !term.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        // 打字时别每个字都去问。
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            if let directoryID = PodcastFeedURL.appleDirectoryID(in: term) {
                let found = try await PodcastDirectoryService.shared.lookup(directoryID)
                guard !Task.isCancelled else { return }
                results = found.map { [$0] } ?? []
            } else {
                let found = try await PodcastDirectoryService.shared.search(term)
                guard !Task.isCancelled else { return }
                results = found
            }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
        }
    }
}

/// 热门榜(总榜或某个分类)。没订阅时的主页和发现页共用。
struct PodcastChartSection: View {
    let genreID: Int?
    var limit = 50
    var openShow: (PodcastDirectoryShow) -> Void

    @State private var shows: [PodcastDirectoryShow] = []
    @State private var failed = false
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PodcastSectionHeader(titleKey: genreID == nil ? "podcast_top_charts" : LocalizedStringKey(PodcastFormat.genreKey(genreID ?? 0)))
                .padding(.bottom, 6)
            if isLoading && shows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else if failed && shows.isEmpty {
                Button {
                    Task { await load() }
                } label: {
                    Label("podcast_chart_failed_retry", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .padding(.vertical, 12)
            } else {
                ForEach(Array(shows.prefix(limit).enumerated()), id: \.element.id) { index, show in
                    PodcastDirectoryRow(show: show, rank: index + 1) { openShow(show) }
                    if index < min(limit, shows.count) - 1 {
                        Divider().padding(.leading, 96)
                    }
                }
            }
        }
        .task(id: "\(genreID ?? 0)|\(PodcastAvailabilityService.shared.policy.directoryCountry)") { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await PodcastDirectoryService.shared.chart(genreID: genreID)
            guard !Task.isCancelled else { return }
            shows = loaded
            failed = false
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

/// 目录里的一档节目:封面、名字、主播、分类,右边订阅键。
struct PodcastDirectoryRow: View {
    let show: PodcastDirectoryShow
    var rank: Int?
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    if let rank {
                        Text(verbatim: "\(rank)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                    PodcastArtwork(directoryShow: show, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(show.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let author = show.author, !author.isEmpty {
                            Text(author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            PodcastSubscribeButton(directoryShow: show)
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("podcast.directory.\(show.id)")
    }

    private var detail: String? {
        var parts: [String] = []
        if let genre = show.genre, !genre.isEmpty { parts.append(PodcastFormat.category(genre)) }
        if let count = show.episodeCount, count > 0 {
            parts.append(String(format: String(localized: "podcast_episode_count %lld"), count))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 订阅键:没订是「+」,订阅中转圈,订了是对勾(再点不会退订 —— 退订在节目页里,免得误触)。
struct PodcastSubscribeButton: View {
    let directoryShow: PodcastDirectoryShow
    /// Mac 的紧凑网格用小一号的圆键。
    var diameter: CGFloat = 34

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var pendingInsecureHost: String?

    private var store: PodcastStore { PodcastStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }

    private var isSubscribed: Bool {
        store.subscribedShow(directoryID: directoryShow.id) != nil
            || directoryShow.feedURL.flatMap { store.isSubscribed(feedURL: $0) } != nil
    }

    var body: some View {
        Button {
            guard !isSubscribed, !isWorking else { return }
            subscribe()
        } label: {
            Group {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else if isSubscribed {
                    Image(systemName: "checkmark")
                        .font(.system(size: diameter * 0.41, weight: .bold))
                        .foregroundStyle(tint)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: diameter * 0.44, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: diameter, height: diameter)
            .background(tint.opacity(isSubscribed ? 0.08 : 0.14), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: isSubscribed)
        .accessibilityLabel(Text(isSubscribed ? "podcast_subscribed" : "podcast_subscribe"))
        .alert("podcast_subscribe_failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("done") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .podcastInsecureHTTPAlert(host: $pendingInsecureHost) { subscribe() }
    }

    private func subscribe() {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await store.subscribe(directoryShow: directoryShow)
            } catch PodcastNetwork.Failure.insecureHTTP(let host) {
                pendingInsecureHost = host
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// 手填 RSS 地址(只有店面允许时才有入口)。先取一遍 feed,能读出节目再进节目页让用户确认订阅。
struct PodcastAddFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var previewURL: URL?
    @State private var pendingInsecureHost: String?
    @FocusState private var focused: Bool

    private var normalized: URL? { PodcastFeedURL.normalized(text) }

    var body: some View {
        Form {
            Section {
                TextField("podcast_feed_url_placeholder", text: $text)
                    #if os(iOS)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(check)
                    .accessibilityIdentifier("podcast.addFeed.field")
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    Text("podcast_feed_url_footer")
                }
            }
            Section {
                Button {
                    check()
                } label: {
                    HStack {
                        Text("podcast_feed_url_continue")
                        Spacer()
                        if isChecking { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(normalized == nil || isChecking)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("podcast_add_by_url")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("cancel") { dismiss() }
            }
        }
        .onAppear { focused = true }
        .navigationDestination(item: $previewURL) { url in
            PodcastShowDetailView(source: .feed(url))
        }
        .podcastInsecureHTTPAlert(host: $pendingInsecureHost) { check() }
    }

    private func check() {
        guard let url = normalized, !isChecking else { return }
        isChecking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isChecking = false }
            do {
                _ = try await PodcastStore.shared.preview(feedURL: url)
                previewURL = url
            } catch PodcastNetwork.Failure.insecureHTTP(let host) {
                pendingInsecureHost = host
            } catch is PodcastFeedError {
                errorMessage = String(localized: "podcast_error_not_a_feed")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
