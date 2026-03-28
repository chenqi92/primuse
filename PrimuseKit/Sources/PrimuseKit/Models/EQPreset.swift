import Foundation
import GRDB

public struct EQPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var bands: [Float] // 10 gain values, -12 to +12 dB
    public var isBuiltIn: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        bands: [Float],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bands = bands
        self.isBuiltIn = isBuiltIn
    }

    public var localizedName: String {
        if isBuiltIn {
            return EQPreset.localizedNames[id] ?? name
        }
        return name
    }

    private static let localizedNames: [String: String] = {
        if Locale.current.language.languageCode?.identifier == "zh" {
            return [
                "flat": "平坦",
                "bass": "低音增强",
                "treble": "高音增强",
                "vocal": "人声",
                "jazz": "爵士",
                "rock": "摇滚",
                "dance": "舞曲",
                "classical": "古典",
                "hiphop": "嘻哈",
                "latenight": "深夜",
            ]
        }
        return [
            "flat": "Flat",
            "bass": "Bass",
            "treble": "Treble",
            "vocal": "Vocal",
            "jazz": "Jazz",
            "rock": "Rock",
            "dance": "Dance",
            "classical": "Classical",
            "hiphop": "Hip-Hop",
            "latenight": "Late Night",
        ]
    }()

    public static let flat = EQPreset(
        id: "flat", name: "Flat",
        bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        isBuiltIn: true
    )

    public static let bass = EQPreset(
        id: "bass", name: "Bass",
        bands: [6, 5, 4, 3, 1, 0, 0, 0, 0, 0],
        isBuiltIn: true
    )

    public static let treble = EQPreset(
        id: "treble", name: "Treble",
        bands: [0, 0, 0, 0, 0, 1, 3, 4, 5, 6],
        isBuiltIn: true
    )

    public static let vocal = EQPreset(
        id: "vocal", name: "Vocal",
        bands: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1],
        isBuiltIn: true
    )

    public static let jazz = EQPreset(
        id: "jazz", name: "Jazz",
        bands: [4, 3, 1, 2, -2, -2, 0, 1, 3, 4],
        isBuiltIn: true
    )

    public static let rock = EQPreset(
        id: "rock", name: "Rock",
        bands: [5, 4, 3, 1, -1, -1, 0, 2, 4, 5],
        isBuiltIn: true
    )

    public static let dance = EQPreset(
        id: "dance", name: "Dance",
        bands: [6, 5, 2, 0, 0, -2, -1, 0, 4, 5],
        isBuiltIn: true
    )

    public static let classical = EQPreset(
        id: "classical", name: "Classical",
        bands: [5, 4, 3, 2, -1, -1, 0, 2, 3, 4],
        isBuiltIn: true
    )

    public static let hiphop = EQPreset(
        id: "hiphop", name: "Hip-Hop",
        bands: [5, 4, 1, 3, -1, -1, 1, 0, 2, 3],
        isBuiltIn: true
    )

    public static let lateNight = EQPreset(
        id: "latenight", name: "Late Night",
        bands: [3, 2, 1, 0, -1, 0, 1, 2, 3, 3],
        isBuiltIn: true
    )

    public static let builtInPresets: [EQPreset] = [
        .flat, .bass, .treble, .vocal, .jazz, .rock, .dance, .classical, .hiphop, .lateNight
    ]
}

extension EQPreset: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "eqPresets" }
}
