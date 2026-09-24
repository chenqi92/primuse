#if os(iOS)
import Network
import PrimuseKit
import SwiftUI
import UIKit

/// `primuse://karaoke-mic` from an Apple TV's karaoke stage.
struct KaraokeRemoteMicTarget: Identifiable {
    let id = UUID()
    let endpoint: KaraokeMicLink.Endpoint
}

/// The iPhone as the singing microphone for an Apple TV: it listens, works
/// out the sung pitch and sends only that to the TV, which scores it. The
/// voice itself is heard in the room as usual.
@MainActor
@Observable
final class KaraokeRemoteMicController {
    enum State: Equatable {
        case starting
        case connecting
        case connected
        case rejected
        case micDenied
        case failed
    }

    private(set) var state: State = .starting
    private(set) var songTitle = ""
    private(set) var isTVPlaying = false
    private(set) var score: Int?
    private(set) var currentNote: Double?

    let endpoint: KaraokeMicLink.Endpoint
    @ObservationIgnored private let microphone = KaraokeMicrophone()
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var detector: KaraokePitchDetector?
    @ObservationIgnored private var isAnalyzing = false
    private let queue = DispatchQueue(label: "primuse.karaoke-remote-mic")

    init(endpoint: KaraokeMicLink.Endpoint) {
        self.endpoint = endpoint
    }

    func start() {
        guard state == .starting else { return }
        Task { @MainActor in
            do {
                try await microphone.start()
            } catch KaraokeMicrophone.StartError.permissionDenied {
                state = .micDenied
                return
            } catch {
                plog("⚠️ Karaoke remote mic: microphone failed: \(error.localizedDescription)")
                state = .failed
                return
            }
            connect()
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        if let connection {
            connection.send(
                content: KaraokeMicLink.encode(KaraokeMicLink.PhoneMessage.goodbye),
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
        connection = nil
        microphone.stop()
    }

    private func connect() {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            state = .failed
            return
        }
        state = .connecting
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        connection.stateUpdateHandler = { [weak self] update in
            Task { @MainActor [weak self] in self?.connectionChanged(update) }
        }
        connection.start(queue: queue)
        self.connection = connection
        receive(on: connection, framer: KaraokeMicLink.Framer())
    }

    private func connectionChanged(_ update: NWConnection.State) {
        switch update {
        case .ready:
            let hello = KaraokeMicLink.PhoneMessage.hello(
                version: KaraokeMicLink.protocolVersion,
                key: endpoint.key,
                deviceName: UIDevice.current.name
            )
            connection?.send(content: KaraokeMicLink.encode(hello), completion: .idempotent)
        case .failed, .cancelled:
            if state == .connecting || state == .connected { state = .failed }
            tickTask?.cancel()
            tickTask = nil
        default:
            break
        }
    }

    private func receive(on connection: NWConnection, framer: KaraokeMicLink.Framer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                var framer = framer
                for message in data.map({ framer.append($0, as: KaraokeMicLink.TVMessage.self) }) ?? [] {
                    self.handle(message)
                }
                if isComplete || error != nil {
                    if self.state == .connected { self.state = .failed }
                    return
                }
                self.receive(on: connection, framer: framer)
            }
        }
    }

    private func handle(_ message: KaraokeMicLink.TVMessage) {
        switch message {
        case .accepted:
            state = .connected
            startStreaming()
        case .rejected:
            state = .rejected
            stop()
        case .status(let title, let playing, let score):
            songTitle = title
            isTVPlaying = playing
            self.score = score
        }
    }

    /// Twenty readings a second while connected.
    private func startStreaming() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.state == .connected else { return }
                self.analyzeAndSend()
            }
        }
    }

    private func analyzeAndSend() {
        guard !isAnalyzing, let connection else { return }
        let rate = microphone.sampleRate / 2
        if detector?.sampleRate != rate {
            detector = KaraokePitchDetector(sampleRate: rate, windowSize: 2_048)
        }
        guard let detector else { return }
        let ring = microphone.ring
        isAnalyzing = true
        Task { @MainActor [weak self] in
            let note = await Task.detached(priority: .userInitiated) { () -> Double?? in
                var raw = [Float](repeating: 0, count: 4_096)
                let fresh = raw.withUnsafeMutableBufferPointer { ring.readLatest(4_096, into: $0.baseAddress!) }
                guard fresh else { return .none }
                let window = (0..<2_048).map { (raw[2 * $0] + raw[2 * $0 + 1]) * 0.5 }
                guard let estimate = detector.detect(window), estimate.confidence >= 0.6 else { return .some(nil) }
                return .some(estimate.midiNote)
            }.value
            guard let self else { return }
            self.isAnalyzing = false
            // No fresh audio yet: nothing to report.
            guard case .some(let reading) = note else { return }
            self.currentNote = reading
            self.sequence += 1
            let message = KaraokeMicLink.PhoneMessage.reading(sequence: self.sequence, midiNote: reading)
            connection.send(content: KaraokeMicLink.encode(message), completion: .idempotent)
        }
    }
}

struct KaraokeRemoteMicView: View {
    @State private var controller: KaraokeRemoteMicController
    @Environment(\.dismiss) private var dismiss

    init(endpoint: KaraokeMicLink.Endpoint) {
        _controller = State(initialValue: KaraokeRemoteMicController(endpoint: endpoint))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.05, blue: 0.2), Color(red: 0.02, green: 0.02, blue: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("close"))
                    Spacer()
                }

                Spacer()
                Image(systemName: statusSymbol)
                    .font(.system(size: 64, weight: .light))
                    .symbolEffect(.pulse, isActive: controller.state == .connecting)
                Text("karaoke_remote_title")
                    .font(.title2.weight(.bold))
                Text(statusText)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)

                if controller.state == .connected {
                    noteDisplay
                    if let score = controller.score {
                        VStack(spacing: 2) {
                            Text("\(score)")
                                .font(.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit())
                            Text("karaoke_score")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                Spacer()
                Text("karaoke_remote_hint")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            controller.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.stop()
        }
    }

    private var statusSymbol: String {
        switch controller.state {
        case .starting, .connecting: "antenna.radiowaves.left.and.right"
        case .connected: "mic.fill"
        case .rejected, .failed: "exclamationmark.triangle"
        case .micDenied: "mic.slash"
        }
    }

    private var statusText: String {
        switch controller.state {
        case .starting, .connecting:
            return String(localized: "karaoke_remote_connecting")
        case .connected:
            return controller.songTitle.isEmpty
                ? String(localized: "karaoke_remote_connected")
                : controller.songTitle
        case .rejected:
            return String(localized: "karaoke_remote_rejected")
        case .micDenied:
            return String(localized: "karaoke_mic_denied")
        case .failed:
            return String(localized: "karaoke_remote_failed")
        }
    }

    private var noteDisplay: some View {
        let name = controller.currentNote.map(Self.noteName) ?? "–"
        return Text(name)
            .font(.system(size: 72, weight: .bold, design: .rounded))
            .contentTransition(.numericText())
            .frame(width: 200, height: 120)
            .background(.white.opacity(controller.currentNote == nil ? 0.05 : 0.14), in: RoundedRectangle(cornerRadius: 24))
            .animation(.easeOut(duration: 0.15), value: controller.currentNote)
            .accessibilityHidden(true)
    }

    /// "A4", "C♯5"… for the live readout.
    static func noteName(_ midi: Double) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let rounded = Int(midi.rounded())
        return names[((rounded % 12) + 12) % 12] + String(rounded / 12 - 1)
    }
}
#endif
