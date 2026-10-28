import SwiftUI
import WatchKit

/// 正在播放底部那一排: 上一首 · 播放暂停 · 下一首。
/// 有声内容换成快退 / 快进 (秒数跟 iPhone 设置走), 电台只有收藏了不止一台时才有两侧的换台键。
struct WatchTransportControls: View {
    @Environment(WatchPlayerStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            leadingButton
            Spacer(minLength: 4)
            WatchPlayPauseButton()
            Spacer(minLength: 4)
            trailingButton
        }
        .frame(height: WatchNowPlayingMetrics.playDiameter)
    }

    @ViewBuilder
    private var leadingButton: some View {
        if store.usesSkipIntervals {
            WatchTransportSideButton(
                symbol: store.skipBackwardSymbol,
                label: WatchString("ext.watch.transport.skipBackward", store.skipBackwardSeconds)
            ) { store.skipBackward() }
        } else if store.showsSideTransport {
            WatchTransportSideButton(
                symbol: "backward.fill",
                label: WatchString(store.isLiveStream
                                   ? "ext.watch.transport.previousStation"
                                   : "ext.watch.transport.previous")
            ) { store.previous() }
        } else {
            Color.clear
                .frame(width: WatchNowPlayingMetrics.sideDiameter)
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if store.usesSkipIntervals {
            WatchTransportSideButton(
                symbol: store.skipForwardSymbol,
                label: WatchString("ext.watch.transport.skipForward", store.skipForwardSeconds)
            ) { store.skipForward() }
        } else if store.showsSideTransport {
            WatchTransportSideButton(
                symbol: "forward.fill",
                label: WatchString(store.isLiveStream
                                   ? "ext.watch.transport.nextStation"
                                   : "ext.watch.transport.next")
            ) { store.next() }
        } else {
            Color.clear
                .frame(width: WatchNowPlayingMetrics.sideDiameter)
        }
    }
}

struct WatchTransportSideButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        let diameter = WatchNowPlayingMetrics.sideDiameter
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(WatchPressableButtonStyle())
        .accessibilityLabel(label)
    }
}

/// 播放暂停。实心圆是主色, 外面一圈是播放进度; 电台没有进度, 只留实心圆。
struct WatchPlayPauseButton: View {
    @Environment(WatchPlayerStore.self) private var store

    var body: some View {
        let diameter = WatchNowPlayingMetrics.playDiameter
        Button {
            store.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(store.accent)
                    .padding(store.isLiveStream ? 0 : 6)
                if !store.isLiveStream {
                    WatchProgressRing(lineWidth: 3)
                }
                icon(diameter: diameter)
            }
            .frame(width: diameter, height: diameter)
        }
        .buttonStyle(WatchPressableButtonStyle())
        .accessibilityLabel(WatchString(accessibilityKey))
    }

    private var iconColor: Color {
        store.accentIsLight ? .black : .white
    }

    private var isLiveConnected: Bool {
        store.isPlaying || store.isLoading
    }

    @ViewBuilder
    private func icon(diameter: CGFloat) -> some View {
        if store.isLoading, !store.isLiveStream {
            ProgressView()
                .tint(iconColor)
        } else {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.34, weight: .bold))
                .foregroundStyle(iconColor)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var symbol: String {
        if store.isLiveStream { return isLiveConnected ? "stop.fill" : "play.fill" }
        return store.isPlaying ? "pause.fill" : "play.fill"
    }

    private var accessibilityKey: String {
        if store.isLiveStream { return isLiveConnected ? "ext.watch.radio.stop" : "ext.watch.transport.play" }
        return store.isPlaying ? "ext.watch.transport.pause" : "ext.watch.transport.play"
    }
}

/// 播放键外圈的进度。单独成一个视图: 进度 100ms 一跳, 只让这一圈跟着重画。
struct WatchProgressRing: View {
    @Environment(WatchPlayerStore.self) private var store
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: store.progress)
                .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

struct WatchPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 系统的 iPhone 音量控件。拿到表冠后转动就改 iPhone 当前线路的音量 (AirPods、
/// 车载、隔空播放都算), 和 Apple Music 手表端同一个控件。音量值只有系统知道,
/// App 读不到也改不了, 所以这里只负责把它放上界面、在该要表冠的时候要表冠。
struct WatchCompanionVolumeControl: WKInterfaceObjectRepresentable {
    let tint: Color
    /// 变一次就重新要一次表冠。
    let focusRequest: Int
    var isLocal = false
    var isActive = true

    @MainActor
    final class Coordinator {
        weak var control: WKInterfaceVolumeControl?
        var appliedFocusRequest: Int?
        var appliedTint: Color?
        var isActive = false
        private var focusTask: Task<Void, Never>?

        /// 刚放进界面、或弹出页刚收起时立刻要表冠会被系统忽略, 晚一拍再要。
        func requestFocus() {
            focusTask?.cancel()
            focusTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, self?.isActive == true else { return }
                self?.control?.focus()
            }
        }

        func resignFocus() {
            isActive = false
            focusTask?.cancel()
            focusTask = nil
            control?.resignFocus()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: isLocal ? .local : .companion)
        context.coordinator.control = control
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        let coordinator = context.coordinator
        coordinator.control = control
        if coordinator.appliedTint != tint {
            coordinator.appliedTint = tint
            control.setTintColor(UIColor(tint))
        }
        guard isActive else {
            if coordinator.isActive { coordinator.resignFocus() }
            return
        }
        if !coordinator.isActive || coordinator.appliedFocusRequest != focusRequest {
            coordinator.isActive = true
            coordinator.appliedFocusRequest = focusRequest
            coordinator.requestFocus()
        }
    }

    static func dismantleWKInterfaceObject(_ control: WKInterfaceVolumeControl, coordinator: Coordinator) {
        coordinator.resignFocus()
    }
}
