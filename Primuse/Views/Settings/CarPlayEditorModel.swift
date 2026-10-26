#if os(iOS)
import Foundation
import Observation
import PrimuseKit
import CarPlay

extension CarPlayMainTab {
    var displayTitle: String {
        let custom = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        if kind == .collection, let content { return content.title }
        return NSLocalizedString(kind.titleKey, comment: "")
    }
}

@MainActor @Observable
final class CarPlayEditorModel {
    private(set) var configuration: CarPlayLayoutConfiguration
    private(set) var history = CarPlayLayoutHistory()
    var selectedID: String?
    var inspectorVisible = false
    var homeEditorVisible = false
    var selectedTabID: String?
    @ObservationIgnored let settings: CarPlaySettingsStore
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var continuousStart: CarPlayLayoutConfiguration?

    init(settings: CarPlaySettingsStore) {
        self.settings = settings
        configuration = settings.configuration
        selectedID = configuration.blocks.first?.id
    }

    var selected: CarPlayLayoutBlock? { configuration.blocks.first { $0.id == selectedID } }
    var maximumTabCount: Int { max(1, CPTabBarTemplate.maximumTabCount) }
    var visibleTabs: [CarPlayMainTab] { configuration.visibleTabs(maximumCount: maximumTabCount) }
    var canAddTab: Bool {
        configuration.tabs.count < CarPlayLayoutConfiguration.maximumSavedTabCount && configuration.tabs.filter(\.isVisible).count < maximumTabCount
    }

    func selectTab(_ id: String) {
        continuousChange(false)
        selectedTabID = id
        homeEditorVisible = configuration.tabs.first { $0.id == id }?.kind == .home
        inspectorVisible = false
    }

    func showMainMenu() {
        continuousChange(false)
        homeEditorVisible = false
        inspectorVisible = false
    }

    func renameTab(_ id: String, title: String) {
        change { config in
            var tabs = config.tabs
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            tabs[index].title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            config.tabs = tabs
        }
    }

    @discardableResult func addTab(_ kind: CarPlayMainTab.Kind, content: CarPlayLayoutItem? = nil) -> Bool {
        guard canAddTab else { return false }
        let tab = CarPlayMainTab(kind: kind, content: content)
        guard tab.isValid else { return false }
        change { $0.tabs.append(tab) }
        selectTab(tab.id)
        return true
    }

    func removeTab(_ id: String) {
        guard let tab = configuration.tabs.first(where: { $0.id == id }),
              !tab.isVisible || configuration.tabs.filter(\.isVisible).count > 1 else { return }
        change { $0.tabs.removeAll { $0.id == id } }
        reconcileSelection()
    }

    func toggleTab(_ tab: CarPlayMainTab) {
        change { $0.setTabVisible(tab.id, visible: !tab.isVisible, maximumCount: maximumTabCount) }
        reconcileSelection()
    }

    @discardableResult func dropTab(_ values: [String], before id: String?) -> Bool {
        guard let value = values.first, value.hasPrefix("carplay-tab:") else { return false }
        var accepted = false
        change { accepted = $0.moveTab(String(value.dropFirst("carplay-tab:".count)), before: id) }
        return accepted
    }

    func moveTab(_ id: String, by offset: Int) {
        let tabs = configuration.tabs
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs.indices.contains(index + offset) else { return }
        let destination = offset < 0 ? index - 1 : index + 2
        change { $0.moveTab(id, before: tabs.indices.contains(destination) ? tabs[destination].id : nil) }
    }

    func select(_ id: String) {
        guard configuration.blocks.contains(where: { $0.id == id }) else { return }
        selectedID = id
        homeEditorVisible = true
        selectedTabID = configuration.tabs.first { $0.kind == .home }?.id
        inspectorVisible = true
    }

    func change(_ action: (inout CarPlayLayoutConfiguration) -> Void) {
        var next = configuration
        action(&next)
        guard next != configuration else { return }
        if continuousStart == nil { history.record(configuration, replacing: next) }
        configuration = next
        scheduleSave()
    }

    func update(_ id: String, _ action: (inout CarPlayLayoutBlock) -> Void) {
        change { config in
            var blocks = config.blocks
            guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
            action(&blocks[index])
            config.blocks = blocks
        }
    }

    func continuousChange(_ active: Bool) {
        if active {
            if continuousStart == nil { continuousStart = configuration }
        } else if let start = continuousStart {
            history.record(start, replacing: configuration)
            continuousStart = nil
            flush()
        }
    }

    func undo() {
        continuousChange(false)
        guard let value = history.undo(configuration) else { return }
        configuration = value
        reconcileSelection()
        scheduleSave()
    }

    func redo() {
        guard let value = history.redo(configuration) else { return }
        configuration = value
        reconcileSelection()
        scheduleSave()
    }

    func apply(_ style: CarPlayVisualStyle) { change { $0.applyVisualStyle(style) } }

    func apply(_ saved: CarPlaySavedLayout) {
        change { $0 = saved.configuration }
        reconcileSelection()
    }

    func add(_ kind: CarPlayLayoutBlockKind) {
        guard configuration.blocks.count < CarPlayLayoutConfiguration.maximumBlockCount else { return }
        homeEditorVisible = true
        selectedTabID = configuration.tabs.first { $0.kind == .home }?.id
        if kind != .custom, let existing = configuration.blocks.first(where: { $0.kind == kind }) {
            selectedID = existing.id
            update(existing.id) { $0.isVisible = true }
            return
        }
        var block = CarPlayLayoutBlock(kind: kind, style: configuration.browseStyle)
        block.columns = configuration.visualStyle == .wall ? 3 : 2
        block.itemLimit = kind == .shortcuts ? 24 : 12
        if kind == .custom {
            block.title = String(localized: "carplay_cover_wall")
            block.style = .covers
            block.columns = 2
        }
        change { $0.blocks.append(block) }
        selectedID = block.id
    }

    func remove(_ id: String) {
        change { $0.blocks.removeAll { $0.id == id } }
        reconcileSelection()
        inspectorVisible = false
    }

    func reset(_ block: CarPlayLayoutBlock) {
        update(block.id) {
            let items = $0.items
            let custom = $0.usesCustomContent
            $0 = CarPlayLayoutBlock(id: block.id, kind: block.kind, style: configuration.browseStyle)
            $0.items = items
            $0.usesCustomContent = custom
        }
    }

    @discardableResult func move(_ id: String, before: String?) -> Bool {
        var accepted = false
        change { accepted = $0.moveBlock(id, before: before) }
        return accepted
    }

    func move(_ id: String, by offset: Int) {
        let blocks = configuration.blocks
        guard let index = blocks.firstIndex(where: { $0.id == id }), blocks.indices.contains(index + offset) else { return }
        let destination = offset < 0 ? index - 1 : index + 2
        move(id, before: blocks.indices.contains(destination) ? blocks[destination].id : nil)
    }

    @discardableResult func addContent(_ item: CarPlayLayoutItem, to id: String, resolved: [CarPlayHomeItem]) -> Bool {
        guard var block = configuration.blocks.first(where: { $0.id == id }), !block.kind.keepsLiveContent else { return false }
        if !block.usesCustomContent && block.kind != .custom {
            block.items = Array(resolved.compactMap(\.layoutItem).prefix(60))
        }
        guard block.items.count < 60, !block.items.contains(where: { $0.kind == item.kind && $0.targetID == item.targetID }) else { return false }
        block.usesCustomContent = true
        var copy = item
        copy.id = UUID().uuidString
        block.items.append(copy)
        block.itemLimit = max(block.itemLimit, block.items.count)
        update(id) { $0 = block }
        return true
    }

    func removeContent(_ item: CarPlayHomeItem, from id: String, resolved: [CarPlayHomeItem]) {
        update(id) { block in
            guard !block.kind.keepsLiveContent else { return }
            if !block.usesCustomContent && block.kind != .custom {
                block.items = Array(resolved.compactMap(\.layoutItem).prefix(60))
            }
            block.usesCustomContent = true
            block.items.removeAll { $0.id == item.id }
        }
    }

    @discardableResult func drop(_ values: [String], before id: String?) -> Bool {
        guard let value = values.first, value.hasPrefix("carplay-block:") else { return false }
        return move(String(value.dropFirst("carplay-block:".count)), before: id)
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        settings.configuration = configuration
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flush()
        }
    }

    private func reconcileSelection() {
        if !visibleTabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = visibleTabs.first?.id }
        if !configuration.tabs.contains(where: { $0.id == selectedTabID && $0.kind == .home }) {
            homeEditorVisible = false
            inspectorVisible = false
        }
        if !configuration.blocks.contains(where: { $0.id == selectedID }) {
            selectedID = configuration.blocks.first?.id
        }
    }
}
#endif
