import Foundation

/// The link between an Apple TV karaoke stage and an iPhone used as the
/// singing microphone. The phone only sends what it hears as pitch; the
/// voice itself is never streamed, so network and TV output latency cannot
/// turn into an echo in the room.
public enum KaraokeMicLink {
    public static let scheme = "primuse"
    public static let host = "karaoke-mic"
    public static let protocolVersion = 1

    public struct Endpoint: Equatable, Sendable {
        public var host: String
        public var port: UInt16
        /// Shared secret shown only in the TV's QR code.
        public var key: String

        public init(host: String, port: UInt16, key: String) {
            self.host = host
            self.port = port
            self.key = key
        }

        public var url: URL {
            var components = URLComponents()
            components.scheme = KaraokeMicLink.scheme
            components.host = KaraokeMicLink.host
            components.queryItems = [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "port", value: String(port)),
                URLQueryItem(name: "k", value: key),
            ]
            return components.url!
        }

        public init?(url: URL) {
            guard url.scheme == KaraokeMicLink.scheme,
                  url.host == KaraokeMicLink.host,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
            }
            guard let host = value("host"),
                  let port = value("port").flatMap(UInt16.init),
                  port > 0,
                  let key = value("k"),
                  key.count >= 16 else { return nil }
            self.init(host: host, port: port, key: key)
        }
    }

    /// Phone → TV.
    public enum PhoneMessage: Equatable, Sendable, Codable {
        case hello(version: Int, key: String, deviceName: String)
        /// One analysis step: sung MIDI note, or nil for silence.
        case reading(sequence: Int, midiNote: Double?)
        /// The phone is separating the TV's song with the AI model.
        case separationProgress(songID: String, fraction: Double)
        /// First line of a separate connection that then carries
        /// `byteCount` bytes of a `KaraokeStemFile` for `songID`.
        case stemUpload(key: String, songID: String, byteCount: Int)
        case goodbye
    }

    /// TV → phone.
    public enum TVMessage: Equatable, Sendable, Codable {
        case accepted(songTitle: String)
        case rejected
        case status(songTitle: String, isPlaying: Bool, score: Int?)
        /// The TV's current song, so the phone can provide its AI vocal.
        case nowPlaying(songID: String?)
        case stemReceived(songID: String)
    }

    /// Largest vocal stem the TV accepts (about 15 minutes at 48 kHz).
    public static let maximumStemBytes = 200_000_000

    public static func encode<T: Encodable>(_ message: T) -> Data {
        var data = (try? JSONEncoder().encode(message)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Splits a byte stream into newline-delimited messages. Oversized or
    /// malformed lines are dropped so a bad peer cannot grow memory.
    public struct Framer: Sendable {
        public static let maximumLineLength = 4_096
        private var buffer = Data()

        public init() {}

        public mutating func append<T: Decodable>(_ data: Data, as type: T.Type) -> [T] {
            buffer.append(data)
            var messages: [T] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let message = try? JSONDecoder().decode(T.self, from: Data(line)) {
                    messages.append(message)
                }
            }
            if buffer.count > Self.maximumLineLength {
                buffer.removeAll()
            }
            return messages
        }

        /// Bytes received after the last complete line: the start of a raw
        /// payload that follows a header line.
        public mutating func takeRemainder() -> Data {
            defer { buffer.removeAll() }
            return buffer
        }

        /// Like `append(_:as:)` but stops after the first message, leaving
        /// everything after it for `takeRemainder()`.
        public mutating func firstMessage<T: Decodable>(_ data: Data, as type: T.Type) -> T? {
            buffer.append(data)
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                if buffer.count > Self.maximumLineLength { buffer.removeAll() }
                return nil
            }
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            buffer = Data(buffer)
            return try? JSONDecoder().decode(T.self, from: Data(line))
        }
    }

    /// A random key for the QR code.
    public static func makeKey() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<24).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
    }
}

/// Works out how far behind the song the singer's readings arrive: the TV's
/// output delay (HDMI, soundbars) plus the phone's capture and network time.
/// The lag that makes the sung notes agree best with the reference melody
/// wins; until enough singing has been heard, a typical value is used.
public struct KaraokeLagEstimator: Sendable {
    public static let candidates: [TimeInterval] = stride(from: 0.0, through: 0.6, by: 0.02).map { $0 }
    public static let defaultLag: TimeInterval = 0.18
    /// Readings with both a sung and a reference note needed before the
    /// estimate is trusted.
    public static let minimumMatches = 40

    private struct Reading: Sendable {
        var time: TimeInterval
        var midiNote: Double
    }

    private var readings: [Reading] = []
    public private(set) var lag: TimeInterval = defaultLag
    public private(set) var isCalibrated = false

    public init() {}

    /// Adds a sung reading received at song time `time`.
    public mutating func record(time: TimeInterval, sung midiNote: Double?) {
        // A backwards seek: earlier readings now overlap the new timeline.
        if let last = readings.last, time < last.time - 0.5 {
            readings.removeAll()
        }
        guard let midiNote else { return }
        readings.append(Reading(time: time, midiNote: midiNote))
        if readings.count > 600 { readings.removeFirst(readings.count - 600) }
    }

    /// Re-estimates the lag against the reference readings so far.
    public mutating func update(reference: KaraokePitchTrack) {
        var bestLag = lag
        var bestScore = -1.0
        var bestMatches = 0
        for candidate in Self.candidates {
            var total = 0.0
            var matches = 0
            for reading in readings {
                guard let target = reference.reading(at: reading.time - candidate, tolerance: 0.03) else { continue }
                // Singing over a rest in the melody is a mismatch too: it is
                // what pins the lag down at note starts and ends.
                if let note = target.midiNote {
                    total += KaraokeScorer.pitchAccuracy(sung: reading.midiNote, reference: note)
                }
                matches += 1
            }
            guard matches >= Self.minimumMatches else { continue }
            let score = total / Double(matches)
            if score > bestScore + 0.01 || (abs(score - bestScore) <= 0.01 && abs(candidate - Self.defaultLag) < abs(bestLag - Self.defaultLag)) {
                bestScore = score
                bestLag = candidate
                bestMatches = matches
            }
        }
        if bestMatches >= Self.minimumMatches {
            lag = bestLag
            isCalibrated = true
        }
    }

    public mutating func reset() {
        readings.removeAll()
        lag = Self.defaultLag
        isCalibrated = false
    }
}
