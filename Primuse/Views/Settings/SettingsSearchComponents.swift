import Observation
import SwiftUI
import PrimuseKit

enum SettingsDestination: Hashable {
    case page(SettingsPage, String?)
}

@MainActor
@Observable
final class SettingsSearchState {
    enum Content {
        case settings, recent, results
    }

    var query = ""
    var isPresented = false {
        didSet {
            if !isPresented { query = "" }
        }
    }

    var content: Content {
        guard isPresented else { return .settings }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .recent : .results
    }

    /// 只有正在展示搜索结果时才隐藏完整设置列表。搜索框处于激活状态但没有
    /// 查询词时, "最近使用" 只是列表顶部的附加分组, 完整列表照常显示。
    var showsSettingsRows: Bool { content != .results }

    /// 结束一次搜索会话: 收起搜索框并清空查询, 让设置页回到完整列表。
    func endSession() {
        query = ""
        isPresented = false
    }
}

struct SettingsSearchNavigationDismissal: ViewModifier {
    let isNavigating: Bool
    let search: SettingsSearchState
    @Environment(\.dismissSearch) private var dismissSearch

    func body(content: Content) -> some View {
        content.onChange(of: isNavigating) { _, isNavigating in
            guard isNavigating else { return }
            // 在 searchable 的环境内结束系统搜索交互，避免返回时恢复搜索焦点并再次调整导航栏。
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dismissSearch()
                search.endSession()
            }
        }
    }
}

#if os(iOS)
/// 设置根页列表上方常驻的搜索框，由页面自己画，挂在页面的顶部安全区栏里。
///
/// 不用系统的 `.searchable(placement: .navigationBarDrawer(displayMode: .always))`：抽屉搜索框长在
/// 导航栏上，每次切到设置这个页签，导航栏都先按没有抽屉的高度排出来（顶上一小条），再把搜索框连同列表
/// 往下放出来，和首页、资料库这些直接出现的页签不一致。放进页面自己的安全区栏（资料库根页的分类行
/// 同一做法）后，它和列表在同一帧里排好，切页签时随页面一起出现。
///
/// 会话状态仍在 `SettingsSearchState`：点进输入框就开始一次搜索（列表顶上出「最近使用」），
/// 收起键盘不结束，点「取消」、打开结果推进详情页时才结束。
struct SettingsSearchBar: View {
    @Bindable var search: SettingsSearchState
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            field
            if search.isPresented {
                Button(action: cancel) {
                    Text("cancel")
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .accessibilityIdentifier("settings.search.cancel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // 只让这一条里的「取消」滑进滑出，列表换内容不跟着动。
        .animation(PMMotion.control.resolved(reduceMotion: reduceMotion), value: search.isPresented)
        .onChange(of: isFocused) { _, focused in
            if focused, !search.isPresented { search.isPresented = true }
        }
        .onChange(of: search.query) { _, query in
            if !query.isEmpty, !search.isPresented { search.isPresented = true }
        }
        .onChange(of: search.isPresented) { _, presented in
            // 打开结果、点「取消」都会结束会话：键盘一起收起，返回时不再弹出来。
            if !presented { isFocused = false }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            TextField(SettingsStrings.text("Search settings"), text: $search.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit { isFocused = false }
                .accessibilityIdentifier("settings.search.field")

            if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("clear"))
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, search.query.isEmpty ? 13 : 4)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(.thinMaterial, in: Capsule())
        .background(Color.secondary.opacity(0.08), in: Capsule())
        .overlay {
            Capsule()
                .stroke(
                    isFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .contentShape(Capsule())
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
    }

    private func cancel() {
        isFocused = false
        search.endSession()
    }
}
#endif

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
