import Foundation

public enum PrimuseConstants {
    public static let appGroupIdentifier = "group.com.welape.yuanyin"
    public static let playbackStateKey = "playbackState"
    public static let keychainServiceName = "com.welape.primuse.credentials"

    public static let eqBandFrequencies: [Float] = [
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]
    public static let eqBandCount = 10
    public static let eqMinGain: Float = -12.0
    public static let eqMaxGain: Float = 12.0
    public static let eqDefaultBandwidth: Float = 1.0

    public static let defaultCacheSizeBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB
    public static let smallFileThreshold: Int64 = 50 * 1024 * 1024 // 50 MB

    public static let supportedCoverExtensions = ["jpg", "jpeg", "png", "webp"]
    public static let supportedLyricsExtensions = ["lrc"]
    public static let folderCoverNames = ["cover", "folder", "album", "front", "artwork"]

    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "flac", "wav", "aiff", "aif", "alac",
        "ape", "dsf", "dff", "ogg", "opus", "wma", "wv"
    ]
}
