import Observation
import SwiftUI
import PrimuseKit

enum SettingsDestination: Hashable {
    case page(SettingsPage, String?)
}

@MainActor
@Observable
final class SettingsNavigation {
    struct Request: Equatable {
        let token = UUID()
        let settingID: String
    }
    static let shared = SettingsNavigation()
    var request: Request?
    var activatedToken: UUID?
    var presentedToken: UUID?

    func open(_ id: String) {
        guard SettingsCatalog.byID[id] != nil else { return }
        SettingsSearchHistory.shared.record(id)
        #if os(macOS)
        SettingsWindowController.shared.show(settingID: id)
        #else
        request = Request(settingID: id)
        #endif
    }
}

@MainActor
@Observable
final class SettingsSearchHistory {
    static let shared = SettingsSearchHistory()
    private static let key = "primuse.settings.recentItems"
    private(set) var ids: [String]

    init() {
        ids = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }
    func record(_ id: String) {
        ids = SettingsRecentItems.recording(id, in: ids, availableIDs: Set(SettingsCatalog.byID.keys))
        UserDefaults.standard.set(ids, forKey: Self.key)
    }
    func clear() {
        ids = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

struct SettingsSearchResultRow: View {
    let item: SettingDefinition
    @Environment(PlaybackSettingsStore.self) private var playback
    @Environment(MusicIntelligenceService.self) private var intelligence

    var body: some View {
        let status = SettingsActionService(playback: playback, showsIntelligence: intelligence.shouldExposeRemoteConfiguration).status(for: item.id)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.page?.category.icon ?? "gearshape")
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title).foregroundStyle(.primary)
                Text(verbatim: item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let reason = status.reason {
                    Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let value = status.value {
                Text(verbatim: value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.result." + item.id)
    }
}

private struct SettingsFocusKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsFocusedAnchor: String? {
        get { self[SettingsFocusKey.self] }
        set { self[SettingsFocusKey.self] = newValue }
    }
}

private struct SettingsAnchorPreference: PreferenceKey {
    static let defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

private struct SettingsAnchorModifier: ViewModifier {
    let id: String
    @Environment(\.settingsFocusedAnchor) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlighted = false

    func body(content: Content) -> some View {
        content
            .id(id)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(highlighted ? 0.14 : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .preference(key: SettingsAnchorPreference.self, value: [id])
            .task(id: focused) {
                highlighted = focused == id
                guard highlighted else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { highlighted = false }
            }
    }
}

extension View {
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchorModifier(id: id))
    }
}

struct SettingsFocusedPage<Content: View>: View {
    let itemID: String?
    var page: SettingsPage? = nil
    @ViewBuilder var content: () -> Content
    @Environment(PlaybackSettingsStore.self) private var playback
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didLocate = false

    private var item: SettingDefinition? { itemID.flatMap { SettingsCatalog.byID[$0] } }

    private var fidelityRestricted: Bool {
        guard let page = item?.page ?? page else { return false }
        return playback.outputMode == .highFidelity && [.equalizer, .effects].contains(page)
    }

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .disabled(fidelityRestricted)
                .environment(\.settingsFocusedAnchor, item?.anchorID)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let id = item?.id ?? page?.id,
                       let reason = SettingsActionService(playback: playback, showsIntelligence: intelligence.shouldExposeRemoteConfiguration).status(for: id).reason {
                        Label(reason, systemImage: "info.circle")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.regularMaterial)
                    }
                }
                .task(id: itemID) {
                    didLocate = false
                    guard let item else { return }
                    await Task.yield()
                    proxy.scrollTo(item.anchorID, anchor: .center)
                }
                .onPreferenceChange(SettingsAnchorPreference.self) { anchors in
                    guard !didLocate, let item, anchors.contains(item.anchorID) else { return }
                    didLocate = true
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        proxy.scrollTo(item.anchorID, anchor: .center)
                    }
                }
        }
    }
}
