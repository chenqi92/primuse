import SwiftUI
import PrimuseKit

/// 各源各条线路起的名字。走 `CloudKVSSync`(同一个 Apple ID 的 iPhone、iPad、Mac 跟着变),
/// 不写进音乐源本身:改名只是换个叫法,不该像改地址那样打断正在跑的扫描、重连服务器。
@MainActor
@Observable
final class SourceRouteLabelStore {
    static let shared = SourceRouteLabelStore()

    private(set) var labels: SourceConnectionRouteLabels
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let syncsWithCloud: Bool

    init(defaults: UserDefaults = .standard, registersWithCloud: Bool = true) {
        self.defaults = defaults
        syncsWithCloud = registersWithCloud
        labels = .decode(defaults.data(forKey: SourceConnectionRouteLabels.storageKey))
        guard registersWithCloud else { return }
        CloudKVSSync.shared.register(key: SourceConnectionRouteLabels.storageKey) { [weak self] in
            self?.reload()
        }
    }

    func customLabel(sourceID: String, kind: SourceConnectionCandidateKind) -> SourceConnectionRouteLabel? {
        labels.label(sourceID: sourceID, kind: kind)
    }

    func setLabel(_ label: SourceConnectionRouteLabel?, sourceID: String, kind: SourceConnectionCandidateKind) {
        var next = labels
        next.setLabel(label, sourceID: sourceID, kind: kind)
        guard next != labels else { return }
        labels = next
        defaults.set(next.encoded(), forKey: SourceConnectionRouteLabels.storageKey)
        if syncsWithCloud {
            CloudKVSSync.shared.markChanged(key: SourceConnectionRouteLabels.storageKey)
        }
    }

    private func reload() {
        let next = SourceConnectionRouteLabels.decode(defaults.data(forKey: SourceConnectionRouteLabels.storageKey))
        if next != labels { labels = next }
    }
}

extension SourceConnectionRouteLabel {
    var localizedTitle: String {
        String(localized: String.LocalizationValue(localizationKey))
    }

    /// 每个名字一种颜色:卡片上一眼认得出现在走的是哪条。
    var tint: Color {
        switch self {
        case .lan: .green
        case .internet: .blue
        case .dataHog: .red
        case .lightSpeed: .orange
        case .zenLoading: .teal
        case .whenever: .mint
        case .mayVanish: .pink
        case .offlineLifeline: .indigo
        case .homeCellar: .brown
        case .godfathersStash: .purple
        case .freeloaded: .pink
        case .cloudFoster: .cyan
        case .inMyPocket: .indigo
        case .rentedTurf: .brown
        case .goldenEars: .orange
        case .masterVault: .purple
        case .justNoise: .gray
        case .cyberVinyl: .indigo
        case .backgroundSnack: .green
        case .moveInReady: .mint
        case .bareShell: .gray
        case .cyberBazaar: .orange
        case .digSite: .brown
        case .headphonesOnly: .pink
        case .grindFuel: .blue
        case .slackerSupply: .teal
        case .carRave: .red
        case .trafficCalm: .green
        case .lateNightFeels: .indigo
        case .preWorkout: .red
        }
    }
}

extension SourceConnectionRouteLabel.Category {
    var localizedTitle: String {
        String(localized: String.LocalizationValue(localizationKey))
    }

    var systemImage: String {
        switch self {
        case .network: "network"
        case .ownership: "person.2.fill"
        case .quality: "waveform"
        case .tidiness: "square.grid.2x2"
        case .scene: "figure.walk"
        }
    }
}

/// 一条线路此刻怎么叫、什么颜色。卡片、详情页、诊断共用一套。
@MainActor
enum SourceRouteNaming {
    static func label(for candidate: SourceConnectionCandidate, in source: MusicSource) -> SourceConnectionRouteLabel? {
        SourceConnectionRouteNamingPolicy.label(
            for: candidate.kind,
            custom: SourceRouteLabelStore.shared.customLabel(sourceID: source.id, kind: candidate.kind)
        )
    }

    /// 起过名字用起的;没起过时内网叫「内网」、公网叫「公网」,厂商中转写厂商名,另加的线路叫「线路 N」。
    static func name(for candidate: SourceConnectionCandidate, in source: MusicSource) -> String {
        if let label = label(for: candidate, in: source) { return label.localizedTitle }
        return defaultName(for: candidate, in: source)
    }

    /// 没起名字时的叫法(另加的线路、厂商中转没有预设名)。
    static func defaultName(for candidate: SourceConnectionCandidate, in source: MusicSource) -> String {
        if let label = SourceConnectionRouteNamingPolicy.defaultLabel(for: candidate.kind) {
            return label.localizedTitle
        }
        switch candidate.kind {
        case .vendorRemote:
            return String(localized: source.type.usesSynologyConnectionMode
                ? "synology_connection_quickconnect"
                : "fnmusic_connection_fnconnect")
        case .localAddress, .publicAddress, .alternative:
            let position = (source.configuredConnectionCandidates.firstIndex { $0.kind == candidate.kind } ?? 0) + 1
            return String(format: String(localized: "source_route_numbered_format"), position)
        }
    }

    static func tint(for candidate: SourceConnectionCandidate, in source: MusicSource) -> Color {
        if let label = label(for: candidate, in: source) { return label.tint }
        return candidate.kind == .vendorRemote ? .teal : .gray
    }

    static func systemImage(for candidate: SourceConnectionCandidate, in source: MusicSource) -> String {
        if let label = label(for: candidate, in: source) { return label.systemImage }
        return SourceConnectionRouteText.iconName(for: candidate.kind)
    }

    /// 手动选一条线路,或者 nil 交回自动。线路是这个源的设置,跟着源同步;换了要重连。
    static func select(
        _ kind: SourceConnectionCandidateKind?,
        sourceID: String,
        sourceStore: SourcesStore,
        sourceManager: SourceManager,
        scanService: ScanService
    ) {
        guard let current = sourceStore.source(id: sourceID),
              let configuration = current.connectionConfiguration,
              configuration.effectiveSelectedRoute != kind,
              kind == nil || current.configuredConnectionCandidates.contains(where: { $0.kind == kind }) else { return }
        sourceStore.update(sourceID) { row in
            row.connectionConfiguration?.clearLegacyRouteRestriction()
            row.connectionConfiguration?.selectedRoute = kind
            row = row.projectingPreferredConnectionForLegacy()
        }
        scanService.removeSynologyAPI(for: sourceID)
        Task { await sourceManager.refreshConnector(for: sourceID) }
    }
}

/// 线路菜单:用哪条(自动或手选),以及给每条换个名字。卡片上长按线路标签、详情页的线路下拉共用。
struct SourceRouteMenuContent: View {
    let source: MusicSource

    @Environment(SourcesStore.self) private var sourceStore
    @Environment(SourceManager.self) private var sourceManager
    @Environment(ScanService.self) private var scanService

    var body: some View {
        let routes = source.configuredConnectionCandidates
        if routes.count > 1 {
            Picker(selection: Binding(
                get: { source.connectionConfiguration?.effectiveSelectedRoute },
                set: { kind in
                    SourceRouteNaming.select(
                        kind, sourceID: source.id, sourceStore: sourceStore,
                        sourceManager: sourceManager, scanService: scanService
                    )
                }
            )) {
                Label("source_address_transport_automatic", systemImage: "arrow.triangle.branch")
                    .tag(nil as SourceConnectionCandidateKind?)
                ForEach(routes) { route in
                    Label(SourceRouteNaming.name(for: route, in: source), systemImage: SourceRouteNaming.systemImage(for: route, in: source))
                        .tag(Optional(route.kind))
                }
            } label: {
                Text("source_connection_route")
            }
            .pickerStyle(.inline)
        }
        Section {
            ForEach(routes) { route in
                SourceRouteRenamePicker(source: source, route: route)
            }
        }
    }
}

/// 给一条线路挑个名字。挑的是预设,不用打字:最上面是内网直连、公网直连,其余按网络、来源、音质、
/// 整洁度、场景分成几组。另加的线路、厂商中转可以挑回原来的叫法。
struct SourceRouteRenamePicker: View {
    let source: MusicSource
    let route: SourceConnectionCandidate

    var body: some View {
        let store = SourceRouteLabelStore.shared
        let selection = Binding<SourceConnectionRouteLabel?>(
            get: { SourceRouteNaming.label(for: route, in: source) },
            set: { store.setLabel($0, sourceID: source.id, kind: route.kind) }
        )
        Menu {
            Picker(selection: selection) {
                if SourceConnectionRouteNamingPolicy.defaultLabel(for: route.kind) == nil {
                    Text(verbatim: SourceRouteNaming.defaultName(for: route, in: source))
                        .tag(nil as SourceConnectionRouteLabel?)
                }
                ForEach(SourceConnectionRouteLabel.allCases.filter { $0.category == nil }) { label in
                    Label(label.localizedTitle, systemImage: label.systemImage)
                        .tag(Optional(label))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            ForEach(SourceConnectionRouteLabel.Category.allCases) { category in
                Picker(selection: selection) {
                    ForEach(category.labels) { label in
                        Label(label.localizedTitle, systemImage: label.systemImage)
                            .tag(Optional(label))
                    }
                } label: {
                    Label(category.localizedTitle, systemImage: category.systemImage)
                }
                .pickerStyle(.menu)
            }
        } label: {
            Label(
                String(format: String(localized: "source_route_rename_format"), SourceRouteNaming.name(for: route, in: source)),
                systemImage: "character.cursor.ibeam"
            )
        }
    }
}

/// 卡片上那颗小小的线路标签:名字带颜色。点一下换到下一条线路,长按选自动、改名字。
/// 不知道能点也没关系 —— 它首先是告诉你现在走的哪条。
struct SourceRouteChip: View {
    let source: MusicSource
    let route: SourceConnectionCandidate

    @Environment(SourcesStore.self) private var sourceStore
    @Environment(SourceManager.self) private var sourceManager
    @Environment(ScanService.self) private var scanService

    var body: some View {
        // 读一下名字表,改名之后这颗标签跟着重画。
        let _ = SourceRouteLabelStore.shared.labels
        let name = SourceRouteNaming.name(for: route, in: source)
        let tint = SourceRouteNaming.tint(for: route, in: source)
        Menu {
            SourceRouteMenuContent(source: source)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: SourceRouteNaming.systemImage(for: route, in: source))
                    .font(.system(size: 9, weight: .bold))
                Text(verbatim: name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
            .fixedSize()
        } primaryAction: {
            cycle()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .pmAnimation(.control, value: route.kind)
        .accessibilityLabel(Text("source_connection_route"))
        .accessibilityValue(Text(verbatim: name))
    }

    private func cycle() {
        guard let next = SourceConnectionRouteNamingPolicy.nextRoute(
            after: route.kind,
            in: source.configuredConnectionCandidates
        ) else { return }
        PMHaptics.playbackModeToggled()
        SourceRouteNaming.select(
            next, sourceID: source.id, sourceStore: sourceStore,
            sourceManager: sourceManager, scanService: scanService
        )
    }
}
