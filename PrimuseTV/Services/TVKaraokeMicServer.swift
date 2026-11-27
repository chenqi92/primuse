#if os(tvOS)
import AVFoundation
import Foundation
import Network
import Observation
import PrimuseKit
import os.lock

/// Pairs the stage with one phone for scoring and optional live voice.
@MainActor
@Observable
final class TVKaraokeMicServer {

    private(set) var state: State = .idle
    private(set) var supportsLiveVoice = false
    private(set) var isLiveVoiceEnabled = false
    @ObservationIgnored private var liveVoice: TVKaraokeVoiceReceiver?
    @ObservationIgnored private var voiceToken: String?
    private let voiceQueue = DispatchQueue(label: "primuse.tv.karaoke-voice", qos: .userInitiated)
    /// Called on the main actor for every reading from the connected phone.
    @ObservationIgnored var onReading: (@MainActor (Double?) -> Void)?
    /// A complete AI vocal stem file uploaded by the phone.
    @ObservationIgnored var onStem: (@MainActor (String, Data) -> Void)?
    /// The phone's AI separation progress for a song.
    @ObservationIgnored var onSeparationProgress: (@MainActor (String, Double) -> Void)?
    @ObservationIgnored private var lastNowPlaying: String??
    /// Connections that have not proven the key yet, oldest first, plus
    /// uploads in progress. Bounded so nobody on the network can pile them up.
    @ObservationIgnored private var pending: [NWConnection] = []
    @ObservationIgnored private var uploads: [NWConnection] = []

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var key = KaraokeMicLink.makeKey()
    private let queue = DispatchQueue(label: "primuse.tv.karaoke-mic")
}

extension TVKaraokeMicServer {
    enum State: Equatable {
        case idle
        case listening(KaraokeMicLink.Endpoint)
        case connected(deviceName: String, endpoint: KaraokeMicLink.Endpoint)
        case failed
    }
    static let maximumPendingConnections = 4
    static let handshakeTimeout: Duration = .seconds(5)

    var endpoint: KaraokeMicLink.Endpoint? {
        switch state {
        case .listening(let endpoint), .connected(_, let endpoint): endpoint
        case .idle, .failed: nil
        }
    }

    func start() {
        guard listener == nil else { return }
        key = KaraokeMicLink.makeKey()
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.stateUpdateHandler = { [weak self, weak listener] update in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.listener === listener else { return }
                    self.listenerChanged(update)
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            plog("⚠️ TV karaoke mic: listener failed: \(error.localizedDescription)")
            state = .failed
        }
    }

    func stop() {
        disconnectLiveVoice()
        for other in pending + uploads { other.cancel() }
        pending.removeAll()
        uploads.removeAll()
        if let connection {
            connection.send(content: KaraokeMicLink.encode(KaraokeMicLink.TVMessage.rejected), completion: .idempotent)
            connection.cancel()
        }
        connection = nil
        listener?.cancel()
        listener = nil
        state = .idle
    }

    func setLiveVoiceEnabled(_ enabled: Bool) {
        guard enabled != isLiveVoiceEnabled else { return }
        if !enabled {
            if let connection {
                connection.send(content: KaraokeMicLink.encode(KaraokeMicLink.TVMessage.stopLiveVoice), completion: .idempotent)
            }
            isLiveVoiceEnabled = false
            voiceToken = nil
            liveVoice?.stop()
            liveVoice = nil
            return
        }
        guard supportsLiveVoice, let connection, case .hostPort(let host, _) = connection.endpoint else { return }
        let token = UUID().uuidString
        let receiver = TVKaraokeVoiceReceiver(host: host, token: token, queue: voiceQueue) { [weak self] port in
            Task { @MainActor in
                guard let self, self.voiceToken == token, let phone = self.connection else { return }
                guard let port else {
                    self.setLiveVoiceEnabled(false)
                    return
                }
                let message = KaraokeMicLink.TVMessage.liveVoice(port: port, token: token)
                phone.send(content: KaraokeMicLink.encode(message), completion: .idempotent)
            }
        }
        voiceToken = token
        liveVoice = receiver
        isLiveVoiceEnabled = true
        receiver.start()
    }

    private func disconnectLiveVoice() {
        setLiveVoiceEnabled(false)
        supportsLiveVoice = false
    }

    /// Tells the phone which song is playing, so it can provide its stem.
    func sendNowPlaying(songID: String?) {
        lastNowPlaying = .some(songID)
        guard case .connected = state, let connection else { return }
        connection.send(content: KaraokeMicLink.encode(KaraokeMicLink.TVMessage.nowPlaying(songID: songID)), completion: .idempotent)
    }

    func sendStatus(songTitle: String, isPlaying: Bool, score: Int?) {
        guard case .connected = state, let connection else { return }
        let message = KaraokeMicLink.TVMessage.status(songTitle: songTitle, isPlaying: isPlaying, score: score)
        connection.send(content: KaraokeMicLink.encode(message), completion: .idempotent)
    }

    private func listenerChanged(_ update: NWListener.State) {
        switch update {
        case .ready:
            guard let port = listener?.port?.rawValue, let host = TVConfigServer.localIPv4() else {
                state = .failed
                return
            }
            state = .listening(KaraokeMicLink.Endpoint(host: host, port: port, key: key))
        case .failed(let error):
            plog("⚠️ TV karaoke mic: listener stopped: \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
            state = .failed
        default:
            break
        }
    }

    /// A new phone: it only counts once its hello carries the right key.
    private func accept(_ incoming: NWConnection) {
        incoming.stateUpdateHandler = { [weak self, weak incoming] update in
            guard let incoming else { return }
            if case .failed = update {
                Task { @MainActor [weak self] in self?.dropped(incoming) }
            } else if case .cancelled = update {
                Task { @MainActor [weak self] in self?.dropped(incoming) }
            }
        }
        pending.append(incoming)
        if pending.count > Self.maximumPendingConnections {
            pending.removeFirst().cancel()
        }
        incoming.start(queue: queue)
        receiveFirst(on: incoming, framer: KaraokeMicLink.Framer())
        Task { @MainActor [weak self, weak incoming] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard let self, let incoming, self.pending.contains(where: { $0 === incoming }) else { return }
            self.pending.removeAll { $0 === incoming }
            incoming.cancel()
        }
    }

    /// The connection proved the key (or failed to): it is no longer pending.
    private func settle(_ incoming: NWConnection) {
        pending.removeAll { $0 === incoming }
    }

    /// The first line decides what the connection is: the phone's control
    /// channel or a one-off stem upload.
    private func receiveFirst(on incoming: NWConnection, framer: KaraokeMicLink.Framer) {
        incoming.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.pending.contains(where: { $0 === incoming }) else { return }
                var framer = framer
                if let data, let first = framer.firstMessage(data, as: KaraokeMicLink.PhoneMessage.self) {
                    self.settle(incoming)
                    if case .stemUpload(let offeredKey, let songID, let byteCount) = first {
                        guard offeredKey == self.key,
                              byteCount > 0,
                              byteCount <= KaraokeMicLink.maximumStemBytes,
                              self.uploads.count < 2 else {
                            incoming.cancel()
                            return
                        }
                        self.uploads.append(incoming)
                        let payload = TVKaraokePayloadBuffer(capacity: byteCount)
                        payload.data.append(framer.takeRemainder())
                        self.receivePayload(on: incoming, songID: songID, expected: byteCount, payload: payload)
                        return
                    }
                    let authenticated = self.handle(first, from: incoming, authenticated: false)
                    guard authenticated else { return }
                    for message in framer.append(Data(), as: KaraokeMicLink.PhoneMessage.self) {
                        _ = self.handle(message, from: incoming, authenticated: true)
                    }
                    self.receive(on: incoming, framer: framer, authenticated: true)
                    return
                }
                if isComplete || error != nil {
                    incoming.cancel()
                    return
                }
                self.receiveFirst(on: incoming, framer: framer)
            }
        }
    }

    private func receivePayload(on incoming: NWConnection, songID: String, expected: Int, payload: TVKaraokePayloadBuffer) {
        if payload.data.count >= expected {
            uploads.removeAll { $0 === incoming }
            onStem?(songID, payload.data.prefix(expected))
            incoming.send(
                content: KaraokeMicLink.encode(KaraokeMicLink.TVMessage.stemReceived(songID: songID)),
                completion: .contentProcessed { _ in incoming.cancel() }
            )
            return
        }
        incoming.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.uploads.contains(where: { $0 === incoming }) else { return }
                if let data { payload.data.append(data) }
                if payload.data.count < expected, isComplete || error != nil {
                    self.uploads.removeAll { $0 === incoming }
                    incoming.cancel()
                    return
                }
                self.receivePayload(on: incoming, songID: songID, expected: expected, payload: payload)
            }
        }
    }

    private func receive(on incoming: NWConnection, framer: KaraokeMicLink.Framer, authenticated: Bool) {
        incoming.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var framer = framer
                var authenticated = authenticated
                let messages = data.map { framer.append($0, as: KaraokeMicLink.PhoneMessage.self) } ?? []
                for message in messages {
                    authenticated = self.handle(message, from: incoming, authenticated: authenticated)
                    if !authenticated, incoming !== self.connection { break }
                }
                if isComplete || error != nil {
                    incoming.cancel()
                    return
                }
                self.receive(on: incoming, framer: framer, authenticated: authenticated)
            }
        }
    }

    /// Returns whether the connection is authenticated after `message`.
    private func handle(_ message: KaraokeMicLink.PhoneMessage, from incoming: NWConnection, authenticated: Bool) -> Bool {
        switch message {
        case .hello(let version, let offeredKey, let deviceName):
            guard version == KaraokeMicLink.protocolVersion, offeredKey == key, let endpoint else {
                incoming.send(content: KaraokeMicLink.encode(KaraokeMicLink.TVMessage.rejected), completion: .idempotent)
                incoming.cancel()
                return false
            }
            // A newer phone replaces the previous one.
            disconnectLiveVoice()
            if let connection, connection !== incoming { connection.cancel() }
            connection = incoming
            state = .connected(deviceName: String(deviceName.prefix(40)), endpoint: endpoint)
            incoming.send(content: KaraokeMicLink.encode(KaraokeMicLink.TVMessage.accepted(songTitle: "")), completion: .idempotent)
            if case .some(let songID) = lastNowPlaying {
                incoming.send(content: KaraokeMicLink.encode(KaraokeMicLink.TVMessage.nowPlaying(songID: songID)), completion: .idempotent)
            }
            return true
        case .liveVoiceCapable:
            guard authenticated, incoming === connection else { return authenticated }
            supportsLiveVoice = true
            return true
        case .liveVoiceStarting(let token):
            guard authenticated, incoming === connection else { return authenticated }
            if token == voiceToken { liveVoice?.expectAudio() }
            return true
        case .liveVoiceFailed(let token):
            guard authenticated, incoming === connection else { return authenticated }
            if token == voiceToken { setLiveVoiceEnabled(false) }
            return true
        case .reading(_, let midiNote):
            guard authenticated, incoming === connection else { return authenticated }
            if let midiNote, !(midiNote.isFinite && (20...110).contains(midiNote)) { return authenticated }
            onReading?(midiNote)
            return authenticated
        case .separationProgress(let songID, let fraction):
            guard authenticated, incoming === connection else { return authenticated }
            onSeparationProgress?(songID, min(1, max(0, fraction)))
            return authenticated
        case .stemUpload:
            // Only valid as the first line of its own connection.
            incoming.cancel()
            return false
        case .goodbye:
            incoming.cancel()
            return false
        }
    }

    private func dropped(_ incoming: NWConnection) {
        pending.removeAll { $0 === incoming }
        uploads.removeAll { $0 === incoming }
        guard incoming === connection else { return }
        disconnectLiveVoice()
        connection = nil
        if let endpoint { state = .listening(endpoint) }
    }
}
/// Accumulates an upload in place; passing `Data` by value between the
/// receive callbacks would copy the whole stem on every chunk.
final class TVKaraokePayloadBuffer: @unchecked Sendable {
    var data: Data

    init(capacity: Int) {
        data = Data(capacity: capacity)
    }
}

/// The UDP socket and engine are confined to the voice queue. Only the
/// bounded PCM buffer crosses into the audio render callback.
private final class TVKaraokeVoiceReceiver: @unchecked Sendable {
    private let host: NWEndpoint.Host
    private let codec: KaraokeMicLink.VoiceCodec
    private let queue: DispatchQueue
    private let onPortChanged: @Sendable (UInt16?) -> Void
    private let audio = TVKaraokeVoiceBuffer()
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var listener: NWListener?
    private var peer: NWConnection?
    private var timer: DispatchSourceTimer?
    private var lastActivity: DispatchTime?
    private var lastSequence: UInt32?
    private var closed = false

    init(host: NWEndpoint.Host, token: String, queue: DispatchQueue,
         onPortChanged: @escaping @Sendable (UInt16?) -> Void) {
        self.host = host
        self.codec = KaraokeMicLink.VoiceCodec(token: token)
        self.queue = queue
        self.onPortChanged = onPortChanged
    }

    func start() {
        queue.async { [self] in
            guard !self.closed else { return }
            do {
                let parameters = NWParameters.udp
                parameters.serviceClass = .interactiveVoice
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, !self.closed else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port else { self.fail(); return }
                        self.lastActivity = nil // The phone may now be waiting for local consent.
                        self.onPortChanged(port.rawValue)
                    case .failed: self.fail()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
                self.lastActivity = .now()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self, let last = self.lastActivity, DispatchTime.now() > last + .seconds(5) else { return }
                    self.fail()
                }
                self.timer = timer
                timer.resume()
            } catch { self.fail() }
        }
    }

    func expectAudio() {
        queue.async { if !self.closed, self.lastActivity == nil { self.lastActivity = .now() } }
    }

    private func accept(_ connection: NWConnection) {
        guard !closed, peer == nil, case .hostPort(let remote, _) = connection.endpoint, remote == host else {
            connection.cancel()
            return
        }
        peer = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.peer === connection else { return }
            if case .failed = state { self.fail() }
        }
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.peer === connection, !self.closed else { return }
            guard error == nil else { self.fail(); return }
            guard let data, let packet = self.codec.decode(data) else {
                // An unauthenticated first packet must not reserve the socket.
                if self.lastSequence == nil {
                    self.peer = nil
                    connection.cancel()
                    return
                }
                self.receive(connection)
                return
            }
            let arrival = DispatchTime.now()
            if let last = self.lastSequence, Int32(bitPattern: packet.sequence &- last) <= 0 {
                self.receive(connection)
                return
            }
            self.lastSequence = packet.sequence
            self.lastActivity = arrival
            do {
                if self.engine == nil { try self.startOutput() }
                self.audio.append(packet.samples, arrival: arrival.uptimeNanoseconds)
            } catch {
                self.fail()
                return
            }
            self.receive(connection)
        }
    }

    private func startOutput() throws {
        let engine = AVAudioEngine()
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = Double(KaraokeMicLink.VoiceCodec.sampleRate)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw CocoaError(.coderInvalidValue)
        }
        let audio = self.audio
        let source = AVAudioSourceNode(format: format) { silence, _, frames, list in
            let output = UnsafeMutableAudioBufferListPointer(list)
            guard let buffer = output.first, let bytes = buffer.mData else { return noErr }
            let destination = bytes.assumingMemoryBound(to: Float.self)
            let count = min(Int(frames), Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride)
            let written = audio.read(into: destination, count: count, now: DispatchTime.now().uptimeNanoseconds)
            if written < count { (destination + written).update(repeating: 0, count: count - written) }
            silence.pointee = ObjCBool(written == 0)
            return noErr
        }
        engine.attach(source)
        var connectError: NSError?
        guard PrimuseConnectNodes(engine, source, engine.mainMixerNode, format, &connectError) else {
            throw connectError ?? NSError(domain: "PrimuseAudioEngine", code: 1)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        let outputMS = Int((source.outputPresentationLatency * 1000).rounded())
        plog("TV karaoke live voice started: reportedOutputLatencyMS=\(outputMS)")
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.fail() }
        }
    }

    func stop() {
        queue.async { self.close() }
    }

    private func fail() {
        guard !closed else { return }
        close()
        onPortChanged(nil)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        peer?.cancel()
        peer = nil
        listener?.cancel()
        listener = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.stop()
            plog("TV karaoke live voice stopped: \(audio.statistics)")
        }
        engine = nil
    }
}

/// The render callback never waits for the network. Re-prime after an
/// underrun; on overflow, keep the newest voice instead of building delay.
final class TVKaraokeVoiceBuffer: Sendable {
    private static let framesPerPacket = KaraokeMicLink.VoiceCodec.frameCount
    private static let packetSlots = 32
    private static let capacity = packetSlots * framesPerPacket
    private struct State {
        var samples = [Float](repeating: 0, count: capacity)
        var arrivals = [UInt64](repeating: 0, count: packetSlots)
        var written = 0
        var consumed = 0
        var lastArrival: UInt64?
        var lastRender: UInt64?
        var burstFrames = 0
        var renderQuantum = framesPerPacket
        var peakQuantum = 0
        var largestCallback = 0
        var arrivalGap = framesPerPacket
        var maxGapNS: UInt64 = 0
        var peakQueued = 0
        var priming = true
        var gain: Float = 0.5
        var overflow = 0
        var stale = 0
        var played = 0
        var underruns = 0
        var renders = 0
        var ageTotalNS: UInt64 = 0
        var ageMaxNS: UInt64 = 0

        // An HDMI render cycle can pull several source blocks back to back.
        // Budget for the complete pull and for recently observed packet
        // spacing. A burst raises the budget immediately; it ages out.
        var primeFrames: Int {
            max(2 * framesPerPacket, min(capacity / 3, renderQuantum + max(framesPerPacket, arrivalGap - framesPerPacket)))
        }

        var queueLimit: Int {
            min(capacity, primeFrames + max(4 * framesPerPacket, 2 * renderQuantum))
        }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ pcm: [Int16], arrival: UInt64) {
        guard pcm.count == Self.framesPerPacket else { return }
        let peak = pcm.reduce(1) { max($0, abs(Int($1))) }
        let target = min(0.5, Float(Int16.max) * 0.4 / Float(peak))
        state.withLock { s in
            if let last = s.lastArrival, arrival >= last {
                let gap = arrival - last
                s.maxGapNS = max(s.maxGapNS, gap)
                // Sub-millisecond packets belong to a burst, not independent
                // evidence that the network is getting smoother.
                if gap >= 1_000_000 {
                    let frames = Int(min(gap, 80_000_000) * UInt64(KaraokeMicLink.VoiceCodec.sampleRate) / 1_000_000_000)
                    s.arrivalGap = max(frames, s.arrivalGap - 2)
                }
            }
            s.lastArrival = arrival
            // Reduce strong peaks immediately; release smoothly. Never raise
            // quiet input above the fixed -6 dB microphone gain.
            s.gain = min(target, s.gain + 0.005)
            let scale = s.gain / 32768
            let offset = s.written % Self.capacity
            for i in pcm.indices { s.samples[offset + i] = Float(pcm[i]) * scale }
            s.arrivals[offset / Self.framesPerPacket] = arrival
            s.written += pcm.count
            let queued = s.written - s.consumed
            s.peakQueued = max(s.peakQueued, queued)
            let excess = queued - s.queueLimit
            if excess > 0 {
                s.consumed += excess
                s.overflow += excess
            }
        }
    }

    func read(into out: UnsafeMutablePointer<Float>, count: Int, now: UInt64) -> Int {
        guard count > 0, count <= Self.capacity / 2 else { return 0 }
        return state.withLockIfAvailableUnchecked { s -> Int in
            if let previous = s.lastRender, now > previous, now - previous < 2_000_000 {
                s.burstFrames = min(Self.capacity / 3, s.burstFrames + count)
            } else {
                s.burstFrames = count
            }
            s.lastRender = now
            s.renderQuantum = max(s.burstFrames, s.renderQuantum - 1)
            s.peakQuantum = max(s.peakQuantum, s.burstFrames)
            s.largestCallback = max(s.largestCallback, count)
            while s.consumed < s.written {
                let packet = s.consumed / Self.framesPerPacket
                let received = s.arrivals[packet % Self.packetSlots]
                guard now > received, now - received >= 150_000_000 else { break }
                let next = (packet + 1) * Self.framesPerPacket
                s.stale += next - s.consumed
                s.consumed = next
                s.priming = true
            }
            let available = s.written - s.consumed
            if available == 0 {
                if !s.priming { s.underruns += 1; s.priming = true }
                return 0
            }
            guard !s.priming || available >= s.primeFrames else { return 0 }
            let offset = s.consumed % Self.capacity
            let arrival = s.arrivals[offset / Self.framesPerPacket]
            let age = now >= arrival ? now - arrival : 0
            let frames = min(available, count)
            let first = min(frames, Self.capacity - offset)
            s.samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                out.update(from: base + offset, count: first)
                if first < frames { (out + first).update(from: base, count: frames - first) }
            }
            s.consumed += frames
            s.played += frames
            s.priming = frames < count
            if s.priming { s.underruns += 1 }
            s.renders += 1
            s.ageTotalNS += age
            s.ageMaxNS = max(s.ageMaxNS, age)
            return frames
        } ?? 0
    }

    var statistics: String {
        state.withLock { s in
            let meanMS = s.renders == 0 ? 0 : s.ageTotalNS / UInt64(s.renders) / 1_000_000
            return "renders=\(s.renders) receiveToRenderMeanMS=\(meanMS) receiveToRenderMaxMS=\(s.ageMaxNS / 1_000_000) droppedFrames=\(s.overflow + s.stale) underruns=\(s.underruns) receivedFrames=\(s.written) playedFrames=\(s.played) staleFrames=\(s.stale) maxCallbackFrames=\(s.largestCallback) maxBurstFrames=\(s.peakQuantum) maxQueuedFrames=\(s.peakQueued) maxPacketGapMS=\(s.maxGapNS / 1_000_000)"
        }
    }
}
#endif
