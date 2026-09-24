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
        receive(on: incoming, framer: KaraokeMicLink.Framer(), authenticated: false)
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
            return true
        case .reading(_, let midiNote):
            guard authenticated, incoming === connection else { return authenticated }
            if let midiNote, !(midiNote.isFinite && (20...110).contains(midiNote)) { return authenticated }
            onReading?(midiNote)
            return authenticated
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
#endif
