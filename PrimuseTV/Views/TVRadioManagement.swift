#if os(tvOS)
import SwiftUI
import UIKit
import PrimuseKit

// MARK: - 台标

/// 电台台标的取法。用户自己选的图(`logoData`)永远优先;没有时用目录、清单或
/// 自动发现带来的远程台标地址,取回后缓存在本机。
///
/// 远程台标原先在电视端完全不显示 —— 从目录添加的台只存地址不存字节,
/// 在 iPhone 上有图,到了电视上就只剩占位。
enum TVRadioLogoLoader {
    /// 台标来源的指纹。视图用它判断要不要重新取图。
    static func identity(for station: RadioStation) -> Int {
        var hasher = Hasher()
        hasher.combine(station.id)
        hasher.combine(station.logoData)
        hasher.combine(station.remoteLogoURL)
        hasher.combine(station.logoFileName)
        return hasher.finalize()
    }

    static func data(for station: RadioStation) async -> Data? {
        if let data = station.logoData, !data.isEmpty { return data }
        // 音乐源自带台标(logoFileName)的台,远程台标只在用户自己填了图片链接时才上场,
        // 与 iPhone / Mac 的取图顺序一致。
        let hasOwnedLogo = station.logoFileName?.isEmpty == false
        guard !hasOwnedLogo || station.remoteLogoSource?.isUserProvided == true,
              let remote = RadioLogoURLPolicy.normalized(station.remoteLogoURL),
              let url = URL(string: remote) else { return nil }

        // 地址进缓存键:别的设备换了台标地址,这里不会一直拿着旧图。
        let cacheID = RadioStationArtworkResolutionPolicy.remoteLogoCacheSongID(for: station.id)
            + "#" + stableDigest(remote)
        if let cached = await MetadataAssetStore.shared.cachedCoverData(forSongID: cacheID) {
            return cached
        }

        // 首页电台那一排不是懒加载的,上千个台会同时要图;限住同时下载的数量。
        await fetchGate.acquire()
        defer { Task { await fetchGate.release() } }
        guard !Task.isCancelled else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty,
              data.count <= 4 * 1_024 * 1_024,
              UIImage(data: data) != nil else { return nil }
        await MetadataAssetStore.shared.cacheCover(data, forSongID: cacheID)
        return data
    }

    private static let fetchGate = TVRadioLogoFetchGate(limit: 4)

    /// 跨进程启动稳定的短摘要(`hashValue` 每次启动都会变,不能进磁盘缓存键)。
    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

private actor TVRadioLogoFetchGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // 名额直接交给下一个等待者,active 不变。
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - 首页「添加电台」卡片

struct TVRadioAddCard: View {
    var width: CGFloat = 220
    let action: () -> Void

    var body: some View {
        TVFocusButton(ring: false, action: action) { focused in
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: TVRadius.cover, style: .continuous)
                        .fill(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
                    RoundedRectangle(cornerRadius: TVRadius.cover, style: .continuous)
                        .strokeBorder(TVColor.cardBorder, style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    Image(systemName: "plus")
                        .font(.system(size: width * 0.24, weight: .semibold))
                        .foregroundStyle(focused ? TVColor.brand : TVColor.textMuted)
                }
                .frame(width: width, height: width)
                .tvFocusRing(focused, radius: TVRadius.cover, scale: 1.04, lift: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(PMString("ext.tv.radio.add"))
                        .tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2, reservesSpace: true)
                    Text(PMString("ext.tv.radio.addSubtitle"))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(1)
                }
                .padding(.top, 12)
                .padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityLabel(Text(PMString("ext.tv.radio.add")))
    }
}

// MARK: - 添加电台

/// 电视端添加电台。遥控器打字很费劲,所以主入口是按名称搜在线目录、一键添加;
/// 手动输入流地址作为第二个页签留着。添加的台写进与 iPhone / Mac 同一份电台存储。
struct TVRadioAddView: View {
    private enum Mode { case search, manual }
    private enum SearchState: Equatable {
        case idle
        case searching
        case finished
        case failed
    }
    private enum Field: Hashable { case query, name, url }

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .search
    @State private var query = ""
    @State private var results: [RadioDirectoryClient.Result] = []
    @State private var searchState: SearchState = .idle
    @State private var searchTask: Task<Void, Never>?
    @State private var manualName = ""
    @State private var manualURL = ""
    @State private var manualError: String?
    @State private var notice: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            card
                .padding(.horizontal, 90)
                .padding(.vertical, 50)
        }
        .onExitCommand { dismiss() }
        .onDisappear { searchTask?.cancel() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(PMString("ext.tv.radio.add"))
                    .tvFont(.pageTitle)
                    .foregroundStyle(TVColor.text)
                Spacer(minLength: 0)
                modeButton(.search, title: PMString("ext.tv.radio.modeSearch"), icon: "magnifyingglass")
                modeButton(.manual, title: PMString("ext.tv.radio.modeManual"), icon: "link")
            }
            .focusSection()
            Rectangle().fill(TVColor.divider)
                .frame(height: 1)
                .padding(.top, 24).padding(.bottom, 26)

            Group {
                switch mode {
                case .search: searchContent
                case .manual: manualContent
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Image(systemName: "icloud")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(TVColor.textFaint)
                Text(notice ?? PMString("ext.tv.radio.syncHint"))
                    .tvFont(.caption)
                    .foregroundStyle(notice == nil ? TVColor.textFaint : TVColor.brand)
                    .lineLimit(2)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 60).padding(.vertical, 46)
        .frame(maxWidth: 1320, maxHeight: .infinity, alignment: .topLeading)
        .tvPanel(radius: 26)
    }

    private func modeButton(_ target: Mode, title: String, icon: String) -> some View {
        TVPillButton(
            title: title,
            systemImage: icon,
            style: mode == target ? .solid : .glass,
            isSelected: mode == target
        ) {
            mode = target
            notice = nil
        }
    }

    // MARK: 搜索目录

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel(PMString("ext.tv.radio.searchLabel"), icon: "magnifyingglass", active: focusedField == .query)
            HStack(spacing: 18) {
                TVTextFieldBox {
                    TextField("", text: $query)
                        .focused($focusedField, equals: .query)
                        .submitLabel(.search)
                        .onSubmit(search)
                        .accessibilityLabel(Text(PMString("ext.tv.radio.searchLabel")))
                }
                TVPillButton(
                    title: PMString("ext.tv.radio.searchButton"),
                    systemImage: "magnifyingglass",
                    style: .solid,
                    action: search
                )
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .focusSection()

            searchResults
                .padding(.top, 22)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch searchState {
        case .idle:
            statusLine(PMString("ext.tv.radio.directoryNote"), icon: "globe")
        case .searching:
            HStack(spacing: 16) {
                ProgressView()
                Text(PMString("ext.tv.radio.searching"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
            }
            .padding(.top, 10)
        case .failed:
            statusLine(PMString("ext.tv.radio.searchFailed"), icon: "exclamationmark.triangle", tint: TVColor.warn)
        case .finished where results.isEmpty:
            statusLine(PMString("ext.tv.radio.noResults"), icon: "radio")
        case .finished:
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(results) { result in
                        resultRow(result)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
            }
            .focusSection()
        }
    }

    private func resultRow(_ result: RadioDirectoryClient.Result) -> some View {
        let isAdded = store.hasRadioStation(streamURL: result.streamURL)
        return TVFocusButton(radius: 16, scale: 1.01, lift: 0, action: { add(result) }) { focused in
            HStack(spacing: 22) {
                TVRadioDirectoryLogo(urlString: result.faviconURL)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: result.name)
                        .tvFont(.rowTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(1)
                    let detail = detailText(for: result)
                    Text(verbatim: detail.isEmpty ? " " : detail)
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Label(
                    isAdded ? PMString("ext.tv.radio.added") : PMString("ext.tv.radio.addButton"),
                    systemImage: isAdded ? "checkmark.circle.fill" : "plus.circle"
                )
                .tvFont(.caption, weight: .semibold)
                .foregroundStyle(isAdded ? TVColor.brand : (focused ? TVColor.text : TVColor.textMuted))
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityLabel(Text(verbatim: result.name))
        .accessibilityValue(Text(isAdded ? PMString("ext.tv.radio.added") : detailText(for: result)))
    }

    private func detailText(for result: RadioDirectoryClient.Result) -> String {
        var parts: [String] = []
        if let country = result.country { parts.append(country) }
        if let codec = result.codec { parts.append(codec.uppercased()) }
        if let bitrate = result.bitrate { parts.append("\(bitrate) kbps") }
        return parts.joined(separator: " · ")
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        searchState = .searching
        notice = nil
        searchTask = Task { @MainActor in
            do {
                let found = try await RadioDirectoryClient.search(name: text)
                guard !Task.isCancelled else { return }
                results = found
                searchState = .finished
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searchState = .failed
            }
        }
    }

    private func add(_ result: RadioDirectoryClient.Result) {
        guard !store.hasRadioStation(streamURL: result.streamURL) else {
            notice = PMString("ext.tv.radio.duplicate")
            return
        }
        if let station = store.addRadioStation(
            name: result.name,
            streamURL: result.streamURL,
            homepageURL: result.homepageURL,
            logoURL: result.faviconURL,
            logoSource: .directoryFavicon
        ) {
            notice = PMString("ext.tv.radio.addedNotice", station.name)
        }
    }

    // MARK: 手动输入

    private var manualContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel(PMString("ext.tv.radio.nameLabel"), icon: "textformat", active: focusedField == .name)
            TVTextFieldBox {
                TextField("", text: $manualName)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .url }
                    .accessibilityLabel(Text(PMString("ext.tv.radio.nameLabel")))
            }
            fieldLabel(PMString("ext.tv.radio.urlLabel"), icon: "link", active: focusedField == .url)
                .padding(.top, 24)
            TVTextFieldBox(mono: true) {
                TextField("", text: $manualURL)
                    .focused($focusedField, equals: .url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addManual)
                    .accessibilityLabel(Text(PMString("ext.tv.radio.urlLabel")))
            }

            HStack(spacing: 18) {
                TVPillButton(
                    title: PMString("ext.tv.radio.addButton"),
                    systemImage: "plus",
                    style: .solid,
                    action: addManual
                )
                if let manualError {
                    Label(manualError, systemImage: "exclamationmark.triangle")
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.warn)
                        .lineLimit(2)
                }
            }
            .padding(.top, 30)
        }
        .onChange(of: manualName) { _, _ in manualError = nil }
        .onChange(of: manualURL) { _, _ in manualError = nil }
    }

    private func addManual() {
        let name = RadioStationValidation.normalizedName(manualName)
        guard let url = RadioStationValidation.normalizedURLString(manualURL), !name.isEmpty else {
            manualError = PMString("ext.tv.radio.invalidInput")
            return
        }
        guard !store.hasRadioStation(streamURL: url) else {
            manualError = PMString("ext.tv.radio.duplicate")
            return
        }
        guard let station = store.addRadioStation(name: name, streamURL: url) else {
            manualError = PMString("ext.tv.radio.invalidInput")
            return
        }
        manualName = ""
        manualURL = ""
        manualError = nil
        notice = PMString("ext.tv.radio.addedNotice", station.name)
    }

    // MARK: 零件

    private func fieldLabel(_ title: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                .foregroundStyle(active ? TVColor.brand : TVColor.textFaint)
                .frame(width: 26)
            Text(title)
                .tvFont(.caption)
                .foregroundStyle(active ? TVColor.text : TVColor.textFaint)
        }
        .padding(.bottom, 10)
    }

    private func statusLine(_ text: String, icon: String, tint: Color = TVColor.textMuted) -> some View {
        Label(text, systemImage: icon)
            .tvFont(.caption)
            .foregroundStyle(tint)
            .padding(.top, 10)
    }
}

/// 搜索结果里的台标缩略图。目录给的 favicon 常常失效,取不到就显示电台图标。
private struct TVRadioDirectoryLogo: View {
    let urlString: String?
    private let side: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TVColor.surface)
            Image(systemName: "radio.fill")
                .font(.system(size: side * 0.4, weight: .semibold))
                .foregroundStyle(TVColor.textGhost)
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 删除确认

/// 删除电台前确认。电台存储与 iPhone / Mac 共用,开着 iCloud 同步时删除会传到
/// 所有设备,所以不做「长按即删」。
struct TVRadioDeleteConfirmation: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let station: RadioStation

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.35)
            TVColor.bg.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    TVRadioArtworkView(station: station, size: 120, radius: 18)
                    Text(PMString("ext.tv.radio.deleteConfirm", station.name))
                        .tvFont(.sectionTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(3)
                }
                Text(PMString("ext.tv.radio.deleteNote"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                HStack(spacing: 18) {
                    TVPillButton(
                        title: PMString("ext.tv.radio.delete"),
                        systemImage: "trash",
                        style: .solid
                    ) {
                        store.removeRadioStation(id: station.id)
                        dismiss()
                    }
                    TVPillButton(title: String(localized: "cancel"), systemImage: "xmark") {
                        dismiss()
                    }
                }
                .padding(.top, 8)
            }
            .padding(40)
            .frame(width: 900, alignment: .leading)
            .tvPanel(radius: 22)
        }
        .onExitCommand { dismiss() }
    }
}
#endif
