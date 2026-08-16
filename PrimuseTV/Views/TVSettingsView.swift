#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 设置 — 左列常用清单,右列 Siri Remote 图示(对应 TVSettingsArtboard)。
/// 刻意精简:无 EQ 推子 / 刮削源 / SSL 信任,这些留在 macOS / iOS。
struct TVSettingsView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var onNavigate: (TVRoot.Tab) -> Void = { _ in }
    @AppStorage("tvAutoSync") private var autoSync = true
    @AppStorage(TVAppearancePreference.storageKey)
    private var appearanceRawValue = TVAppearancePreference.system.rawValue
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var immersiveEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    @State private var showsEffectPicker = false
    @State private var isSyncing = false
    @State private var syncMsg: String?

    private var immersiveEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: immersiveEffectRawValue) ?? .defaultValue
    }

    private var version: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0" }
    private var build: String { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1" }
    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
    private var libraryStat: String {
        !store.hasRealLibrary ? PMString("ext.tv.settings.notSynced") :
            PMString("ext.tv.settings.libraryStat", TVFmt.count(store.songs.count), store.albums.count, store.artists.count)
    }
    private var syncValue: String {
        if isSyncing { return PMString("ext.tv.settings.syncing") }
        return syncMsg ?? PMString("ext.tv.settings.tapToPull")
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 80) {
                    VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: PMString("ext.tv.settings.eyebrow")).padding(.bottom, 6)
                    Text(PMString("ext.tv.settings.general")).font(TVFont.pageTitle).foregroundStyle(TVColor.text).padding(.bottom, 24)
                    VStack(spacing: 12) {
                        navRow("icloud.fill", PMString("ext.tv.settings.icloudSync"), syncValue, trailing: "arrow.clockwise", action: sync)
                        toggleRow("arrow.triangle.2.circlepath", PMString("ext.tv.settings.autoSync"), isOn: $autoSync)
                        appearanceRow()
                        navRow("sparkles.tv", PMString("ext.tv.settings.immersive"),
                               immersiveEffect.localizedTitle,
                               action: { showsEffectPicker = true })
                        navRow("music.note", PMString("ext.tv.settings.library"), libraryStat) { go(.library) }
                        navRow("music.note.list", PMString("ext.tv.settings.playlists"), PMString("ext.tv.countOnly", store.playlists.count)) { go(.playlists) }
                        navRow("server.rack", PMString("ext.tv.settings.sources"), PMString("ext.tv.countOnly", store.sources.count)) { go(.sources) }
                        navRow("star.bubble", PMString("rate_on_app_store"), "App Store", trailing: "arrow.up.right") {
                            openURL(PrimuseAppStore.reviewURL)
                        }
                        infoRow("info.circle", PMString("ext.tv.settings.about"), "\(version) (\(build)) · tvOS \(osVersion)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: PMString("ext.tv.settings.remoteTips")).padding(.bottom, 24)
                    HStack { Spacer(); TVSiriRemote(); Spacer() }
                    VStack(alignment: .leading, spacing: 14) {
                        TVRemoteHint(PMString("ext.tv.settings.tip.touch.title"), PMString("ext.tv.settings.tip.touch.body"))
                        TVRemoteHint(PMString("ext.tv.settings.tip.menu.title"), PMString("ext.tv.settings.tip.menu.body"))
                        TVRemoteHint(PMString("ext.tv.settings.tip.tv.title"), PMString("ext.tv.settings.tip.tv.body"))
                        TVRemoteHint(PMString("ext.tv.settings.tip.search.title"), PMString("ext.tv.settings.tip.search.body"))
                    }
                    .padding(.top, 32)
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 24)
            .tvPage()

            if showsEffectPicker {
                TVFullscreenEffectPicker(
                    selectedRawValue: $immersiveEffectRawValue,
                    lyricsMotionEnabled: $lyricsMotionEnabled,
                    onDismiss: { showsEffectPicker = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: showsEffectPicker)
        .onExitCommand {
            if showsEffectPicker {
                showsEffectPicker = false
            } else {
                dismiss()
            }
        }
        .onAppear { FullscreenPlayerEffectSync.shared.install() }
    }

    private func sync() {
        guard !isSyncing else { return }
        isSyncing = true
        syncMsg = nil
        Task {
            await store.bootstrap()
            isSyncing = false
            syncMsg = !store.hasRealLibrary ? PMString("ext.tv.settings.noSnapshot") : PMString("ext.tv.settings.synced", TVFmt.count(store.songs.count))
        }
    }

    private func go(_ tab: TVRoot.Tab) {
        onNavigate(tab)
        dismiss()
    }

    private var appearance: TVAppearancePreference {
        TVAppearancePreference(rawValue: appearanceRawValue) ?? .system
    }

    private func appearanceTitle(_ preference: TVAppearancePreference) -> String {
        switch preference {
        case .system: PMString("ext.tv.settings.appearance.system")
        case .light: PMString("ext.tv.settings.appearance.light")
        case .dark: PMString("ext.tv.settings.appearance.dark")
        }
    }

    /// 三个选项都可独立聚焦，Siri Remote 无需循环点按即可直接选择外观。
    private func appearanceRow() -> some View {
        HStack(spacing: 18) {
            settingIcon("circle.lefthalf.filled", focused: false)
            Text(PMString("ext.tv.settings.appearance"))
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(TVColor.text)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ForEach(TVAppearancePreference.allCases, id: \.self) { preference in
                    let isSelected = appearance == preference
                    TVFocusButton(radius: 10, scale: 1.04, lift: 0) {
                        appearanceRawValue = preference.rawValue
                    } label: { focused in
                        Text(appearanceTitle(preference))
                            .font(.system(size: 16, weight: isSelected ? .bold : .semibold))
                            .foregroundStyle(isSelected ? TVColor.onBrand : TVColor.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: 94)
                            .padding(.vertical, 11)
                            .background(isSelected ? TVColor.brand : TVColor.cardElev,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(TVColor.brand.opacity(focused || isSelected ? 0.9 : 0), lineWidth: 2)
                            }
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(TVColor.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func settingIcon(_ icon: String, focused: Bool) -> some View {
        Image(systemName: icon).font(.system(size: 20, weight: .semibold))
            .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
            .frame(width: 40, height: 40)
            .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surface),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 可点击行(同步 / 跳转);trailing 默认箭头表示可进入。
    private func navRow(_ icon: String, _ title: String, _ value: String,
                        trailing: String = "chevron.right",
                        action: @escaping () -> Void) -> some View {
        TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: action) { focused in
            HStack(spacing: 18) {
                settingIcon(icon, focused: focused)
                Text(title).font(.system(size: 22, weight: focused ? .bold : .medium)).foregroundStyle(TVColor.text)
                Spacer(minLength: 0)
                Text(value).font(.system(size: 18)).foregroundStyle(TVColor.textMuted).lineLimit(1)
                Image(systemName: trailing).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(focused ? TVColor.text : TVColor.textGhost)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.card)
        }
    }

    /// 开关行 — 真实持久化偏好(@AppStorage),启动时被读取。
    private func toggleRow(_ icon: String, _ title: String, isOn: Binding<Bool>) -> some View {
        TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: { isOn.wrappedValue.toggle() }) { focused in
            HStack(spacing: 18) {
                settingIcon(icon, focused: focused)
                Text(title).font(.system(size: 22, weight: focused ? .bold : .medium)).foregroundStyle(TVColor.text)
                Spacer(minLength: 0)
                ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                    Capsule().fill(isOn.wrappedValue ? AnyShapeStyle(TVColor.brand)
                                                     : AnyShapeStyle(TVColor.surfaceStrong))
                        .frame(width: 62, height: 34)
                    Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                }
                .animation(.easeOut(duration: 0.18), value: isOn.wrappedValue)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.card)
            .accessibilityValue(Text(isOn.wrappedValue
                ? PMString("ext.tv.sources.status.enabled")
                : PMString("ext.tv.sources.status.disabled")))
        }
    }

    /// 只读信息行(不可聚焦)。
    private func infoRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 18) {
            settingIcon(icon, focused: false)
            Text(title).font(.system(size: 22, weight: .medium)).foregroundStyle(TVColor.text)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 18)).foregroundStyle(TVColor.textMuted).lineLimit(1)
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
            Text(binding).font(.system(size: 15, weight: .semibold)).foregroundStyle(TVColor.text)
                .frame(minWidth: 180).padding(.horizontal, 12).padding(.vertical, 6)
                .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(TVColor.cardBorder, lineWidth: 0.5)
                }
            Text(label).font(.system(size: 18)).foregroundStyle(TVColor.textMuted)
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
