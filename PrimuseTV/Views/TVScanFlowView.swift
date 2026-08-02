#if os(tvOS)
import PrimuseKit
import SwiftUI

/// 添加新源后(或长按源菜单)的扫描流程。目录型源选择目录，道理鱼直接扫描服务端曲库。
struct TVScanFlowView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: MusicSource

    @State private var lister: TVDirectoryLister?
    @State private var path = "/"
    @State private var entries: [TVDirEntry] = []
    @State private var selected: Set<String> = []
    @State private var loading = false
    @State private var started = false
    @State private var browseError: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: Color(hex: "#1f3a5b"), strength: started ? 0.5 : 0.4)
            TVColor.bg.opacity(0.48).ignoresSafeArea()
            if started {
                TVScanningView(
                    source: source,
                    onDone: { dismiss() },
                    onCancel: {
                        scanTask?.cancel()
                        dismiss()
                    }
                )
            } else if source.type == .daoliyu {
                daoLiYuPickView
            } else {
                pickView
            }
        }
        .onDisappear { loadTask?.cancel() }
        .onAppear {
            if lister == nil {
                lister = store.makeLister(for: source)
                if source.type != .daoliyu {
                    selected = Set(source.scannedDirectories)   // 回填上次扫描勾选的目录
                    load("/")
                }
            }
        }
    }

    private var daoLiYuPickView: some View {
        VStack(spacing: 28) {
            Image(systemName: source.type.iconName)
                .font(.system(size: 66, weight: .semibold))
                .foregroundStyle(TVColor.onBrand)
                .frame(width: 132, height: 132)
                .background(TVColor.brand, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            VStack(spacing: 10) {
                TVEyebrow(text: "\(source.type.displayName) · 完整曲库")
                Text("扫描服务端音乐曲库")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(TVColor.text)
                Text("将通过道理鱼原生 API 导入曲目，无需选择 NAS 文件夹。")
                    .font(.system(size: 20))
                    .foregroundStyle(TVColor.textFaint)
            }
            TVFocusButton(radius: 16, accent: TVColor.brand, scale: 1.05, lift: 4, action: startDaoLiYuScan) { focused in
                Label(PMString("ext.tv.scan.start"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(TVColor.onBrand)
                    .padding(.horizontal, 46)
                    .padding(.vertical, 20)
                    .background(TVColor.brand.opacity(focused ? 1 : 0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            TVFocusButton(radius: 16, scale: 1.04, lift: 0, action: { dismiss() }) { focused in
                Text(PMString("ext.tv.sources.cancel"))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(TVColor.text)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 14)
                    .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 选目录(第 3 步)

    private var pickView: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(text: PMString("ext.tv.scan.step3")).padding(.bottom, 6)
                Text(PMString("ext.tv.scan.chooseFolders")).font(.system(size: 40, weight: .bold)).foregroundStyle(TVColor.text).padding(.bottom, 6)
                Text(breadcrumb).font(.system(size: 18, design: .monospaced)).foregroundStyle(TVColor.textFaint).padding(.bottom, 22)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        if path != "/" {
                            folderRow(name: PMString("ext.tv.scan.up"), isUp: true, selectable: false, checked: false) {
                                load(Self.parent(of: path))
                            }
                        }
                        if loading {
                            HStack { ProgressView().tint(TVColor.brand); Text(PMString("ext.tv.scan.loading")).foregroundStyle(TVColor.textFaint) }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                        } else if let browseError {
                            Text(browseError)
                                .font(.system(size: 17)).foregroundStyle(TVColor.bad).padding(.vertical, 16)
                        } else if entries.filter(\.isDir).isEmpty {
                            Text(PMString("ext.tv.scan.noSubfolders"))
                                .font(.system(size: 17)).foregroundStyle(TVColor.textGhost).padding(.vertical, 16)
                        }
                        ForEach(entries.filter(\.isDir)) { e in
                            folderRow(name: e.name, isUp: false, selectable: true, checked: selected.contains(e.path),
                                      onSelect: { toggle(e.path) }, onOpen: { load(e.path) })
                        }
                    }
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

    private func folderRow(name: String, isUp: Bool, selectable: Bool, checked: Bool,
                           onSelect: @escaping () -> Void = {}, onOpen: @escaping () -> Void = {}) -> some View {
        // 全宽行不缩放/不上抬:缩放会溢出 ScrollView 横向裁切导致描边被裁(同 TVSourceRow)。
        TVFocusButton(radius: 12, scale: 1.0, lift: 0, action: selectable ? onSelect : onOpen) { focused in
            HStack(spacing: 16) {
                if selectable {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(checked ? .clear : TVColor.cardBorder, lineWidth: 2)
                            .background(checked ? TVColor.brand : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .frame(width: 28, height: 28)
                        if checked { Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(TVColor.onBrand) }
                    }
                }
                Image(systemName: isUp ? "arrow.up.left" : "folder.fill")
                    .font(.system(size: 22)).foregroundStyle(checked ? TVColor.brand : TVColor.textFaint).frame(width: 26)
                Text(name).font(.system(size: 22, weight: checked ? .semibold : .regular)).foregroundStyle(TVColor.text).lineLimit(1)
                Spacer(minLength: 0)
                if selectable {
                    Text(PMString("ext.tv.scan.open")).font(.system(size: 15)).foregroundStyle(focused ? TVColor.text : TVColor.textGhost)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
        }
        .contextMenu {
            if selectable {
                Button { onOpen() } label: { Label(PMString("ext.tv.scan.openFolder"), systemImage: "folder") }
                Button { onSelect() } label: { Label(checked ? PMString("ext.tv.scan.uncheck") : PMString("ext.tv.scan.check"), systemImage: checked ? "square" : "checkmark.square") }
            }
        }
    }

    private var summaryPanel: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(text: PMString("ext.tv.scan.summary")).padding(.bottom, 14)
                summaryRow(PMString("ext.tv.scan.selected"), selected.isEmpty ? PMString("ext.tv.scan.currentFolder") : PMString("ext.tv.scan.folderCount", selected.count))
                summaryRow(PMString("ext.tv.scan.metadata"), PMString("ext.tv.scan.metadataValue"))
                summaryRow(PMString("ext.tv.scan.playable"), PMString("ext.tv.scan.formats"))
            }
            .padding(26).frame(maxWidth: .infinity)
            .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(TVColor.cardBorder, lineWidth: 0.5) }

            TVFocusButton(radius: 16, accent: TVColor.brand, scale: 1.05, lift: 4, action: startScan) { f in
                Label(PMString("ext.tv.scan.start"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(TVColor.onBrand)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                    .background(TVColor.brand.opacity(f ? 1 : 0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            TVFocusButton(radius: 16, scale: 1.04, lift: 0, action: { dismiss() }) { f in
                Text(PMString("ext.tv.sources.cancel")).font(.system(size: 20, weight: .medium)).foregroundStyle(TVColor.text)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(f ? TVColor.surfaceStrong : TVColor.surfaceSubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func summaryRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 18)).foregroundStyle(TVColor.textFaint)
            Spacer()
            Text(v).font(.system(size: 18, weight: .semibold)).foregroundStyle(TVColor.text)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(TVColor.divider).frame(height: 0.5) }
    }

    // MARK: 行为

    private var breadcrumb: String { "\(source.name) · \(path)" }

    private func load(_ p: String) {
        guard let lister else { return }
        loadTask?.cancel()
        path = p
        loading = true
        browseError = nil
        loadTask = Task {
            do {
                let loaded = try await store.scanner.browse(lister: lister, path: p)
                guard !Task.isCancelled, path == p else { return }
                entries = loaded
            } catch is CancellationError {
                return
            } catch {
                guard path == p else { return }
                entries = []
                browseError = PMString("ext.tv.scan.browseFailed", error.localizedDescription)
            }
            if path == p { loading = false }
        }
    }

    private func toggle(_ p: String) {
        if selected.contains(p) { selected.remove(p) } else { selected.insert(p) }
    }

    private func startScan() {
        guard let lister else { return }
        let dirs = selected.isEmpty ? [path] : Array(selected)
        loadTask?.cancel()
        started = true
        scanTask = Task { await store.runScan(source: source, lister: lister, dirs: dirs) }
    }

    private func startDaoLiYuScan() {
        loadTask?.cancel()
        started = true
        scanTask = Task { await store.runDaoLiYuScan(source: source) }
    }

    private static func parent(of path: String) -> String {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).dropLast()
        return comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
    }
}

// MARK: - 扫描进行中(第 4 步)

private struct TVScanningView: View {
    @Environment(TVStore.self) private var store
    let source: MusicSource
    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}

    private var phase: TVSourceScanner.Phase { store.scanner.phase }
    private var done: Bool { phase == .done }

    var body: some View {
        VStack(spacing: 0) {
            ring.padding(.bottom, 40)
            Text(done ? PMString("ext.tv.scan.completedSource", source.name) : PMString("ext.tv.scan.scanningSource", source.name))
                .font(.system(size: 40, weight: .bold)).foregroundStyle(TVColor.text).padding(.bottom, 10)
            Text(currentLine).font(.system(size: 18, design: .monospaced)).foregroundStyle(TVColor.textFaint)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 900).padding(.bottom, 36)

            HStack(spacing: 56) {
                stat("\(store.scanner.indexed)", PMString("ext.tv.scan.indexed"))
                stat(done ? PMString("ext.tv.scan.complete") : PMString("ext.tv.scan.inProgress"), PMString("ext.tv.scan.status"))
            }
            .padding(.bottom, 40)

            TVFocusButton(radius: 14, accent: TVColor.brand, scale: 1.05, lift: 5, action: onDone) { f in
                Text(done ? PMString("ext.tv.scan.listen") : PMString("ext.tv.scan.continueBackground"))
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(TVColor.onBrand)
                    .padding(.horizontal, 44).padding(.vertical, 18)
                    .background(TVColor.brand.opacity(f ? 1 : 0.88), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !done {
                TVFocusButton(radius: 14, scale: 1.03, lift: 0, action: onCancel) { focused in
                    Text(PMString("ext.tv.scan.cancelScan"))
                        .font(.system(size: 19, weight: .medium)).foregroundStyle(TVColor.text)
                        .padding(.horizontal, 38).padding(.vertical, 14)
                        .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.top, 14)
            }
            if case .failed(let msg) = phase {
                Text(msg).font(.system(size: 17)).foregroundStyle(TVColor.bad).padding(.top, 24)
            } else {
                Text(PMString("ext.tv.scan.syncHint"))
                    .font(.system(size: 15)).foregroundStyle(TVColor.textGhost).padding(.top, 24)
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
            } else {
                SpinnerArc().frame(width: 232, height: 232)
                VStack(spacing: 4) {
                    Text("\(store.scanner.indexed)").font(.system(size: 56, weight: .bold, design: .monospaced)).foregroundStyle(TVColor.text)
                    Text(PMString("ext.tv.scan.indexed")).font(.system(size: 16)).foregroundStyle(TVColor.textFaint)
                }
            }
        }
    }

    private var currentLine: String {
        if case .failed = phase { return PMString("ext.tv.scan.interrupted") }
        return done
            ? PMString("ext.tv.scan.totalIndexed", store.scanner.indexed)
            : (store.scanner.currentFile.isEmpty ? PMString("ext.tv.scan.walking") : store.scanner.currentFile)
    }

    private func stat(_ v: String, _ k: String) -> some View {
        VStack(spacing: 4) {
            Text(v).font(.system(size: 32, weight: .bold, design: .monospaced)).foregroundStyle(TVColor.brand)
            Text(k).font(.system(size: 15)).foregroundStyle(TVColor.textFaint)
        }
    }
}

/// 不定量旋转弧(扫描中没有总数预估)。
private struct SpinnerArc: View {
    @State private var spin = false
    var body: some View {
        Circle().trim(from: 0, to: 0.28)
            .stroke(TVColor.brand, style: StrokeStyle(lineWidth: 14, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}
#endif
