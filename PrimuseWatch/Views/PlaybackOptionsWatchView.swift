import SwiftUI
import WatchKit

/// 正在播放右上角「更多」: 喜欢、播放方式、调整进度, 以及声音现在从哪里放出来。
struct WatchPlaybackOptionsView: View {
    let onShowSeek: () -> Void
    @Environment(WatchPlayerStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { OfflineLibraryWatchView() } label: {
                    Label(WatchString("ext.watch.offline.title"), systemImage: "applewatch")
                }
                if store.isOfflinePlayback {
                    Button(WatchString("ext.watch.offline.phone"), systemImage: "iphone") { store.returnToPhone() }
                }
                if store.canLike {
                    likeRow
                }
                if store.offersPlaybackModes {
                    playbackModeRow
                }
                if !store.isLiveStream, store.duration > 0 {
                    Button(action: onShowSeek) {
                        Label(WatchString("ext.watch.seek.title"), systemImage: "timeline.selection")
                    }
                }
                Section {
                    outputRow
                } footer: {
                    Text(WatchString(store.isOfflinePlayback ? "ext.watch.offline.volume" : "ext.watch.volume.hint"))
                }
            }
            .navigationTitle(WatchString("ext.watch.more.title"))
        }
    }

    private var likeRow: some View {
        Button {
            WKInterfaceDevice.current().play(.click)
            store.setLiked(!store.isLiked)
        } label: {
            Label {
                Text(WatchString(store.isLiked ? "ext.watch.liked" : "ext.watch.like"))
            } icon: {
                Image(systemName: store.isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(.pink)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }

    private var playbackModeRow: some View {
        Button {
            store.cyclePlaybackMode()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(WatchString("ext.watch.mode.title"))
                    Text(WatchString(store.playbackMode.titleKey))
                        .font(.footnote)
                        .foregroundStyle(store.playbackMode == .sequential ? Color.secondary : store.accent)
                }
            } icon: {
                Image(systemName: store.playbackMode.symbolName)
                    .foregroundStyle(store.playbackMode == .sequential ? Color.secondary : store.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .accessibilityValue(WatchString(store.playbackMode.titleKey))
    }

    private var outputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: store.outputSymbol)
                .font(.title3)
                .foregroundStyle(store.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(WatchString("ext.watch.output.title"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(store.outputDisplayName)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 调整进度。正在播放页的表冠管音量, 进度在这里调: 转表冠挪时间, 停转 0.4 秒后才真正跳过去,
/// 两侧键一次挪一小段 (有声内容按 iPhone 设置的快退 / 快进秒数)。
struct WatchSeekView: View {
    let isActive: Bool
    @Environment(WatchPlayerStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    /// 表冠绑定的目标时间 (秒)。进页时对齐当前进度, 转表冠改它, 停转后交给 store.seek。
    @State private var crownTime: Double = 0
    /// 停转 0.4 秒后才发 seek, 连转时不每一格都发一条消息。
    @State private var seekDebounceTask: Task<Void, Never>?
    @State private var pendingSeekSongID: String?
    /// 程序化改写 crownTime 时置 true, 让 .onChange 跳过这一次, 不当成用户转动。
    @State private var programmaticCrownUpdate = false
    @FocusState private var isCrownFocused: Bool

    private var isAdjusting: Bool { seekDebounceTask != nil }
    private var displayTime: Double { isAdjusting ? crownTime : store.currentTime }
    private var backwardStep: Int { store.usesSkipIntervals ? store.skipBackwardSeconds : 15 }
    private var forwardStep: Int { store.usesSkipIntervals ? store.skipForwardSeconds : 15 }
    /// 很长的有声书一格 1 秒转不动, 半小时以上改成一格 10 秒。
    private var crownStep: Double { store.duration > 1800 ? 10 : 1 }
    private var acceptsInput: Bool { isActive && isVisible && scenePhase == .active }
    private var progress: Double {
        guard store.duration.isFinite, store.duration > 0, displayTime.isFinite else { return 0 }
        return min(1, max(0, displayTime / store.duration))
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(WatchString("ext.watch.seek.title"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            progressDial
            Text(store.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            HStack {
                stepButton(symbol: symbol(forward: false, seconds: backwardStep),
                           label: WatchString("ext.watch.transport.skipBackward", backwardStep)) {
                    seekImmediately(to: displayTime - Double(backwardStep))
                }
                Spacer(minLength: 8)
                stepButton(symbol: symbol(forward: true, seconds: forwardStep),
                           label: WatchString("ext.watch.transport.skipForward", forwardStep)) {
                    seekImmediately(to: displayTime + Double(forwardStep))
                }
            }
            .padding(.horizontal, 14)
            Text(WatchString("ext.watch.seek.crownHint"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.top, -10)
        .padding(.bottom, WatchNowPlayingMetrics.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusable(acceptsInput)
        .focused($isCrownFocused)
        .focusEffectDisabled()
        .digitalCrownRotation(
            $crownTime,
            from: 0,
            through: max(1, store.duration),
            by: crownStep,
            sensitivity: store.duration > 1800 ? .medium : .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            isVisible = true
        }
        .onChange(of: acceptsInput) { _, active in
            if active {
                syncCrown(to: store.currentTime)
                isCrownFocused = true
            } else {
                isCrownFocused = false
                finishPendingSeek()
            }
        }
        .onChange(of: crownTime) { _, newValue in
            if programmaticCrownUpdate {
                programmaticCrownUpdate = false
                return
            }
            guard acceptsInput else { return }
            seekDebounceTask?.cancel()
            pendingSeekSongID = store.songID
            seekDebounceTask = Task { @MainActor [newValue] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                store.seek(to: newValue)
                // 被新一次转动取消时不清 (新任务接管), 免得空闲跟随把用户正在调的值盖掉。
                seekDebounceTask = nil
                pendingSeekSongID = nil
            }
        }
        // 换歌或空闲时让表冠跟着播放进度走, 否则轻转一格会从几分钟前的旧值起跳。
        .onChange(of: store.songID) { _, _ in
            seekDebounceTask?.cancel()
            seekDebounceTask = nil
            pendingSeekSongID = nil
            syncCrown(to: store.currentTime)
        }
        .onChange(of: store.currentTime) { _, newTime in
            guard seekDebounceTask == nil else { return }
            if abs(newTime - crownTime) > crownStep { syncCrown(to: newTime) }
        }
        .onDisappear {
            isVisible = false
            isCrownFocused = false
            finishPendingSeek()
        }
    }

    private func finishPendingSeek() {
        guard let task = seekDebounceTask else { return }
        task.cancel()
        seekDebounceTask = nil
        if pendingSeekSongID == store.songID { store.seek(to: crownTime) }
        pendingSeekSongID = nil
    }

    private var progressDial: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let lineWidth = max(4, side * 0.065)
            let radius = (side - lineWidth - 4) / 2
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(store.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .fill(.white)
                    .frame(width: lineWidth + 1, height: lineWidth + 1)
                    .padding(3)
                    .background(store.accent, in: Circle())
                    .offset(y: -radius)
                    .rotationEffect(.degrees(progress * 360))
                VStack(spacing: 2) {
                    Text(formatTime(displayTime))
                        .font(.system(size: min(32, side * 0.28), weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("/ " + formatTime(store.duration))
                        .font(.system(size: min(14, side * 0.14), design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: side * 0.72)
            }
            .padding(lineWidth / 2 + 2)
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchString("ext.watch.seek.title"))
        .accessibilityValue(formatTime(displayTime) + " / " + formatTime(store.duration))
        .accessibilityHint(WatchString("ext.watch.seek.hint"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seekImmediately(to: displayTime + crownStep)
            case .decrement: seekImmediately(to: displayTime - crownStep)
            @unknown default: break
            }
        }
    }

    private func stepButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.16), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(WatchPressableButtonStyle())
        .accessibilityLabel(label)
    }

    private func seekImmediately(to time: Double) {
        guard acceptsInput else { return }
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        pendingSeekSongID = nil
        let clamped = min(max(0, time), store.duration)
        store.seek(to: clamped)
        syncCrown(to: clamped)
    }

    /// 对齐 crownTime 但不触发 seek。值没变时不动: .onChange 不会触发, 标志提前置位会吞掉下一次转动。
    private func syncCrown(to value: Double) {
        guard value != crownTime else { return }
        programmaticCrownUpdate = true
        crownTime = value
    }

    /// 系统只有这几档秒数的快进快退图标, 别的秒数用不带数字的那个。
    private func symbol(forward: Bool, seconds: Int) -> String {
        let base = forward ? "goforward" : "gobackward"
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let total = Int(t)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
