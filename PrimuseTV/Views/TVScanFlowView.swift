#if os(tvOS)
import PrimuseKit
import SwiftUI

/// 添加新源后(或长按源菜单)的「选目录 + 扫描」全屏流程,对照设计 TVPickFolderArtboard /
/// TVScanningArtboard。目前支持 SMB:浏览共享内的文件夹、勾选要扫的目录、路径快扫建库。
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

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: Color(hex: "#1f3a5b"), strength: started ? 0.5 : 0.4)
            Color.black.opacity(0.5).ignoresSafeArea()
            if started {
                TVScanningView(source: source, onDone: { dismiss() })
            } else {
                pickView
            }
        }
        .onAppear {
            if lister == nil {
                lister = store.makeLister(for: source)
                selected = Set(source.scannedDirectories)   // 回填上次扫描勾选的目录
                load("/")
            }
        }
    }

    // MARK: 选目录(第 3 步)

    private var pickView: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(text: "添加新源 · 第 3 步").padding(.bottom, 6)
                Text("选择要扫描的目录").font(.system(size: 40, weight: .bold)).foregroundStyle(.white).padding(.bottom, 6)
                Text(breadcrumb).font(.system(size: 18, design: .monospaced)).foregroundStyle(TVColor.textFaint).padding(.bottom, 22)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        if path != "/" {
                            folderRow(name: "返回上一级", isUp: true, selectable: false, checked: false) {
                                load(Self.parent(of: path))
                            }
                        }
                        if loading {
                            HStack { ProgressView().tint(.white); Text("加载中…").foregroundStyle(TVColor.textFaint) }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                        } else if entries.filter(\.isDir).isEmpty {
                            Text("该目录下没有子文件夹。可勾选当前目录直接扫描。")
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
                            .strokeBorder(checked ? .clear : .white.opacity(0.3), lineWidth: 2)
                            .background(checked ? TVColor.brand : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .frame(width: 28, height: 28)
                        if checked { Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white) }
                    }
                }
                Image(systemName: isUp ? "arrow.up.left" : "folder.fill")
                    .font(.system(size: 22)).foregroundStyle(checked ? .white : .white.opacity(0.55)).frame(width: 26)
                Text(name).font(.system(size: 22, weight: checked ? .semibold : .regular)).foregroundStyle(checked ? .white : .white.opacity(0.85)).lineLimit(1)
                Spacer(minLength: 0)
                if selectable {
                    Text("打开 ▸").font(.system(size: 15)).foregroundStyle(focused ? .white : TVColor.textGhost)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity)
            .background(focused ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
        }
        .contextMenu {
            if selectable {
                Button { onOpen() } label: { Label("打开此文件夹", systemImage: "folder") }
                Button { onSelect() } label: { Label(checked ? "取消勾选" : "勾选扫描", systemImage: checked ? "square" : "checkmark.square") }
            }
        }
    }

    private var summaryPanel: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(text: "即将扫描").padding(.bottom, 14)
                summaryRow("已选目录", selected.isEmpty ? "当前目录" : "\(selected.count) 个")
                summaryRow("元数据", "路径快扫 · 标签靠同步补")
                summaryRow("可播放", "FLAC · MP3 · AAC · DSD…")
            }
            .padding(26).frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }

            TVFocusButton(radius: 16, accent: TVColor.brand, scale: 1.05, lift: 4, action: startScan) { f in
                Label("开始扫描", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(Color(hex: "#1f1c19"))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                    .background(Color.white.opacity(f ? 1 : 0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            TVFocusButton(radius: 16, scale: 1.04, lift: 0, action: { dismiss() }) { f in
                Text("取消").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.white.opacity(f ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func summaryRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 18)).foregroundStyle(TVColor.textFaint)
            Spacer()
            Text(v).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
    }

    // MARK: 行为

    private var breadcrumb: String { "\(source.name) · \(path)" }

    private func load(_ p: String) {
        guard let lister else { return }
        path = p; loading = true
        Task {
            entries = await store.scanner.browse(lister: lister, path: p)
            loading = false
        }
    }

    private func toggle(_ p: String) {
        if selected.contains(p) { selected.remove(p) } else { selected.insert(p) }
    }

    private func startScan() {
        guard let lister else { return }
        let dirs = selected.isEmpty ? [path] : Array(selected)
        started = true
        Task { await store.runScan(source: source, lister: lister, dirs: dirs) }
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

    private var phase: TVSourceScanner.Phase { store.scanner.phase }
    private var done: Bool { phase == .done }

    var body: some View {
        VStack(spacing: 0) {
            ring.padding(.bottom, 40)
            Text(done ? "扫描完成 · \(source.name)" : "正在扫描 \(source.name)")
                .font(.system(size: 40, weight: .bold)).foregroundStyle(.white).padding(.bottom, 10)
            Text(currentLine).font(.system(size: 18, design: .monospaced)).foregroundStyle(TVColor.textFaint)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 900).padding(.bottom, 36)

            HStack(spacing: 56) {
                stat("\(store.scanner.indexed)", "已索引")
                stat(done ? "完成" : "进行中", "状态")
            }
            .padding(.bottom, 40)

            TVFocusButton(radius: 14, accent: TVColor.brand, scale: 1.05, lift: 5, action: onDone) { f in
                Text(done ? "开始听歌 →" : "后台继续")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(Color(hex: "#1f1c19"))
                    .padding(.horizontal, 44).padding(.vertical, 18)
                    .background(Color.white.opacity(f ? 1 : 0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if case .failed(let msg) = phase {
                Text(msg).font(.system(size: 17)).foregroundStyle(TVColor.bad).padding(.top, 24)
            } else {
                Text("路径快扫:从文件夹结构建库 · 真实标签/封面/歌词随手机同步补全")
                    .font(.system(size: 15)).foregroundStyle(TVColor.textGhost).padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 14).frame(width: 232, height: 232)
            if done {
                Circle().trim(from: 0, to: 1).stroke(TVColor.ok, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .frame(width: 232, height: 232).rotationEffect(.degrees(-90))
                Image(systemName: "checkmark").font(.system(size: 72, weight: .bold)).foregroundStyle(TVColor.ok)
            } else {
                SpinnerArc().frame(width: 232, height: 232)
                VStack(spacing: 4) {
                    Text("\(store.scanner.indexed)").font(.system(size: 56, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    Text("已索引").font(.system(size: 16)).foregroundStyle(TVColor.textFaint)
                }
            }
        }
    }

    private var currentLine: String {
        if case .failed = phase { return "扫描中断" }
        return done ? "共索引 \(store.scanner.indexed) 首" : (store.scanner.currentFile.isEmpty ? "正在遍历目录…" : store.scanner.currentFile)
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
