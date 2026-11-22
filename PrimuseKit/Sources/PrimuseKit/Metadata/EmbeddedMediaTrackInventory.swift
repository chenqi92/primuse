import Foundation

/// Audio ordinals count only audio streams, in demuxer order, including disabled NI stems.
public struct EmbeddedMediaTrackInventory: Codable, Hashable, Sendable {
    public struct AudioTrack: Codable, Hashable, Sendable {
        public let ordinal: Int
        public let name: String?
        public let stemName: String?
        public let isDefault: Bool
        public var isInstrumental: Bool { EmbeddedMediaTrackInventory.instrumentalLabel(name) || EmbeddedMediaTrackInventory.instrumentalLabel(stemName) }
        public var isVocalStem: Bool {
            guard let stemName else { return false }
            let label = EmbeddedMediaTrackInventory.label(stemName)
            return !EmbeddedMediaTrackInventory.instrumentalLabel(stemName)
                && (["vocal", "vocals", "voice", "voices", "acapella", "a cappella", "vox", "gesang", "voix", "voce"].contains { label.contains(" " + $0 + " ") }
                    || ["人声", "人聲", "主唱", "和声", "和聲", "ボーカル"].contains(where: label.contains))
        }

        public init(ordinal: Int, name: String? = nil, stemName: String? = nil, isDefault: Bool = false) {
            self.ordinal = ordinal
            self.name = EmbeddedMediaTrackInventory.cleanName(name)
            self.stemName = EmbeddedMediaTrackInventory.cleanName(stemName)
            self.isDefault = isDefault
        }
    }

    public let audioTracks: [AudioTrack]
    public let hasVideo: Bool
    public var instrumentalTracks: [AudioTrack] { audioTracks.filter(\.isInstrumental) }
    public var stemTracks: [AudioTrack] { audioTracks.filter { $0.stemName != nil } }
    public var originalTrack: AudioTrack? {
        let complete = audioTracks.filter { $0.stemName == nil && !$0.isInstrumental }
        if !stemTracks.isEmpty { return complete.first { $0.ordinal == 0 } }
        let named = complete.first { track in
            let value = Self.label(track.name)
            return ["original", "full mix", "main mix", "master", "original mix"].contains { value.contains(" " + $0 + " ") }
                || ["原唱", "原声", "原聲", "原曲"].contains(where: value.contains)
        }
        return named ?? complete.first(where: \.isDefault) ?? complete.first
    }

    public init(audioTracks: [AudioTrack], hasVideo: Bool) {
        self.audioTracks = audioTracks
        self.hasVideo = hasVideo
    }

    private static let isoExtensions: Set<String> = ["mp4", "m4a", "m4v", "m4b", "mov", "alac", "m4r", "3gp", "3g2"]
    private static let matroskaExtensions: Set<String> = ["mka", "mkv", "webm", "weba"]
    public static func supports(fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        return isoExtensions.contains(ext) || matroskaExtensions.contains(ext)
    }
    public static func supports(_ song: Song) -> Bool {
        switch song.fileFormat {
        case .mp4, .m4a, .m4v, .mov, .alac, .mka, .webm: return true
        default: return song.filePath.utf8.suffix(4).lazy.map { $0 | 0x20 }.elementsEqual(".mkv".utf8)
        }
    }

    public static func sameMediaFile(_ lhs: Song, _ rhs: Song) -> Bool {
        lhs.id == rhs.id && lhs.sourceID == rhs.sourceID && lhs.filePath == rhs.filePath
            && lhs.fileSize == rhs.fileSize && lhs.revision == rhs.revision && lhs.lastModified == rhs.lastModified
    }

    public static func supportsCatalogOriginal(_ type: MusicSourceType) -> Bool {
        type.isSubsonicFamily || [.jellyfin, .emby, .plex, .songloft, .fnMusic, .synologyAudioStation].contains(type)
    }

    public static func isStemFileName(_ name: String) -> Bool {
        name.utf8.suffix(9).lazy.map { $0 | 0x20 }.elementsEqual(".stem.mp4".utf8)
    }

    public static func inspect(at url: URL, fileExtension: String? = nil) async -> Self? {
        let ext = fileExtension ?? url.pathExtension
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = Int64(clamping: try handle.seekToEnd())
            try handle.seek(toOffset: 0)
            let head = try handle.read(upToCount: Int(min(size, 8192))) ?? Data()
            return try await inspect(head: head, fileSize: size, fileExtension: ext) { start, count in
                try handle.seek(toOffset: UInt64(start))
                return try handle.read(upToCount: Int(count)) ?? Data()
            }
        } catch { return nil }
    }

    public static func inspect(head: Data, fileSize: Int64, fileExtension: String,
                               fetch: @escaping EmbeddedMediaLyricReader.RangeFetch) async throws -> Self? {
        guard fileSize > 0 else { return nil }
        if head.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) {
            return try await MatroskaLyricReader(head: head, fileSize: fileSize, fetch: fetch).inventory()
        }
        if let inventory = isoBaseMedia(in: head) { return inventory }
        let namedISO = isoExtensions.contains(fileExtension.lowercased())
        let signature = head.dropFirst(4).prefix(4).elementsEqual("ftyp".utf8)
        guard namedISO || signature, let moov = try await ISOBaseMediaRangeReader.read(head: head, fileSize: fileSize, fetch: fetch) else { return nil }
        return isoBaseMedia(in: moov)
    }

    public static func inspect(fileSize: Int64, fileExtension: String,
                               fetch: @escaping EmbeddedMediaLyricReader.RangeFetch) async throws -> Self? {
        guard fileSize > 0 else { return nil }
        let head = try await fetch(0, min(fileSize, 8192))
        return try await inspect(head: head, fileSize: fileSize, fileExtension: fileExtension, fetch: fetch)
    }

    public static func isoBaseMedia(in data: Data) -> Self? { ISOBaseMediaChapterParser.trackInventory(in: data) }

    static func cleanName(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)), !name.isEmpty else { return nil }
        let basic = ["soundhandler", "videohandler", "core media audio", "core media video"]
        return basic.contains(name.lowercased()) ? nil : name
    }

    static func label(_ value: String?) -> String {
        let folded = (value ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return " " + folded.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
    }

    static func instrumentalLabel(_ name: String?) -> Bool {
        let text = label(name)
        if ["commentary", "guide vocal", "with vocals", "karaoke guide"].contains(where: text.contains) { return false }
        return ["instrumental", "karaoke", "accompaniment", "backing track", "backing only", "minus one",
                "no vocal", "no vocals", "without vocals", "off vocal", "music only", "accompagnement", "伴奏", "カラオケ"]
            .contains { text.contains(" " + $0 + " ") }
            || ["伴奏", "无人声", "無人聲", "カラオケ"].contains(where: text.contains)
    }

    static func isArtworkName(_ name: String?) -> Bool {
        let text = label(name)
        return ["cover art", "album cover", "front cover", "thumbnail", "thumbnails", "chapter art", "chapter image", "album artwork", "attached picture"]
            .contains { text.contains(" " + $0 + " ") }
            || ["cover", "poster", "artwork", "jacket"].contains(text.trimmingCharacters(in: .whitespaces))
            || ["封面", "缩略图", "縮圖", "章節圖片", "章节图片"].contains(where: text.contains)
    }
}
