#if os(iOS)
import AVFoundation
import Network
import PrimuseKit
import SwiftUI
import Synchronization
import UIKit

/// `primuse://karaoke-mic` from an Apple TV's karaoke stage.
struct KaraokeRemoteMicTarget: Identifiable {
    let id = UUID()
    let endpoint: KaraokeMicLink.Endpoint
}

/// The iPhone sends pitch for scoring; live vocals require a TV request
/// and consent on this phone.
@MainActor
@Observable
final class KaraokeRemoteMicController {

    private(set) var state: State = .starting
    private(set) var songTitle = ""
    private(set) var isTVPlaying = false
    private(set) var score: Int?
    private(set) var currentNote: Double?
    private(set) var sendsLiveVoice = false
    var presentedVoiceRequest: VoiceRequest?
    private(set) var stemStatus: StemStatus = .none
    @ObservationIgnored private var tvSongID: String?
    @ObservationIgnored private var sentSongID: String?
    @ObservationIgnored private var stemTask: Task<Void, Never>?
    @ObservationIgnored private var uploadConnection: NWConnection?

    let endpoint: KaraokeMicLink.Endpoint
    @ObservationIgnored private let microphone = KaraokeMicrophone()
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var voiceSender: KaraokeVoiceSender?
    @ObservationIgnored private var voiceRequest: VoiceRequest?
    @ObservationIgnored private var allowsLiveVoice = false
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var detector: KaraokePitchDetector?
    @ObservationIgnored private var isAnalyzing = false
    private let queue = DispatchQueue(label: "primuse.karaoke-remote-mic")

    init(endpoint: KaraokeMicLink.Endpoint) {
        self.endpoint = endpoint
    }
}

extension KaraokeRemoteMicController {
    enum State: Equatable {
        case starting
        case connecting
        case connected
        case rejected
        case micDenied
        case failed
    }
    struct VoiceRequest: Identifiable, Equatable {
        let port: UInt16
        let token: String
        var id: String { token }
    }

    /// The AI vocal this phone provides for the TV's current song.
    enum StemStatus: Equatable {
        case none
        case needsModel
        case downloadingModel(Double)
        case preparing
        case separating(Double)
        case sending
        case sent
        case unavailable
    }

    func start() {
        guard state == .starting, startTask == nil else { return }
        startTask = Task { @MainActor in
            do {
                try await microphone.start(forRemoteStage: true)
            } catch KaraokeMicrophone.StartError.permissionDenied {
                guard !Task.isCancelled else { return }
                state = .micDenied
                return
            } catch {
                guard !Task.isCancelled else { return }
                plog("⚠️ Karaoke remote mic: microphone failed: \(error.localizedDescription)")
                state = .failed
                return
            }
            guard !Task.isCancelled else { return }
            connect()
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        allowsLiveVoice = false
        stopLiveVoice()
        tickTask?.cancel()
        tickTask = nil
        stemTask?.cancel()
        stemTask = nil
        uploadConnection?.cancel()
        uploadConnection = nil
        connection?.cancel()
        connection = nil
        microphone.stop()
    }

    func suspend() {
        stop()
        state = .starting
        currentNote = nil
        score = nil
        songTitle = ""
        tvSongID = nil
        sentSongID = nil
        stemStatus = .none
    }

    func refreshInput(changedEngine: AVAudioEngine? = nil) {
        guard state == .connected || state == .connecting,
              microphone.remoteInputNeedsRestart(changedEngine: changedEngine) else { return }
        suspend()
        start()
    }

    private func connect() {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            state = .failed
            return
        }
        state = .connecting
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] update in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                self.connectionChanged(update)
            }
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
            stop()
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
                    self.stop()
                    return
                }
                self.receive(on: connection, framer: framer)
            }
        }
    }

    private func handle(_ message: KaraokeMicLink.TVMessage) {
        switch message {
        case .accepted:
            guard state == .connecting else { return }
            state = .connected
            if microphone.usesLiveInput {
                send(.liveVoiceCapable)
            }
            startStreaming()
        case .liveVoice(let port, let token):
            guard state == .connected, microphone.usesLiveInput else { return }
            let request = VoiceRequest(port: port, token: token)
            guard voiceRequest != request else { return }
            stopLiveVoice()
            guard port > 0, UUID(uuidString: token) != nil else {
                send(.liveVoiceFailed(token: token))
                return
            }
            voiceRequest = request
            if allowsLiveVoice {
                allowVoice(request)
            } else {
                presentedVoiceRequest = request
            }
        case .stopLiveVoice:
            stopLiveVoice()
        case .rejected:
            state = .rejected
            stop()
        case .status(let title, let playing, let score):
            songTitle = title
            isTVPlaying = playing
            self.score = score
        case .nowPlaying(let songID):
            tvSongID = songID
            provideStem()
        case .stemReceived(let songID):
            if songID == tvSongID { stemStatus = .sent }
        }
    }

    private func send(_ message: KaraokeMicLink.PhoneMessage) {
        connection?.send(content: KaraokeMicLink.encode(message), completion: .idempotent)
    }

    private func stopLiveVoice() {
        voiceRequest = nil
        presentedVoiceRequest = nil
        voiceSender?.stop()
        voiceSender = nil
        sendsLiveVoice = false
    }

    func declineVoice(_ request: VoiceRequest) {
        guard voiceRequest == request else { return }
        stopLiveVoice()
        send(.liveVoiceFailed(token: request.token))
    }

    func allowVoice(_ request: VoiceRequest) {
        guard voiceRequest == request, state == .connected, voiceSender == nil else { return }
        presentedVoiceRequest = nil
        allowsLiveVoice = true
        guard let sender = KaraokeVoiceSender(
            host: endpoint.host, port: request.port, token: request.token,
            ring: microphone.ring, sampleRate: microphone.sampleRate,
            hardwareBufferDuration: AVAudioSession.sharedInstance().ioBufferDuration,
            inputCadence: microphone.inputCadence
        ) else {
            declineVoice(request)
            return
        }
        voiceSender = sender
        send(.liveVoiceStarting(token: request.token))
        sender.start { [weak self] ready in
            Task { @MainActor [weak self] in
                guard let self, self.voiceRequest == request else { return }
                if ready { self.sendsLiveVoice = true } else { self.declineVoice(request) }
            }
        }
    }

    // MARK: AI vocal for the TV

    /// Makes sure the TV gets the AI vocal of its current song: separates it
    /// here if needed, then uploads it.
    func provideStem() {
        stemTask?.cancel()
        guard let songID = tvSongID else {
            stemStatus = .none
            return
        }
        guard sentSongID != songID else {
            stemStatus = .sent
            return
        }
        let services = AppServices.shared
        guard let song = services.musicLibrary.song(id: songID) else {
            stemStatus = .unavailable
            return
        }
        let separation = KaraokeSeparationService.shared
        stemTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.tvSongID == songID, self.state == .connected else { return }
                switch separation.modelState {
                case .unsupportedSystem:
                    self.stemStatus = .unavailable
                    return
                case .notDownloaded, .failed:
                    self.stemStatus = .needsModel
                case .downloading(let fraction):
                    self.stemStatus = .downloadingModel(fraction)
                case .ready:
                    switch separation.state(for: song) {
                    case .ready:
                        self.upload(song: song)
                        return
                    case .idle:
                        separation.prepare(song, sourceManager: services.sourceManager)
                        self.stemStatus = .preparing
                    case .preparing:
                        self.stemStatus = .preparing
                    case .separating(let fraction):
                        self.stemStatus = .separating(fraction)
                        let progress = KaraokeMicLink.PhoneMessage.separationProgress(songID: songID, fraction: fraction)
                        self.connection?.send(content: KaraokeMicLink.encode(progress), completion: .idempotent)
                    case .unsupported, .failed:
                        self.stemStatus = .unavailable
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func downloadModel() {
        KaraokeSeparationService.shared.downloadModel()
        provideStem()
    }

    /// Sends the cached stem on its own connection: a header line with the
    /// key, then the file bytes.
    private func upload(song: Song) {
        stemStatus = .sending
        let url = KaraokeSeparationService.stemURL(for: song)
        let songID = song.id
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return }
        let key = endpoint.key
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        uploadConnection?.cancel()
        uploadConnection = connection
        Task { @MainActor [weak self] in
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard let self, self.uploadConnection === connection else { return }
            guard let data, data.count <= KaraokeMicLink.maximumStemBytes else {
                self.stemStatus = .unavailable
                return
            }
            // Built here, where `self` is a constant, so the network callbacks
            // below never capture the weak variable themselves.
            let markFailed: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in
                    if self?.uploadConnection === connection { self?.stemStatus = .unavailable }
                }
            }
            let markSent: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in
                    guard let self, self.tvSongID == songID else { return }
                    self.sentSongID = songID
                }
            }
            connection.stateUpdateHandler = { update in
                guard case .ready = update else {
                    if case .failed = update { markFailed() }
                    return
                }
                let header = KaraokeMicLink.encode(KaraokeMicLink.PhoneMessage.stemUpload(key: key, songID: songID, byteCount: data.count))
                connection.send(content: header + data, completion: .contentProcessed { _ in markSent() })
            }
            connection.start(queue: self.queue)
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
            guard self.connection === connection, self.state == .connected else { return }
            // No fresh audio yet: nothing to report.
            guard case .some(let reading) = note else { return }
            self.currentNote = reading
            self.sequence += 1
            let message = KaraokeMicLink.PhoneMessage.reading(sequence: self.sequence, midiNote: reading)
            connection.send(content: KaraokeMicLink.encode(message), completion: .idempotent)
        }
    }
}

/// The capture callback only writes the existing ring. Conversion, encryption
/// and network I/O run on one serial queue with a bounded playout horizon.
private final class KaraokeVoiceSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "primuse.karaoke-live-voice", qos: .userInitiated)
    private let ring: KaraokeSampleRing
    private let inputCadence: KaraokeInputCadence
    private let codec: KaraokeMicLink.VoiceCodec
    private let connection: NWConnection
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let maximumBacklog: Int
    private let stopped = Atomic<Bool>(false)
    private let context = NWConnection.ContentContext(identifier: "live-voice", expiration: 35)
    private var cursor: Int
    private var timer: DispatchSourceTimer?
    private var inflight = 0
    private var sequence: UInt32 = 0
    private var frame = [Int16](repeating: 0, count: KaraokeMicLink.VoiceCodec.frameCount)
    private var filled = 0
    private var suppliedInput = false
    private var reportedFirstSend = false
    private var onStatus: (@Sendable (Bool) -> Void)?
    private var measurement: CadenceMeasurement?

    private struct CadenceMeasurement {
        let start = DispatchTime.now().uptimeNanoseconds
        let firstInputFrame: Int
        let firstInputBlock: Int
        var lastSend: UInt64?
        var maxGap: UInt64 = 0
        var shortGaps = 0
        var longGaps = 0
        var sent = 0
        var trimmedFrames = 0
        var backpressuredFrames = 0
        var maxBacklog = 0

        mutating func recordSend() {
            let now = DispatchTime.now().uptimeNanoseconds
            if let lastSend {
                let gap = now - lastSend
                maxGap = max(maxGap, gap)
                if gap < 5_000_000 { shortGaps += 1 }
                if gap >= 20_000_000 { longGaps += 1 }
            }
            lastSend = now
            sent += 1
        }
    }

    init?(host: String, port: UInt16, token: String, ring: KaraokeSampleRing, sampleRate: Double,
          hardwareBufferDuration: Double, inputCadence: KaraokeInputCadence) {
        let rate = Double(KaraokeMicLink.VoiceCodec.sampleRate)
        guard let port = NWEndpoint.Port(rawValue: port), (8_000...192_000).contains(sampleRate),
              let source = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(ceil(sampleRate * 0.010))),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(rate * 0.05)),
              let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.ring = ring
        self.inputCadence = inputCadence
        self.input = input
        self.output = output
        self.converter = converter
        // Some audio routes deliver a larger hardware block even when the
        // preferred I/O duration is short. Drain that block across ticks.
        let horizon = min(0.12, max(0.035, hardwareBufferDuration + 0.015))
        maximumBacklog = Int(ceil(sampleRate * horizon))
        converter.primeMethod = .none
        cursor = ring.totalWritten
        codec = KaraokeMicLink.VoiceCodec(token: token)
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVoice
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
    }

    func start(onStatus: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped.load(ordering: .acquiring) else { return }
            self.onStatus = onStatus
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped.load(ordering: .acquiring) else { return }
                switch state {
                case .ready:
                    guard self.timer == nil else { return }
                    self.cursor = self.ring.totalWritten
                    self.measurement = CadenceMeasurement(firstInputFrame: self.cursor, firstInputBlock: self.inputCadence.blockCount)
                    // Pace the packets even when a hardware callback supplies
                    // several packets' worth of samples at once.
                    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
                    timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .microseconds(300))
                    timer.setEventHandler { [weak self] in self?.drain() }
                    self.timer = timer
                    timer.resume()
                case .failed, .cancelled:
                    self.fail()
                default:
                    break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    func stop() {
        stopped.store(true, ordering: .releasing)
        connection.cancel()
        queue.async { [self] in
            reportCadenceIfNeeded(finishing: true)
            timer?.cancel()
            timer = nil
            onStatus = nil
        }
    }

    private func fail() {
        guard !stopped.load(ordering: .acquiring) else { return }
        onStatus?(false)
        stop()
    }

    private func drain() {
        guard !stopped.load(ordering: .acquiring), let destination = input.floatChannelData?[0] else { return }
        let end = ring.totalWritten
        reportCadenceIfNeeded(finishing: false)
        guard end > cursor else { return }
        if let maxBacklog = measurement?.maxBacklog, end - cursor > maxBacklog { measurement?.maxBacklog = end - cursor }
        // After a scheduling stall or network backpressure, resume at live
        // time. An old syllable delivered late is heard as an echo.
        if inflight >= 4 {
            measurement?.backpressuredFrames += end - cursor
            cursor = end
            filled = 0
            converter.reset()
            return
        }
        if end - cursor > maximumBacklog {
            measurement?.trimmedFrames += end - cursor - maximumBacklog
            cursor = end - maximumBacklog
            filled = 0
        }
        let count = min(end - cursor, Int(input.frameCapacity))
        let next = cursor + count
        guard ring.copy(cursor..<next, into: destination) else { return }
        cursor = next
        input.frameLength = AVAudioFrameCount(count)
        output.frameLength = 0
        suppliedInput = false
        let status = converter.convert(to: output, error: nil) { [self] _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        guard status != .error, let samples = output.int16ChannelData?[0] else {
            fail()
            return
        }
        var offset = 0
        while offset < Int(output.frameLength) {
            let take = min(frame.count - filled, Int(output.frameLength) - offset)
            frame.withUnsafeMutableBufferPointer {
                $0.baseAddress!.advanced(by: filled).update(from: samples.advanced(by: offset), count: take)
            }
            offset += take
            filled += take
            if filled == frame.count {
                sendFrame()
                filled = 0
            }
        }
    }

    private func sendFrame() {
        sequence &+= 1
        guard inflight < 4, !stopped.load(ordering: .acquiring),
              let packet = frame.withUnsafeBufferPointer({ codec.encode(sequence: sequence, samples: $0) }) else { return }
        inflight += 1
        measurement?.recordSend()
        connection.send(content: packet, contentContext: context, completion: .contentProcessed { [weak self] error in
            guard let self, !self.stopped.load(ordering: .acquiring) else { return }
            self.inflight -= 1
            if error != nil {
                self.fail()
            } else if !self.reportedFirstSend {
                self.reportedFirstSend = true
                self.onStatus?(true)
            }
        })
    }

    private func reportCadenceIfNeeded(finishing: Bool) {
        guard let snapshot = measurement else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds - snapshot.start
        guard finishing || elapsed >= 6_000_000_000 else { return }
        measurement = nil
        let seconds = max(0.001, Double(elapsed) / 1_000_000_000)
        let frames = ring.totalWritten - snapshot.firstInputFrame
        let blocks = inputCadence.blockCount - snapshot.firstInputBlock
        let meanFrames = blocks > 0 ? frames / blocks : 0
        let pps = (Double(snapshot.sent) / seconds * 10).rounded() / 10
        plog("Karaoke live voice send: elapsedMS=\(elapsed / 1_000_000) captureHz=\(Int(Double(frames) / seconds)) hardwareMeanFrames=\(meanFrames) hardwareMaxFrames=\(inputCadence.maximumFrames) packets=\(snapshot.sent) packetsPerSecond=\(pps) sendGapUnder5MS=\(snapshot.shortGaps) sendGapAtLeast20MS=\(snapshot.longGaps) maxSendGapMS=\(snapshot.maxGap / 1_000_000) maxInputBacklogFrames=\(snapshot.maxBacklog) trimmedInputFrames=\(snapshot.trimmedFrames) backpressuredInputFrames=\(snapshot.backpressuredFrames)")
    }
}

struct KaraokeRemoteMicView: View {
    @State private var controller: KaraokeRemoteMicController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

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
                    stemRow
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
                Text(controller.sendsLiveVoice ? "karaoke_remote_live_hint" : "karaoke_remote_hint")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .alert(item: Binding(get: { controller.presentedVoiceRequest }, set: { controller.presentedVoiceRequest = $0 })) { request in
            Alert(
                title: Text("karaoke_live_request"),
                primaryButton: .default(Text("karaoke_live_allow")) { controller.allowVoice(request) },
                secondaryButton: .cancel(Text("cancel")) { controller.declineVoice(request) }
            )
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.suspend() }
            if phase == .active { controller.start() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main)) { _ in
            if scenePhase == .active { controller.refreshInput() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange).receive(on: DispatchQueue.main)) { event in
            if scenePhase == .active, let engine = event.object as? AVAudioEngine {
                controller.refreshInput(changedEngine: engine)
            }
        }
        .onAppear {
            // 手机当麦克风时不锁屏；和播放时屏幕常亮各持一份，离开时不会把对方的也关掉。
            ScreenWakeLeases.update(owner: "karaokeRemoteMic", holds: true)
            if scenePhase == .active { controller.start() }
        }
        .onDisappear {
            ScreenWakeLeases.update(owner: "karaokeRemoteMic", holds: false)
            controller.stop()
        }
    }

    @ViewBuilder
    private var stemRow: some View {
        switch controller.stemStatus {
        case .none, .unavailable:
            EmptyView()
        case .needsModel:
            Button {
                controller.downloadModel()
            } label: {
                Label(
                    String(
                        format: String(localized: "karaoke_ai_download_format"),
                        ByteCountFormatter.string(fromByteCount: KaraokeVocalModel.approximateDownloadBytes, countStyle: .file)
                    ),
                    systemImage: "sparkles"
                )
            }
            .buttonStyle(.bordered)
            .tint(.white)
        case .downloadingModel(let fraction):
            progressRow(String(localized: "karaoke_ai_downloading"), fraction)
        case .preparing:
            ProgressView(String(localized: "karaoke_remote_ai_preparing"))
                .tint(.white)
        case .separating(let fraction):
            progressRow(String(localized: "karaoke_remote_ai_preparing"), fraction)
            // 这台手机在当前系统上改走慢的那条路时，说明电视为什么要等这么久。
            if KaraokeSeparationService.shared.runsModelOnCPU {
                Text("karaoke_ai_cpu_fallback")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .sending:
            Label("karaoke_remote_ai_sending", systemImage: "arrow.up.circle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
        case .sent:
            Label("karaoke_remote_ai_sent", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private func progressRow(_ title: String, _ fraction: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text(title)
            ProgressView(value: fraction)
                .frame(width: 80)
                .tint(.white)
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.75))
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
