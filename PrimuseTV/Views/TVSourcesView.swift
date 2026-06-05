#if os(tvOS)
import SwiftUI

/// tvOS 音乐源 — 列出经 iCloud 同步过来的音乐源(只读)。
/// tvOS 不跑原生连接器,音乐源在 iPhone / Mac 上添加后同步到此。
struct TVSourcesView: View {
    @Environment(TVStore.self) private var store
    @State private var pendingDelete: TVSource?

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            HStack(alignment: .top, spacing: 60) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        TVEyebrow(text: "音乐源")
                        Text("音乐源 · \(store.sources.count) 个")
                            .font(TVFont.pageTitle).foregroundStyle(.white)
                            .padding(.bottom, 22)
                        if store.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "server.rack").font(.system(size: 54))
                                    .foregroundStyle(.white.opacity(0.35))
                                Text("还没有音乐源").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                                Text("扫右侧二维码在手机上添加,或在 iPhone / Mac 上添加后经 iCloud 同步过来。")
                                    .font(.system(size: 18)).foregroundStyle(.white.opacity(0.6))
                                    .frame(maxWidth: 560, alignment: .leading).lineSpacing(4)
                            }
                            .padding(.top, 24)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(store.sources) { s in
                                    TVSourceRow(source: s, onSelect: { pendingDelete = s })
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: "添加音乐源").padding(.bottom, 16)
                    TVSourcesInfoCard()
                }
                .frame(width: 520)
            }
            .tvPage()
        }
        .alert("删除音乐源?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { source in
            Button("删除", role: .destructive) { store.deleteSource(source.id); pendingDelete = nil }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { source in
            Text("「\(source.name)」将从 Apple TV 移除。它在 iPhone / Mac 上仍是权威方,彻底删除请在手机/电脑上操作。")
        }
    }
}

/// 扫码添加:Apple TV 展示二维码,iPhone 相机扫码打开 app 的「添加音乐源」,经 iCloud 同步回来。
private struct TVSourcesInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "qrcode").font(.system(size: 28)).foregroundStyle(TVColor.brand)
                Text("扫码在手机上添加").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            }
            HStack(alignment: .top, spacing: 22) {
                TVQRCode(content: "primuse://add-source", size: 190)
                VStack(alignment: .leading, spacing: 12) {
                    Text("用 iPhone 相机扫这个码,会打开 Primuse 到「添加音乐源」,可挨个添加 NAS / 云盘 / Subsonic 等。")
                        .font(.system(size: 18)).foregroundStyle(.white.opacity(0.72)).lineSpacing(5)
                    Text("添加后经 iCloud 自动同步到 Apple TV;也可直接在 iPhone / Mac 上添加。")
                        .font(.system(size: 15)).foregroundStyle(TVColor.textGhost).lineSpacing(4)
                }
            }
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct TVSourceRow: View {
    let source: TVSource
    var onSelect: () -> Void = {}

    var body: some View {
        // 不缩放:全宽行缩放会溢出 ScrollView 横向裁切,导致描边左右被裁(只剩上下)。
        TVFocusButton(radius: TVRadius.card, scale: 1.0, lift: 0, action: onSelect) { focused in
            HStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [source.color, .black.opacity(0.4)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                    .overlay {
                        Text(source.type.prefix(1).uppercased())
                            .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(1)
                    Text("\(source.type.uppercased()) · \(TVFmt.count(source.songs)) 首")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(TVColor.textFaint)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: statusIcon).font(.system(size: 15))
                    Text(statusLabel).font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(statusColor)
                if focused {
                    Image(systemName: "trash").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TVColor.bad).padding(.leading, 10)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(focused ? Color.white.opacity(0.12) : TVColor.card)
        }
    }

    private var statusIcon: String {
        switch source.status {
        case .connected: return "circle.fill"
        case .scanning: return "arrow.triangle.2.circlepath"
        case .authFailed: return "exclamationmark.triangle.fill"
        case .disabled: return "circle"
        }
    }
    private var statusLabel: String {
        switch source.status {
        case .connected: return "已启用"
        case .scanning: return "扫描中"
        case .authFailed: return "凭据失败"
        case .disabled: return "已停用"
        }
    }
    private var statusColor: Color {
        switch source.status {
        case .connected: return TVColor.ok
        case .scanning: return source.color
        case .authFailed: return TVColor.bad
        case .disabled: return TVColor.textGhost
        }
    }
}

#endif
