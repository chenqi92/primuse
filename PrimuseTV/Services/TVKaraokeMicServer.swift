#if os(tvOS)
import Foundation
import Network
import Observation
import PrimuseKit

/// Lets one iPhone join the karaoke stage as the singing microphone. The
/// phone connects to the address and key in the stage's QR code and sends
/// pitch readings; nothing else is accepted.
@MainActor
@Observable
final class TVKaraokeMicServer {
    enum State: Equatable {
        case idle
        case listening(KaraokeMicLink.Endpoint)
        case connected(deviceName: String, endpoint: KaraokeMicLink.Endpoint)
        case failed
    }

    private(set) var state: State = .idle
    /// Called on the main actor for every reading from the connected phone.
    @ObservationIgnored var onReading: (@MainActor (Double?) -> Void)?
    /// A complete AI vocal stem file uploaded by the phone.
    @ObservationIgnored var onStem: (@MainActor (String, Data) -> Void)?
    /// The phone's AI separation progress for a song.
    @ObservationIgnored var onSeparationProgress: (@MainActor (String, Double) -> Void)?
    @ObservationIgnored private var lastNowPlaying: String??

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var key = KaraokeMicLink.makeKey()
    private let queue = DispatchQueue(label: "primuse.tv.karaoke-mic")

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
            listener.stateUpdateHandler = { [weak self] update in
                Task { @MainActor [weak self] in self?.listenerChanged(update) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            plog("⚠️ TV karaoke mic: listener failed: \(error.localizedDescription)")
            state = .failed
        }
    }

    func stop() {
        if let connection {
            connection.send(content: KaraokeMicLink.encode(KaraokeMicLink.TVMessage.rejected), completion: .idempotent)
            connection.cancel()
        }
        connection = nil
        listener?.cancel()
        listener = nil
        state = .idle
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
        incoming.start(queue: queue)
        receiveFirst(on: incoming, framer: KaraokeMicLink.Framer())
    }

    /// The first line decides what the connection is: the phone's control
    /// channel or a one-off stem upload.
    private func receiveFirst(on incoming: NWConnection, framer: KaraokeMicLink.Framer) {
        incoming.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var framer = framer
                if let data, let first = framer.firstMessage(data, as: KaraokeMicLink.PhoneMessage.self) {
                    if case .stemUpload(let offeredKey, let songID, let byteCount) = first {
                        guard offeredKey == self.key,
                              byteCount > 0,
                              byteCount <= KaraokeMicLink.maximumStemBytes else {
                            incoming.cancel()
                            return
                        }
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
                if let data { payload.data.append(data) }
                if payload.data.count < expected, isComplete || error != nil {
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
            if let connection, connection !== incoming { connection.cancel() }
            connection = incoming
            state = .connected(deviceName: String(deviceName.prefix(40)), endpoint: endpoint)
            incoming.send(content: KaraokeMicLink.encode(KaraokeMicLink.TVMessage.accepted(songTitle: "")), completion: .idempotent)
            if case .some(let songID) = lastNowPlaying {
                incoming.send(content: KaraokeMicLink.encode(KaraokeMicLink.TVMessage.nowPlaying(songID: songID)), completion: .idempotent)
            }
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
        guard incoming === connection else { return }
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
#endif
