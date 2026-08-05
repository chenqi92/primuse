import SwiftUI

/// Watch 端的 Now Playing 主屏。
///
/// 布局: 封面 + 歌名 / 艺术家 / 当前歌词 + 进度条 + 上/暂/下三个按钮。
/// 主色跟 iPhone ThemeService 同步, RGB 推过来实时着色。
///
/// 调进度两种方式:
/// - 数字表冠旋转 ── 进入"调进度模式"后转表冠 ±N 秒精细调整 (一圈≈30s)
/// - 进度条点击 ── 点哪儿跳哪儿 (粗调, 没那么精确)
struct NowPlayingWatchView: View {
    @Environment(WatchPlayerStore.self) private var store
    /// 数字表冠绑定的 seek 偏移 (秒)。每次进 NowPlaying 重置成当前 currentTime,
    /// 用户转表冠会修改这个值, 松手后 .onChange 把值同步给 store.seek。
    @State private var crownTime: Double = 0
    /// crown 实际生效时机: 用户停止旋转 0.4s 后才发 seek, 避免连续转动期间
    /// 每一帧都狂发 sendMessage 把链路打满。
    @State private var seekDebounceTask: Task<Void, Never>?
    /// 程序化改写 crownTime 时置 true ── 让 .onChange(of: crownTime) 跳过这次
    /// 不发 seek。覆盖三种情况: onAppear / 切歌重置, 以及空闲时跟随 currentTime。
    /// 只有用户真正转表冠产生的变化才会触发 seek。
    @State private var programmaticCrownUpdate = false

    /// 把 crownTime 跟某个值"对齐"但不触发 seek ── 程序化写入统一走这里。
    /// 值无变化时不动: .onChange 不会触发, 标志若提前置位会误吞下一次用户转动。
    private func syncCrown(to value: Double) {
        guard value != crownTime else { return }
        programmaticCrownUpdate = true
        crownTime = value
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if store.hasSong {
                    cover
                    titleBlock
                    if !store.isLiveStream, !store.currentLyric.isEmpty {
                        lyricLine
                    }
                    progressBlock
                    transportButtons
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .navigationTitle(WatchString("ext.watch.appName"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.requestCurrentState()
            syncCrown(to: store.currentTime)
        }
        // 数字表冠 ── 转动时直接调 seek 时间, 1 step = 1 秒。
        .focusable(store.hasSong && !store.isLiveStream)
        .digitalCrownRotation(
            $crownTime,
            from: 0,
            through: max(1, store.duration),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownTime) { _, newValue in
            guard !store.isLiveStream else { return }
            // 程序化写入 (重置 / 跟随 currentTime) 不算用户操作, 跳过不发 seek。
            if programmaticCrownUpdate {
                programmaticCrownUpdate = false
                return
            }
            // 用户停转 0.4s 后才发 seek, 避免连转中每帧都打 sendMessage。
            seekDebounceTask?.cancel()
            seekDebounceTask = Task { @MainActor [newValue] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                store.seek(to: newValue)
                // 这次 debounce 已完成, 清空 handle 让空闲跟随逻辑恢复。被新一次
                // 转动取消时不清 (newer task 接管), 以免误开门覆盖用户正在调的值。
                seekDebounceTask = nil
            }
        }
        // 切歌 ── 一切重新跟随 iPhone, 把 crown 重置到新歌当前位置 (程序化, 不发 seek)。
        .onChange(of: store.songID) { _, _ in syncCrown(to: store.currentTime) }
        // 空闲时让 crown 跟随播放进度 ── 否则放了几分钟后 crownTime 仍停留在
        // 旧位置, 用户轻转一格就会从陈旧值 +1 把播放拖回几分钟前。仅在无 pending
        // debounce (用户没在调) 且差值 >1s 时同步, 避免每 100ms 抖动 / 覆盖用户操作。
        .onChange(of: store.currentTime) { _, newTime in
            guard !store.isLiveStream else { return }
            guard seekDebounceTask == nil else { return }
            if abs(newTime - crownTime) > 1 { syncCrown(to: newTime) }
        }
    }

    private var cover: some View {
        ZStack {
            if let img = store.coverImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [store.accent.opacity(0.5), store.accent.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: store.isLiveStream ? "radio.fill" : "music.note")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var titleBlock: some View {
        VStack(spacing: 2) {
            Text(store.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(store.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 当前歌词单行 ── 在艺术家下面紧跟一行, 跟随播放进度自动更新。
    /// 暂停时停留在最后一行歌词不动。
    private var lyricLine: some View {
        Text(store.currentLyric)
            .font(.caption2)
            .foregroundStyle(store.accent)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 4)
            .id(store.currentLyric)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: store.currentLyric)
    }

    @ViewBuilder
    private var progressBlock: some View {
        if store.isLiveStream {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text(WatchString("ext.watch.radio.live"))
                    .font(.caption.weight(.bold))
                if store.currentTime > 0 {
                    Text("· \(formatTime(store.currentTime))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(spacing: 2) {
            // 自定义进度条 ── 支持 tap-to-seek (点哪跳哪)。比 ProgressView
            // 多一个 GeometryReader 算点击位置在条上的比例。
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(store.accent)
                        .frame(width: geo.size.width * CGFloat(store.progress))
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard store.duration > 0, geo.size.width > 0 else { return }
                    let ratio = max(0, min(1, location.x / geo.size.width))
                    store.seek(to: store.duration * Double(ratio))
                }
            }
            .frame(height: 6)

            HStack {
                Text(formatTime(store.currentTime))
                    .monospacedDigit()
                Spacer()
                Text(formatTime(store.duration))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var transportButtons: some View {
        if store.isLiveStream {
            Button { store.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(store.accent)
                    Image(systemName: store.isPlaying || store.isLoading ? "stop.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 58, height: 58)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(WatchString(
                store.isPlaying || store.isLoading ? "ext.watch.radio.stop" : "ext.watch.radio.live"
            ))
            .padding(.top, 4)
        } else {
            HStack(spacing: 14) {
            Button { store.previous() } label: {
                Image(systemName: "backward.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)

            Button { store.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(store.accent)
                    Group {
                        if store.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                }
                .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)

            Button { store.next() } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            }
            .padding(.top, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(WatchString("ext.watch.nowPlaying.empty.title"))
                .font(.headline)
            Text(store.isReachable
                 ? WatchString("ext.watch.nowPlaying.empty.reachable")
                 : WatchString("ext.watch.nowPlaying.empty.unreachable"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
