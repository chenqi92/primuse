#if os(tvOS)
import SwiftUI

/// tvOS 设置 — 左列常用清单,右列 Siri Remote 图示(对应 TVSettingsArtboard)。
/// 刻意精简:无 EQ 推子 / 刮削源 / SSL 信任,这些留在 macOS / iOS。
struct TVSettingsView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onNavigate: (TVRoot.Tab) -> Void = { _ in }
    @AppStorage("tvAutoSync") private var autoSync = true
    @State private var isSyncing = false
    @State private var syncMsg: String?

    private var version: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0" }
    private var build: String { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1" }
    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
    private var libraryStat: String {
        store.albums.isEmpty ? TVL("尚未同步", "Not synced yet") :
            TVL("\(TVFmt.count(store.songs.count)) 首 · \(store.albums.count) 张专辑 · \(store.artists.count) 位艺术家", "\(TVFmt.count(store.songs.count)) songs · \(store.albums.count) albums · \(store.artists.count) artists")
    }
    private var syncValue: String {
        if isSyncing { return TVL("正在从 iCloud 同步…", "Syncing from iCloud…") }
        return syncMsg ?? TVL("点按拉取最新曲库", "Tap to pull latest library")
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            HStack(alignment: .top, spacing: 80) {
                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: TVL("设置", "Settings")).padding(.bottom, 6)
                    Text(TVL("常用", "General")).font(TVFont.pageTitle).foregroundStyle(.white).padding(.bottom, 24)
                    VStack(spacing: 12) {
                        navRow("icloud.fill", TVL("iCloud 同步", "iCloud Sync"), syncValue, trailing: "arrow.clockwise", action: sync)
                        toggleRow("arrow.triangle.2.circlepath", TVL("启动时自动同步", "Auto sync on launch"), isOn: $autoSync)
                        navRow("music.note", TVL("曲库", "Library"), libraryStat) { go(.library) }
                        navRow("music.note.list", TVL("歌单", "Playlists"), TVL("\(store.playlists.count) 个", "\(store.playlists.count)")) { go(.playlists) }
                        navRow("server.rack", TVL("音乐源", "Sources"), TVL("\(store.sources.count) 个", "\(store.sources.count)")) { go(.sources) }
                        infoRow("info.circle", TVL("关于 Primuse", "About Primuse"), "\(version) (\(build)) · tvOS \(osVersion)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: TVL("遥控提示", "Remote Tips")).padding(.bottom, 24)
                    HStack { Spacer(); TVSiriRemote(); Spacer() }
                    VStack(alignment: .leading, spacing: 14) {
                        TVRemoteHint(TVL("圆形触控板", "Touch surface"), TVL("上 / 下 / 左 / 右移动焦点 · 按下选择", "Swipe up / down / left / right · press to select"))
                        TVRemoteHint(TVL("Menu / 返回", "Menu / Back"), TVL("返回上一层", "Go back one level"))
                        TVRemoteHint(TVL("TV 按钮", "TV button"), TVL("回 Apple TV 主屏", "Return to Apple TV Home"))
                        TVRemoteHint(TVL("搜索框", "Search field"), TVL("唤出系统键盘 · 支持语音听写", "Brings up the keyboard · voice dictation supported"))
                    }
                    .padding(.top, 32)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tvPage()
        }
        .onExitCommand { dismiss() }
    }

    private func sync() {
        guard !isSyncing else { return }
        isSyncing = true
        syncMsg = nil
        Task {
            await store.bootstrap()
            isSyncing = false
            syncMsg = store.albums.isEmpty ? TVL("未找到曲库快照", "No library snapshot found") : TVL("已同步 · \(TVFmt.count(store.songs.count)) 首", "Synced · \(TVFmt.count(store.songs.count)) songs")
        }
    }

    private func go(_ tab: TVRoot.Tab) {
        onNavigate(tab)
        dismiss()
    }

    private func settingIcon(_ icon: String, focused: Bool) -> some View {
        Image(systemName: icon).font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(Color.white.opacity(0.10)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 可点击行(同步 / 跳转);trailing 默认箭头表示可进入。
    private func navRow(_ icon: String, _ title: String, _ value: String,
                        trailing: String = "chevron.right",
                        action: @escaping () -> Void) -> some View {
        TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: action) { focused in
            HStack(spacing: 18) {
                settingIcon(icon, focused: focused)
                Text(title).font(.system(size: 22, weight: focused ? .bold : .medium)).foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(value).font(.system(size: 18)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                Image(systemName: trailing).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(focused ? 0.85 : 0.45))
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? Color.white.opacity(0.12) : TVColor.card)
        }
    }

    /// 开关行 — 真实持久化偏好(@AppStorage),启动时被读取。
    private func toggleRow(_ icon: String, _ title: String, isOn: Binding<Bool>) -> some View {
        TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: { isOn.wrappedValue.toggle() }) { focused in
            HStack(spacing: 18) {
                settingIcon(icon, focused: focused)
                Text(title).font(.system(size: 22, weight: focused ? .bold : .medium)).foregroundStyle(.white)
                Spacer(minLength: 0)
                ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                    Capsule().fill(isOn.wrappedValue ? AnyShapeStyle(TVColor.brand)
                                                     : AnyShapeStyle(Color.white.opacity(0.18)))
                        .frame(width: 62, height: 34)
                    Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                }
                .animation(.easeOut(duration: 0.18), value: isOn.wrappedValue)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? Color.white.opacity(0.12) : TVColor.card)
        }
    }

    /// 只读信息行(不可聚焦)。
    private func infoRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 18) {
            settingIcon(icon, focused: false)
            Text(title).font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 18)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(TVColor.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct TVRemoteHint: View {
    let binding: String
    let label: String
    init(_ binding: String, _ label: String) { self.binding = binding; self.label = label }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(binding).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(minWidth: 180).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                }
            Text(label).font(.system(size: 18)).foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// 风格化 Siri Remote。
private struct TVSiriRemote: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.08), .clear],
                                         center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 90))
                    .overlay { Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
                    .frame(width: 150, height: 150)
                ForEach([0.0, 90.0, 180.0, 270.0], id: \.self) { deg in
                    Image(systemName: "chevron.up").font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.45))
                        .offset(y: -56)
                        .rotationEffect(.degrees(deg))
                }
                Circle().fill(.white.opacity(0.18))
                    .overlay { Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5) }
                    .frame(width: 24, height: 24)
            }
            .padding(.top, 10)

            let grid = [("arrow.uturn.backward", "Back"), ("tv", "TV"),
                        ("speaker.slash.fill", "Mute"), ("mic.fill", "Siri")]
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(grid, id: \.0) { b in
                    VStack(spacing: 3) {
                        Image(systemName: b.0).font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                        Text(b.1).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                }
            }

            HStack(spacing: 14) {
                Image(systemName: "backward.fill")
                Image(systemName: "playpause.fill")
                Image(systemName: "forward.fill")
            }
            .font(.system(size: 16)).foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }

            Text("SIRI REMOTE").font(.system(size: 11, weight: .medium)).tracking(1.6)
                .foregroundStyle(.white.opacity(0.4)).padding(.top, 4)
        }
        .padding(24)
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#2a2722"), Color(hex: "#16140f")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.6), radius: 30, y: 14)
    }
}
#endif
