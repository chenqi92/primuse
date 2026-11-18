import SwiftUI
import PrimuseKit

private struct CalibrationPromptHost: ViewModifier {
    @Environment(EqualizerService.self) private var eq
    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var choosing: EqualizerService.DeviceSuggestion?
    @State private var hovering = false
    @State private var visible = false
    @State private var unobscured = false

    private var canExpire: Bool { visible && unobscured && scenePhase == .active && choosing == nil && !hovering && !voiceOver }
    private var timerID: String { "\(eq.deviceSuggestion?.id.uuidString ?? ""):\(canExpire)" }
    private var isProcessing: Bool {
        eq.isEnabled && !eq.unsupportedSampleRate && engine.outputMode == .effects
            && !player.isAppleMusicMode && !player.isCastingMode && !player.isSystemMediaPlaybackActive
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let suggestion = eq.deviceSuggestion, scenePhase == .active {
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.device.kind.eqSymbolName)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(suggestion.device.eqDisplayName).font(.caption).foregroundStyle(.secondary)
                                if let id = suggestion.presetID, let preset = eq.preset(withID: id) {
                                    Text(EQText(isProcessing ? "applied" : "selected", preset.localizedName)).font(.subheadline)
                                } else {
                                    Text(EQText("chooseDevice")).font(.subheadline)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12) {
                            if suggestion.presetID != nil {
                                Button(EQText("confirm")) { close(suggestion.id) }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("eq.calibration.confirm")
                            }
                            Button(EQText(suggestion.presetID == nil ? "choose" : "change")) { choosing = suggestion }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("eq.calibration.change")
                            if suggestion.presetID == nil {
                                Button { close(suggestion.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(EQText("done"))
                            }
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .onHover { hovering = $0 }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("eq.calibration.prompt")
                    .background(CalibrationVisibilityProbe(isVisible: $unobscured).allowsHitTesting(false))
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: timerID) {
                guard canExpire, let id = eq.deviceSuggestion?.id else { return }
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                guard canExpire, eq.deviceSuggestion?.id == id else { return }
                close(id)
            }
            .sheet(item: $choosing) { suggestion in
                AudioCalibrationLibraryView(deviceID: suggestion.device.id).environment(eq)
            }
            .onChange(of: eq.currentOutputDevice?.id) { _, current in
                if let choosing, choosing.device.id != current { self.choosing = nil }
            }
    }

    private func close(_ id: UUID) {
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.6)) { eq.acceptDeviceSuggestion(id) }
    }
}

#if os(iOS)
private struct CalibrationVisibilityProbe: UIViewRepresentable {
    @Binding var isVisible: Bool
    func makeUIView(context: Context) -> Sensor { Sensor { isVisible = $0 } }
    func updateUIView(_ view: Sensor, context: Context) {}
    static func dismantleUIView(_ view: Sensor, coordinator: ()) { view.timer?.invalidate() }

    final class Sensor: UIView {
        var timer: Timer?
        private let changed: (Bool) -> Void
        private var previous: Bool?
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate()
            guard window != nil else { changed(false); return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        private func refresh() {
            var top = window?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            let visible = window?.windowScene?.activationState == .foregroundActive
                && top.map { isDescendant(of: $0.view) } == true
            guard previous != visible else { return }
            previous = visible
            changed(visible)
        }
    }
}
#elseif os(macOS)
private struct CalibrationVisibilityProbe: NSViewRepresentable {
    @Binding var isVisible: Bool
    func makeNSView(context: Context) -> Sensor { Sensor { isVisible = $0 } }
    func updateNSView(_ view: Sensor, context: Context) {}
    static func dismantleNSView(_ view: Sensor, coordinator: ()) { view.timer?.invalidate() }

    final class Sensor: NSView {
        var timer: Timer?
        private let changed: (Bool) -> Void
        private var previous: Bool?
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            guard window != nil else { changed(false); return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        private func refresh() {
            let visible = window?.isKeyWindow == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true && window?.attachedSheet == nil
            guard previous != visible else { return }
            previous = visible
            changed(visible)
        }
    }
}
#endif

extension View {
    func calibrationPromptHost() -> some View { modifier(CalibrationPromptHost()) }
}
