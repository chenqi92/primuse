#if os(tvOS)
import PrimuseKit
import SwiftUI

enum TVScanProgressPresentationState: Equatable, Sendable {
    case scanning
    case complete
    case failed
}

enum TVScanProgressPresentationPolicy {
    static func state(for phase: TVSourceScanner.Phase) -> TVScanProgressPresentationState {
        switch phase {
        case .done:
            return .complete
        case .failed:
            return .failed
        default:
            return .scanning
        }
    }
}

/// 添加新源后(或长按源菜单)的扫描流程。目录型源选择目录，飞牛音乐直接扫描服务端曲库。
struct TVScanFlowView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: MusicSource
    var rereadMetadata = false
    var mode: TVScanMode = .full

    @State private var lister: TVDirectoryLister?
    @State private var path = "/"
    @State private var parentPaths: [String] = []
    @State private var breadcrumbNames: [String] = []
    @State private var entries: [TVDirEntry] = []
    /// 已勾选的目录,原样保存(顺序即勾选顺序)。上下级覆盖、同一目录的不同写法
    /// 都交给 `SourceDirectorySelectionPolicy`,与手机、Mac 的选择页同一套规则。
    @State private var selected: [String] = []
    @State private var loading = false
    @State private var started = false
    @State private var browseError: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var showsOTP = false
    /// 验证码通过后要重新加载的目录。浏览途中被 2FA 打断时记住原位置,
    /// 输完验证码直接回到原来那一层,而不是退回根目录重走一遍。
    @State private var pendingPathAfterOTP: String?
    /// 验证码这一趟是否真的通过。用户按 Menu 取消时不能重试 —— 那会立刻又撞上
    /// 两步验证、又弹出输入页,成了退不出去的死循环。
    @State private var otpVerified = false

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: started ? 0.5 : 0.4)
            TVColor.bg.opacity(0.48).ignoresSafeArea()
            if started {
                TVScanningView(
                    source: source,
                    onDone: { dismiss() },
                    onRetry: {
                        store.scanner.phase = .idle
                        started = false
                    },
                    onCancel: {
                        store.cancelScan(sourceID: source.id)
                        dismiss()
                    },
                    onEnterOTP: { showsOTP = true },
                    canCancel: store.activeScanSourceID == source.id
                )
                .onChange(of: store.scanner.needsTwoFactor) { _, needsCode in
                    // 扫描中途被要求验证码时直接进输入页;`started` 保持 true,
                    // 输完退出来就落在扫描页上,按「重试」即可继续。
                    guard needsCode, !showsOTP else { return }
                    showsOTP = true
                }
            } else if TVSourceScanner.serverCatalogTypes.contains(source.type) {
                // 整库型来源没有目录可选,直接给「开始扫描」。
                fnMusicPickView
            } else if rereadMetadata && !source.scannedDirectories.isEmpty {
                VStack(alignment: .leading, spacing: 24) {
                    Text(PMString("tv_metadata_reread")).tvFont(.pageTitle)
                    Text(source.name).tvFont(.sectionTitle)
                    Text(PMString("tv_metadata_reread_body")).tvFont(.body)
                        .foregroundStyle(TVColor.textMuted)
                    Text(source.scannedDirectories.joined(separator: "\n"))
                        .tvFont(.caption).foregroundStyle(TVColor.textFaint)
                        .lineLimit(4)
                    summaryPanel
                }
                .frame(maxWidth: 920, alignment: .leading)
            } else {
                pickView
            }
        }
        .fullScreenCover(isPresented: $showsOTP, onDismiss: {
            // 验证码通过后凭据/设备令牌已更新,回到未开始状态让用户直接重试。
            store.scanner.phase = .idle
            started = false
            let resume = pendingPathAfterOTP
            pendingPathAfterOTP = nil
            guard otpVerified else {
                // 用户放弃了验证码:把原来那条错误显示回去,不再自动重试。
                otpVerified = false
                if resume != nil { browseError = PMString("ext.tv.source.error.needs2FA") }
                return
            }
            otpVerified = false
            let refreshedLister = store.source(id: source.id)
                .flatMap { store.makeLister(for: $0) }
            if let refreshedLister { lister = refreshedLister }
            if let resume { load(resume, using: refreshedLister) }
        }) {
            if let tvSource = store.sources.first(where: { $0.id == source.id }) {
                TVOTPEntryView(source: tvSource, onVerified: { otpVerified = true })
                    .environment(store)
            }
        }
        .onDisappear {
            loadTask?.cancel()
        }
        .onAppear {
            if store.activeScanSourceID == source.id {
                started = true
                return
            }
            if source.type != .fnMusic && source.type != .daoliyu && source.type != .songloft, lister == nil {
                lister = store.makeLister(for: source)
                selected = mode == .incremental ? [] : source.scannedDirectories
                #if DEBUG
                if let preset = TVDebugLaunch.scanPreset { selected = preset }
                if !rereadMetadata, let debugPath = TVDebugLaunch.scanOpenPath {
                    parentPaths = ["/"]
                    breadcrumbNames = [(debugPath as NSString).lastPathComponent]
                    load(debugPath)
                    return
                }
                #endif
                if !rereadMetadata || selected.isEmpty { load("/") }
            }
        }
    }

    // MARK: 选目录(第 3 步)

    private var fnMusicPickView: some View {
        VStack(spacing: 28) {
            Image(systemName: source.type.iconName)
                .font(.system(size: 66, weight: .semibold))
                .foregroundStyle(TVColor.onBrand)
                .frame(width: 132, height: 132)
                .background(TVColor.brand, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            VStack(spacing: 10) {
                TVEyebrow(
                    text: PMString("ext.tv.scan.fullLibrary", source.type.displayName)
                )
                Text(PMString("ext.tv.scan.serverCatalogTitle"))
                    .tvFont(size: 42, weight: .bold, relativeTo: .title)
                    .foregroundStyle(TVColor.text)
                Text(PMString("ext.tv.scan.serverCatalogBody", source.type.displayName))
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
            }
            TVFocusButton(radius: 16, accent: TVColor.brand, scale: 1.05, lift: 4, action: startFnMusicScan) { focused in
                Label(PMString("ext.tv.scan.start"), systemImage: "arrow.triangle.2.circlepath")
                    .tvFont(.eyebrow, weight: .bold)
                    .foregroundStyle(TVColor.onBrand)
                    .padding(.horizontal, 46)
                    .padding(.vertical, 20)
                    .background(TVColor.brand.opacity(focused ? 1 : 0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if let browseError {
                Text(browseError)
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(TVColor.warn)
            }
            TVFocusButton(radius: 16, scale: 1.04, lift: 0, action: { dismiss() }) { focused in
                Text(PMString("ext.tv.sources.cancel"))
                    .tvFont(.meta, weight: .medium)
                    .foregroundStyle(TVColor.text)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 14)
                    .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pickView: some View {
        // 空判断和列表都要用,同一次刷新里只过滤一次。
        let directories = entries.filter(\.isDir)
        return HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(text: PMString("ext.tv.scan.step3")).padding(.bottom, 6)
                Text(mode == .incremental ? TVScanMode.incrementalTitle : PMString("ext.tv.scan.chooseFolders")).tvFont(size: 40, weight: .bold, relativeTo: .title2).foregroundStyle(TVColor.text).padding(.bottom, 6)
                Text(breadcrumb).tvFont(.caption, design: .monospaced).foregroundStyle(TVColor.textFaint).padding(.bottom, 22)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        if !parentPaths.isEmpty {
                            // 显式标 onOpen:尾随闭包会按顺序落到 onSelect 上,而「上一级」
                            // 不可勾选、只有打开按钮,那样按下去什么也不做。
                            folderRow(name: PMString("ext.tv.scan.up"), isUp: true, selectable: false,
                                      onOpen: { goUp() })
                        }
                        if loading {
                            HStack { ProgressView().tint(TVColor.brand); Text(PMString("ext.tv.scan.loading")).foregroundStyle(TVColor.textFaint) }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                        } else if let browseError {
                            Text(browseError)
                                .tvFont(.caption).foregroundStyle(TVColor.bad)
                                .multilineTextAlignment(.leading)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 16)
                            // 列目录失败时给一个能按的「重试」,不必退回上一级再进来。
                            folderRow(name: PMString("ext.tv.scan.retry"), isUp: false, selectable: false,
                                      icon: "arrow.clockwise", onOpen: { load(path) })
                        } else {
                            // 每一层最上面都能勾「整个文件夹」/「整个音乐源」:勾它等于
                            // 扫描下面的一切,包括以后新建的目录;已存的根选择也在这里取消。
                            wholeFolderRow
                            if directories.isEmpty {
                                Text(PMString("ext.tv.scan.noSubfolders"))
                                    .tvFont(.caption).foregroundStyle(TVColor.textGhost).padding(.vertical, 16)
                            }
                        }
                        TVPagedList(directories, spacing: 8) { _, e, onFocusChanged in
                            folderRow(name: e.name, isUp: false, selectable: true,
                                      state: selectionState(of: e.path, ancestors: parentPaths + [path]),
                                      onSelect: { toggle(e.path) }, onOpen: { openFolder(e) },
                                      onFocusChanged: onFocusChanged)
                        }
                        // 每一层目录一份新的懒加载列表:换目录时不在原地替换整批行
                        // (焦点所在的那一行会被移走),续页进度也从第一页重新算。
                        .id(path)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .focusSection()

            // 右侧「即将扫描 / 开始扫描」面板撑满高度,选目录列表往下任意一行往右都能到达。
            summaryPanel.frame(width: 380).frame(maxHeight: .infinity, alignment: .top).focusSection()
        }
        .padding(.horizontal, 120).padding(.vertical, 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func folderRow(name: String, isUp: Bool, selectable: Bool,
                           icon: String? = nil,
                           state: SourceDirectorySelectionPolicy.SelectionState = .unselected,
                           onSelect: @escaping () -> Void = {}, onOpen: @escaping () -> Void = {},
                           onFocusChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        let checked = state == .selected
        // 上级已勾选:这一行本来就会被扫描,勾选框显示淡色的勾并禁用,只能打开。
        let includedCaption = inclusionCaption(for: state)
        let included = includedCaption != nil
        // Opening and selecting are separate remote targets. Select now follows
        // the visible “Open” affordance; the trailing checkbox controls scan scope.
        return HStack(spacing: 10) {
            TVFocusButton(radius: 12, scale: 1.0, lift: 0, action: onOpen,
                          onFocusChanged: onFocusChanged) { focused in
                HStack(spacing: 16) {
                    Image(systemName: icon ?? (isUp ? "arrow.up.left" : "folder.fill"))
                        .font(.system(size: 22))
                        .foregroundStyle(checked ? TVColor.brand : TVColor.textFaint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .tvFont(.body, weight: checked ? .semibold : .regular)
                            .foregroundStyle(TVColor.text)
                            .lineLimit(1)
                        if let includedCaption {
                            Text(includedCaption)
                                .tvFont(.meta)
                                .foregroundStyle(TVColor.textFaint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if selectable {
                        Label(PMString("ext.tv.scan.open"), systemImage: "chevron.right")
                            .tvFont(.caption)
                            .foregroundStyle(focused ? TVColor.text : TVColor.textGhost)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
            }
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(includedCaption ?? ""))
            .accessibilityHint(Text(selectable ? PMString("ext.tv.scan.openFolder") : name))

            if selectable {
                TVFocusButton(radius: 12, scale: 1.0, lift: 0, action: onSelect,
                              onFocusChanged: onFocusChanged) { focused in
                    Image(systemName: checked || included ? "checkmark.square.fill" : "square")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(checkboxColor(checked: checked, included: included))
                        .frame(width: 62, height: 58)
                        .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
                }
                .disabled(included)
                .accessibilityLabel(Text(
                    includedCaption
                        ?? (checked ? PMString("ext.tv.scan.uncheck") : PMString("ext.tv.scan.check"))
                ))
                .accessibilityAddTraits(checked || included ? [.isButton, .isSelected] : .isButton)
            }
        }
        .contextMenu {
            if selectable {
                Button { onOpen() } label: { Label(PMString("ext.tv.scan.openFolder"), systemImage: "folder") }
                if !included {
                    Button { onSelect() } label: { Label(checked ? PMString("ext.tv.scan.uncheck") : PMString("ext.tv.scan.check"), systemImage: checked ? "square" : "checkmark.square") }
                }
            }
        }
    }

    /// 这一层最上面的「整个文件夹 / 整个音乐源」行:勾的是当前目录本身。
    /// 上级已勾选时同样显示淡色的勾并禁用,说明文字指出是哪一级。
    private var wholeFolderRow: some View {
        let target = currentSelectionPath
        let state = selectionState(of: target, ancestors: parentPaths)
        let checked = state == .selected
        let includedCaption = inclusionCaption(for: state)
        let included = includedCaption != nil
        let atRoot = parentPaths.isEmpty
        let title = atRoot
            ? String(localized: "folder_pick_whole_source")
            : String(format: String(localized: "folder_pick_whole_folder_format"), breadcrumbNames.last ?? path)
        let caption = includedCaption ?? String(localized: "folder_pick_includes_future")
        return TVFocusButton(radius: 12, scale: 1.0, lift: 0, action: { toggle(target) }) { focused in
            HStack(spacing: 16) {
                Image(systemName: atRoot ? "shippingbox.fill" : "folder.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(checked ? TVColor.brand : TVColor.textFaint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .tvFont(.body, weight: .semibold)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(1)
                    Text(caption)
                        .tvFont(.meta)
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: checked || included ? "checkmark.square.fill" : "square")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(checkboxColor(checked: checked, included: included))
                    .frame(width: 62)
            }
            .padding(.leading, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
        }
        .disabled(included)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(caption))
        .accessibilityHint(Text(
            included ? "" : (checked ? PMString("ext.tv.scan.uncheck") : PMString("ext.tv.scan.check"))
        ))
        .accessibilityAddTraits(checked || included ? [.isButton, .isSelected] : .isButton)
    }

    private func checkboxColor(checked: Bool, included: Bool) -> Color {
        if checked { return TVColor.brand }
        return included ? TVColor.textFaint : TVColor.text
    }

    private var summaryPanel: some View {
        VStack(spacing: 24) {
            if mode == .incremental {
                Text(TVScanMode.incrementalBody)
                    .tvFont(.caption).foregroundStyle(TVColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(text: PMString("ext.tv.scan.summary")).padding(.bottom, 14)
                summaryRow(PMString("ext.tv.scan.selected"), scanSelection.isEmpty ? String(localized: "folder_pick_none") : PMString("ext.tv.scan.folderCount", scanSelection.count))
                summaryRow(PMString("ext.tv.scan.metadata"), PMString(
                    rereadMetadata ? "tv_metadata_reread" : "ext.tv.scan.metadataValue"
                ))
                summaryRow(PMString("ext.tv.scan.playable"), PMString("ext.tv.scan.formats"))
            }
            .padding(26).frame(maxWidth: .infinity)
            .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(TVColor.cardBorder, lineWidth: 1) }

            // 什么都没勾时不再悄悄扫描当前目录(在根目录就是整个音乐源):
            // 「开始扫描」变灰,这里说明要先勾什么。只随勾选变化,不随焦点增删。
            if scanSelection.isEmpty {
                Text(String(localized: "folder_pick_select_hint"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textFaint)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let browseError {
                // 右栏只有 380pt 宽,错误文案必须按整行换行并左对齐,
                // 否则长句会挤成参差不齐的几行、把「开始扫描」顶下去。
                Text(browseError)
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.warn)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TVFocusButton(radius: 16, accent: TVColor.brand, scale: 1.05, lift: 4, action: startScan) { f in
                Label(PMString(rereadMetadata ? "tv_metadata_reread" : "ext.tv.scan.start"), systemImage: "arrow.triangle.2.circlepath")
                    .tvFont(.eyebrow, weight: .bold).foregroundStyle(TVColor.onBrand)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                    .background(TVColor.brand.opacity(scanSelection.isEmpty ? 0.35 : (f ? 1 : 0.88)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(scanSelection.isEmpty)
            TVFocusButton(radius: 16, scale: 1.04, lift: 0, action: { dismiss() }) { f in
                Text(PMString("ext.tv.sources.cancel")).tvFont(.meta, weight: .medium).foregroundStyle(TVColor.text)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(f ? TVColor.surfaceStrong : TVColor.surfaceSubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func summaryRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).tvFont(.caption).foregroundStyle(TVColor.textFaint)
            Spacer()
            Text(v).tvFont(.caption, weight: .semibold).foregroundStyle(TVColor.text)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(TVColor.divider).frame(height: 1) }
    }

    // MARK: 行为

    private var breadcrumb: String {
        let displayPath = breadcrumbNames.isEmpty ? "/" : "/" + breadcrumbNames.joined(separator: "/")
        return "\(source.name) · \(displayPath)"
    }

    private func openFolder(_ entry: TVDirEntry) {
        // 加载中列表已清空;万一按到了,别把正在进入的目录当成上一级压栈。
        guard !loading else { return }
        parentPaths.append(path)
        breadcrumbNames.append(entry.name)
        load(entry.path)
    }

    private func goUp() {
        guard let parent = parentPaths.popLast() else { return }
        if !breadcrumbNames.isEmpty { breadcrumbNames.removeLast() }
        load(parent)
    }

    private func load(_ p: String, using refreshedLister: TVDirectoryLister? = nil) {
        guard let activeLister = refreshedLister ?? lister else { return }
        loadTask?.cancel()
        path = p
        loading = true
        browseError = nil
        // 上一层的行不能留在新目录下面:它们的勾选状态按新目录算,按下去还会
        // 把正在进入的目录压进返回栈。
        entries = []
        loadTask = Task {
            do {
                let loaded = try await store.scanner.browse(lister: activeLister, path: p)
                guard !Task.isCancelled, path == p else { return }
                entries = loaded
                plog("📂 TV scan picker listed depth=\(parentPaths.count) entries=\(loaded.count) dirs=\(loaded.filter(\.isDir).count)")
            } catch {
                guard path == p else { return }
                if TVSourceErrorText.isSilent(error) {
                    // 被新的一次加载或离开页面取消时什么也不做;请求自己被中止
                    // (比如证书确认没通过)则不能一直转圈,给出错误和重试。
                    guard !Task.isCancelled else { return }
                    plog("📂 TV scan picker list aborted depth=\(parentPaths.count)")
                    entries = []
                    browseError = PMString("ext.tv.scan.connectFailed")
                    loading = false
                    return
                }
                plog("📂 TV scan picker list failed depth=\(parentPaths.count) error=\(type(of: error))")
                entries = []
                // 服务端要验证码时直接把用户送进输入页 —— 先报一条错、再让他退出去
                // 长按菜单里找「两步验证登录」,是上一版最让人困惑的地方。
                if SourceFailureClassifier.requiresTwoFactor(error) {
                    browseError = nil
                    loading = false
                    pendingPathAfterOTP = p
                    showsOTP = true
                    return
                }
                browseError = TVSourceErrorText.message(error: error)
            }
            if path == p { loading = false }
        }
    }

    /// 这一层「整个文件夹」行勾的路径。根目录就是整个音乐源:S3 的桶根存 "",
    /// 与手机端一致;其余源存 "/"。
    private var currentSelectionPath: String {
        guard parentPaths.isEmpty else { return path }
        return SourceDirectorySelectionPolicy.selectableRootPath(for: source.type, browserPath: "/") ?? "/"
    }

    /// 真正要扫描、要保存的目录:去掉重复写法和上级已勾选的下级。
    private var scanSelection: [String] {
        SourceDirectorySelectionPolicy.normalizedSelections(selected, for: source.type)
    }

    private func selectionState(
        of p: String,
        ancestors: [String]
    ) -> SourceDirectorySelectionPolicy.SelectionState {
        SourceDirectorySelectionPolicy.selectionState(
            of: p,
            in: selected,
            ancestors: ancestors,
            for: source.type
        )
    }

    /// 「已包含在…中」的说明;这一行没被上级覆盖时为 nil。
    private func inclusionCaption(for state: SourceDirectorySelectionPolicy.SelectionState) -> String? {
        guard case .included(let ancestor) = state else { return nil }
        if SourceDirectorySelectionPolicy.isRootPath(ancestor) {
            return String(localized: "folder_pick_included_whole_source")
        }
        guard let title = folderTitle(for: ancestor) else {
            return String(localized: "folder_pick_included_generic")
        }
        return String(format: String(localized: "folder_pick_included_in_format"), title)
    }

    /// 浏览经过的某一级目录的名字:parentPaths[0] 是根,第 i 级(含当前目录)
    /// 对应 breadcrumbNames[i - 1]。按 ID 寻址的源不把 ID 当名字露出来。
    private func folderTitle(for ancestor: String) -> String? {
        let chain = parentPaths + [path]
        if let index = chain.lastIndex(where: { SourceDirectorySelectionPolicy.isSamePath($0, ancestor) }),
           index > 0, index <= breadcrumbNames.count {
            return breadcrumbNames[index - 1]
        }
        return SourceDirectoryLabelPolicy.readableFallback(path: ancestor, sourceType: source.type)
    }

    private func toggle(_ p: String) {
        // 勾了上级就把它下面单独勾过的目录收起来(扫描本来就会整棵走下去),
        // 与手机、Mac 的选择页一致;被上级覆盖的行勾选框是禁用的。
        selected = SourceDirectorySelectionPolicy.normalizedSelections(
            SourceDirectorySelectionPolicy.toggledSelection(selected, path: p),
            for: source.type
        )
    }

    private func startScan() {
        guard let lister else {
            browseError = PMString("ext.tv.scan.connectFailed")
            return
        }
        let dirs = scanSelection
        // 没勾任何目录时按钮是禁用的;这里再挡一次,不再悄悄把当前目录当成扫描范围。
        guard !dirs.isEmpty else { return }
        let currentSource = store.source(id: source.id) ?? source
        loadTask?.cancel()
        started = true
        Task {
            let admitted = await store.runScan(source: currentSource, lister: lister, dirs: dirs,
                                              rereadMetadata: rereadMetadata, mode: mode)
            guard !admitted, !Task.isCancelled else { return }
            browseError = PMString("ext.tv.scan.busy")
            started = false
        }
    }

    private func startFnMusicScan() {
        loadTask?.cancel()
        started = true
        Task {
            let admitted = await store.runServerCatalogScan(source: source, rereadMetadata: rereadMetadata)
            guard !admitted, !Task.isCancelled else { return }
            browseError = PMString("ext.tv.scan.busy")
            started = false
        }
    }

}

// MARK: - 扫描进行中(第 4 步)

private struct TVScanningView: View {
    @Environment(TVStore.self) private var store
    let source: MusicSource
    var onDone: () -> Void = {}
    var onRetry: () -> Void = {}
    var onCancel: () -> Void = {}
    var onEnterOTP: () -> Void = {}
    var canCancel = true

    private var phase: TVSourceScanner.Phase { store.scanner.phase }
    private var presentationState: TVScanProgressPresentationState {
        TVScanProgressPresentationPolicy.state(for: phase)
    }
    private var done: Bool { presentationState == .complete }
    private var failed: Bool { presentationState == .failed }

    var body: some View {
        VStack(spacing: 0) {
            ring.padding(.bottom, 40)
            Text(title)
                .tvFont(size: 40, weight: .bold, relativeTo: .title2).foregroundStyle(TVColor.text).padding(.bottom, 10)
            Text(currentLine).tvFont(.caption, design: .monospaced).foregroundStyle(TVColor.textFaint)
                .lineLimit(done ? 3 : 1).truncationMode(.middle).multilineTextAlignment(.center)
                .frame(maxWidth: 900).padding(.bottom, 36)

            HStack(spacing: 56) {
                stat("\(store.scanner.indexed)", PMString("ext.tv.scan.indexed"))
                stat(statusText, PMString("ext.tv.scan.status"))
            }
            .padding(.bottom, 40)

            TVFocusButton(
                radius: 14,
                accent: TVColor.brand,
                scale: 1.05,
                lift: 5,
                action: failed ? onRetry : onDone
            ) { f in
                Text(primaryActionTitle)
                    .tvFont(.caption, weight: .bold).foregroundStyle(TVColor.onBrand)
                    .padding(.horizontal, 44).padding(.vertical, 18)
                    .background(TVColor.brand.opacity(f ? 1 : 0.88), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            // 卡在两步验证时直接给入口,不然只丢一句失败文案让人无从下手。
            if failed, store.scanner.needsTwoFactor {
                TVFocusButton(radius: 14, scale: 1.03, lift: 0, action: onEnterOTP) { focused in
                    Label(PMString("ext.tv.sources.login2FA"), systemImage: "lock.shield")
                        .tvFont(.caption, weight: .semibold).foregroundStyle(TVColor.text)
                        .padding(.horizontal, 38).padding(.vertical, 14)
                        .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.top, 14)
            }
            if !done && !failed && canCancel {
                TVFocusButton(radius: 14, scale: 1.03, lift: 0, action: onCancel) { focused in
                    Text(PMString("ext.tv.scan.cancelScan"))
                        .tvFont(.caption, weight: .medium).foregroundStyle(TVColor.text)
                        .padding(.horizontal, 38).padding(.vertical, 14)
                        .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.top, 14)
            }
            if case .failed(let msg) = phase {
                Text(msg).tvFont(.caption).foregroundStyle(TVColor.bad).padding(.top, 24)
            } else {
                Text(PMString("ext.tv.scan.syncHint"))
                    .tvFont(.meta).foregroundStyle(TVColor.textGhost).padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(TVColor.divider, lineWidth: 14).frame(width: 232, height: 232)
            if done {
                Circle().trim(from: 0, to: 1).stroke(TVColor.ok, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .frame(width: 232, height: 232).rotationEffect(.degrees(-90))
                Image(systemName: "checkmark").font(.system(size: 72, weight: .bold)).foregroundStyle(TVColor.ok)
            } else if failed {
                Circle().stroke(TVColor.bad, lineWidth: 14).frame(width: 232, height: 232)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(TVColor.bad)
            } else {
                SpinnerArc().frame(width: 232, height: 232)
                VStack(spacing: 4) {
                    Text("\(store.scanner.indexed)").tvFont(size: 56, weight: .bold, design: .monospaced, relativeTo: .title).foregroundStyle(TVColor.text)
                    Text(PMString("ext.tv.scan.indexed")).tvFont(.meta).foregroundStyle(TVColor.textFaint)
                }
            }
        }
    }

    private var currentLine: String {
        if case .failed = phase { return PMString("ext.tv.scan.interrupted") }
        if done, store.scanner.metadataIssueCount > 0 {
            return PMString("tv_metadata_reread_issues", store.scanner.metadataIssueCount)
        }
        return done
            ? PMString("ext.tv.scan.totalIndexed", store.scanner.indexed)
            : (store.scanner.currentFile.isEmpty ? PMString("ext.tv.scan.walking") : store.scanner.currentFile)
    }

    private var title: String {
        switch presentationState {
        case .complete:
            return PMString("ext.tv.scan.completedSource", source.name)
        case .failed:
            return PMString("ext.tv.scan.failedSource", source.name)
        case .scanning:
            return PMString("ext.tv.scan.scanningSource", source.name)
        }
    }

    private var statusText: String {
        switch presentationState {
        case .complete: return PMString("ext.tv.scan.complete")
        case .failed: return PMString("ext.tv.scan.failed")
        case .scanning: return PMString("ext.tv.scan.inProgress")
        }
    }

    private var primaryActionTitle: String {
        switch presentationState {
        case .complete: return PMString("ext.tv.scan.listen")
        case .failed: return PMString("ext.tv.scan.retry")
        case .scanning: return PMString("ext.tv.scan.continueBackground")
        }
    }

    private func stat(_ v: String, _ k: String) -> some View {
        VStack(spacing: 4) {
            Text(v).tvFont(.sectionTitle, design: .monospaced).foregroundStyle(TVColor.brand)
            Text(k).tvFont(.meta).foregroundStyle(TVColor.textFaint)
        }
    }
}

/// 不定量旋转弧(扫描中没有总数预估)。
private struct SpinnerArc: View {
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().trim(from: 0, to: 0.28)
            .stroke(TVColor.brand, style: StrokeStyle(lineWidth: 14, lineCap: .round))
            .rotationEffect(.degrees(spin && !reduceMotion ? 360 : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false),
                value: spin
            )
            .onAppear { spin = !reduceMotion }
    }
}
#endif
