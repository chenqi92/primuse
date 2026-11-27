import Foundation

public struct PEQFilter: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case peak = "PK", lowShelf = "LSC", highShelf = "HSC" }
    public var kind: Kind
    public var frequency: Double
    public var gain: Double
    public var q: Double
    public var enabled: Bool

    public init(kind: Kind, frequency: Double, gain: Double, q: Double, enabled: Bool = true) {
        self.kind = kind; self.frequency = frequency; self.gain = gain; self.q = q; self.enabled = enabled
    }

    public var isValid: Bool {
        frequency.isFinite && (10...96_000).contains(frequency)
            && gain.isFinite && (-30...30).contains(gain) && q.isFinite && (0.05...40).contains(q)
    }
}

public struct ParametricEQ: Codable, Hashable, Sendable {
    public static let maximumFilters = 16
    public var preamp: Double
    public var filters: [PEQFilter]
    public var source: String?

    public init(preamp: Double = 0, filters: [PEQFilter], source: String? = nil) {
        self.preamp = preamp; self.filters = filters; self.source = source
    }

    public var isValid: Bool {
        preamp.isFinite && (-60...30).contains(preamp) && !filters.isEmpty
            && filters.count <= Self.maximumFilters && filters.allSatisfy(\.isValid)
    }
}

public enum PEQImportError: Error, Equatable, Sendable {
    case tooLarge, empty, unsupportedLine(Int), invalidValue(Int), tooManyFilters
}

public enum EqualizerAPOParser {
    public static let maximumBytes = 65_536

    public static func parse(_ text: String) throws -> ParametricEQ {
        guard text.utf8.count <= maximumBytes else { throw PEQImportError.tooLarge }
        var preamp = 0.0
        var filters: [PEQFilter] = []
        let pattern = #"^Filter(?:\s+\d+)?:\s*(ON|OFF)\s+(PK|PEQ|LSC|HSC)\s+Fc\s+([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*Hz\s+Gain\s+([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*dB\s+Q\s+([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*$"#
        let filterExpression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let preampExpression = try NSRegularExpression(pattern: #"^Preamp:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*dB\s*$"#, options: .caseInsensitive)
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for (offset, raw) in lines.enumerated() {
            let line = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let match = preampExpression.firstMatch(in: line, range: range),
               let value = Double(ns.substring(with: match.range(at: 1))) {
                preamp += value
                guard preamp.isFinite, (-60...30).contains(preamp) else { throw PEQImportError.invalidValue(offset + 1) }
            } else if let match = filterExpression.firstMatch(in: line, range: range) {
                func group(_ index: Int) -> String { ns.substring(with: match.range(at: index)) }
                let type = group(2).uppercased()
                guard let kind = PEQFilter.Kind(rawValue: type == "PEQ" ? "PK" : type),
                      let frequency = Double(group(3)), let gain = Double(group(4)), let q = Double(group(5)) else {
                    throw PEQImportError.invalidValue(offset + 1)
                }
                let filter = PEQFilter(kind: kind, frequency: frequency, gain: gain, q: q, enabled: group(1).uppercased() == "ON")
                guard filter.isValid else { throw PEQImportError.invalidValue(offset + 1) }
                filters.append(filter)
                guard filters.count <= ParametricEQ.maximumFilters else { throw PEQImportError.tooManyFilters }
            } else {
                // Channel/Include/GraphicEQ commands change the meaning of a file; never partially import it.
                throw PEQImportError.unsupportedLine(offset + 1)
            }
        }
        guard !filters.isEmpty else { throw PEQImportError.empty }
        return ParametricEQ(preamp: preamp, filters: filters)
    }
}

public struct EQBiquad: Sendable, Equatable {
    public var b0: Double = 1
    public var b1: Double = 0
    public var b2: Double = 0
    public var a1: Double = 0
    public var a2: Double = 0

    public init() {}

    public init(filter: PEQFilter, sampleRate: Double) {
        guard filter.enabled, filter.gain != 0 else { return }
        let a = pow(10, filter.gain / 40)
        let w = 2 * Double.pi * filter.frequency / sampleRate
        let c = cos(w), alpha = sin(w) / (2 * filter.q)
        let a0: Double
        switch filter.kind {
        case .peak:
            a0 = 1 + alpha / a
            b0 = 1 + alpha * a; b1 = -2 * c; b2 = 1 - alpha * a
            a1 = -2 * c; a2 = 1 - alpha / a
        case .lowShelf:
            let t = 2 * sqrt(a) * alpha
            a0 = (a + 1) + (a - 1) * c + t
            b0 = a * ((a + 1) - (a - 1) * c + t)
            b1 = 2 * a * ((a - 1) - (a + 1) * c)
            b2 = a * ((a + 1) - (a - 1) * c - t)
            a1 = -2 * ((a - 1) + (a + 1) * c)
            a2 = (a + 1) + (a - 1) * c - t
        case .highShelf:
            let t = 2 * sqrt(a) * alpha
            a0 = (a + 1) - (a - 1) * c + t
            b0 = a * ((a + 1) + (a - 1) * c + t)
            b1 = -2 * a * ((a - 1) + (a + 1) * c)
            b2 = a * ((a + 1) + (a - 1) * c - t)
            a1 = 2 * ((a - 1) - (a + 1) * c)
            a2 = (a + 1) - (a - 1) * c - t
        }
        b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0
    }

    public func gainDB(frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c = cos(w), s = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let numerator = pow(b0 + b1 * c + b2 * c2, 2) + pow(b1 * s + b2 * s2, 2)
        let denominator = pow(1 + a1 * c + a2 * c2, 2) + pow(a1 * s + a2 * s2, 2)
        return 10 * log10(max(1e-30, numerator) / max(1e-30, denominator))
    }
}

public struct EQRenderConfiguration: Sendable, Equatable {
    public var filters: [EQBiquad]
    public var preampDB: Double
    public var linearGain: Double { pow(10, preampDB / 20) }
    public static let flat = EQRenderConfiguration(filters: [], preampDB: 0)

    public init(filters: [EQBiquad], preampDB: Double) { self.filters = filters; self.preampDB = preampDB }

    public static func make(preset: EQPreset, sampleRate: Double, enabled: Bool) -> EQRenderConfiguration? {
        guard enabled else { return .flat }
        guard sampleRate.isFinite, sampleRate >= 8_000, preset.isValid else { return nil }
        let filters: [EQBiquad]
        let requestedPreamp: Double
        if let peq = preset.parametric {
            guard peq.filters.filter(\.enabled).allSatisfy({ $0.frequency < sampleRate * 0.5 }) else { return nil }
            filters = peq.filters.filter(\.enabled).map { EQBiquad(filter: $0, sampleRate: sampleRate) }
            requestedPreamp = peq.preamp
        } else {
            filters = zip(preset.bands, PrimuseConstants.eqBandFrequencies).compactMap { gain, frequency in
                guard Double(frequency) < sampleRate * 0.5, gain != 0 else { return nil }
                let w = 2 * Double.pi * Double(frequency) / sampleRate
                let q = 1 / (2 * sinh(log(2) / 2 * Double(PrimuseConstants.eqDefaultBandwidth) * w / sin(w)))
                return EQBiquad(filter: PEQFilter(kind: .peak, frequency: Double(frequency), gain: Double(gain), q: q), sampleRate: sampleRate)
            }
            requestedPreamp = 0
        }
        let peak = preset.parametric == nil
            ? -Double(EqualizerHeadroomPolicy.preampDB(bandGainsDB: preset.bands,
                frequencies: PrimuseConstants.eqBandFrequencies,
                bandwidthOctaves: PrimuseConstants.eqDefaultBandwidth, sampleRate: sampleRate))
            : peakGainDB(filters: filters, sampleRate: sampleRate)
        // Retain a more conservative imported preamp instead of applying both attenuations.
        let safety = peak > 0.05 ? -peak - (preset.parametric == nil ? 0 : 1) : 0
        return EQRenderConfiguration(filters: filters, preampDB: min(0, requestedPreamp, safety))
    }

    public static func peakGainDB(filters: [EQBiquad], sampleRate: Double) -> Double {
        guard !filters.isEmpty else { return 0 }
        func response(_ f: Double) -> Double { filters.reduce(0) { $0 + $1.gainDB(frequency: f, sampleRate: sampleRate) } }
        // Scan the whole digital spectrum, including shelf plateaus, then refine each local maximum.
        let upper = sampleRate * 0.5
        var points = [0.0]
        var f = 1.0
        while f < upper { points.append(f); f *= pow(2, 1.0 / 192) }
        points.append(upper)
        let values = points.map(response)
        var peak = values.max() ?? 0
        for i in 1..<(points.count - 1) where values[i] >= values[i - 1] && values[i] >= values[i + 1] {
            var lo = points[i - 1], hi = points[i + 1]
            for _ in 0..<16 {
                let a = lo + (hi - lo) / 3, b = hi - (hi - lo) / 3
                if response(a) < response(b) { lo = a } else { hi = b }
            }
            peak = max(peak, response((lo + hi) / 2))
        }
        return peak
    }
}
