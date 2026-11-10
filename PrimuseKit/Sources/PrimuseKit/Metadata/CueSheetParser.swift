import CoreFoundation
import Foundation

public struct CueSheet: Equatable, Sendable {
    public var title: String?
    public var performer: String?
    public var songwriter: String?
    public var genre: String?
    public var year: Int?
    public var files: [CueFile]

    public init(
        title: String? = nil,
        performer: String? = nil,
        songwriter: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        files: [CueFile] = []
    ) {
        self.title = title
        self.performer = performer
        self.songwriter = songwriter
        self.genre = genre
        self.year = year
        self.files = files
    }
}

public struct CueFile: Equatable, Sendable {
    public var name: String
    public var type: String
    public var tracks: [CueTrack]

    public init(name: String, type: String, tracks: [CueTrack] = []) {
        self.name = name
        self.type = type
        self.tracks = tracks
    }
}

public struct CueTrack: Equatable, Sendable {
    public var number: Int
    public var type: String
    public var title: String?
    public var performer: String?
    public var songwriter: String?
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?
    public var isoAudioTrack: ISOAudioTrack?
    /// CUE 里用 REM 记的回放增益(foobar2000 等扫完增益后写进去的)。整轨文件的标签只有一份,
    /// 说不了每一轨各是多少,分轨的增益只有这里有。专辑那两项是整张的值,每一轨都带一份。
    public var replayGainTrackGain: Double?
    public var replayGainTrackPeak: Double?
    public var replayGainAlbumGain: Double?
    public var replayGainAlbumPeak: Double?
    public var identityKey: String { isoAudioTrack?.key ?? String(number) }

    public init(
        number: Int,
        type: String,
        title: String? = nil,
        performer: String? = nil,
        songwriter: String? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        isoAudioTrack: ISOAudioTrack? = nil
    ) {
        self.number = number
        self.type = type
        self.title = title
        self.performer = performer
        self.songwriter = songwriter
        self.startTime = startTime
        self.endTime = endTime
        self.isoAudioTrack = isoAudioTrack
    }
}

public extension CueSheet {
    /// SACD tracks have independent extracted timelines; an external CUE's whole-image
    /// offsets cannot split them. Their authoritative track list comes from the ISO itself.
    func filesForScanning(sheetFileName: String) -> [CueFile] {
        if (sheetFileName as NSString).pathExtension.lowercased() == "iso" { return files }
        return files.filter {
            ($0.name.replacingOccurrences(of: "\\", with: "/") as NSString).pathExtension.lowercased() != "iso"
        }
    }

    /// 按音频文件名(不分大小写;CUE 里带目录的写法只看最后一段)和起点找回一轨,
    /// 起点对不上时退回轨号。曲库里的轨号可能被刮削改过,起点不会。按 ID 寻址的网盘
    /// 上曲库里只有文件 ID、对不上名字,表里只有一个 FILE 时就是它。
    func track(audioFileName: String, startTime: TimeInterval?, number: Int?, imageTrackKey: String? = nil) -> CueTrack? {
        var matchedFiles = files.filter { file in
            let referenced = (file.name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            return referenced.caseInsensitiveCompare(audioFileName) == .orderedSame
        }
        if matchedFiles.isEmpty, files.count == 1 { matchedFiles = files }
        let tracks = matchedFiles
            .flatMap(\.tracks)
            .filter { $0.type == "AUDIO" && $0.startTime != nil }
        if let imageTrackKey { return tracks.first { $0.isoAudioTrack?.key == imageTrackKey } }
        if let startTime,
           let match = tracks.first(where: { abs(($0.startTime ?? -1) - startTime) < 0.01 }) {
            return match
        }
        guard let number else { return nil }
        return tracks.first { $0.number == number }
    }
}

/// 一轨在曲库里的身份,与扫描时建 CUE 分轨的写法一致:艺术家取这一轨的 PERFORMER,
/// 没有就用整张的;专辑艺术家取整张的 PERFORMER,没有就跟这一轨的艺术家。
/// CUE 里没写的就是空的(标题除外,由调用方给占位名)。
public struct CueTrackIdentity: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var albumTitle: String?
    public var albumArtist: String?
    public var trackNumber: Int
    public var genre: String?
    public var year: Int?

    public init(sheet: CueSheet, track: CueTrack) {
        title = Self.trimmedNonEmpty(track.title)
        artist = Self.trimmedNonEmpty(track.performer) ?? Self.trimmedNonEmpty(sheet.performer)
        albumTitle = Self.trimmedNonEmpty(track.isoAudioTrack?.albumTitle) ?? Self.trimmedNonEmpty(sheet.title)
        albumArtist = Self.trimmedNonEmpty(track.isoAudioTrack?.albumArtist) ?? Self.trimmedNonEmpty(sheet.performer) ?? artist
        trackNumber = track.number
        genre = Self.trimmedNonEmpty(sheet.genre)
        year = sheet.year
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Tolerant parser for the CDRWIN CUE subset used by music archives.
///
/// It deliberately ignores unknown directives while preserving the pieces a
/// library/player needs: FILE, TRACK AUDIO, TITLE/PERFORMER/SONGWRITER and
/// INDEX 01. UTF-8 (with or without BOM), UTF-16 and legacy GB18030 sheets are
/// accepted because Chinese NAS libraries commonly contain all three.
public enum CueSheetParser {
    public static func parse(data: Data) -> CueSheet? {
        guard let text = decode(data: data) else { return nil }
        return parse(text: text)
    }

    public static func parse(text: String) -> CueSheet? {
        var sheet = CueSheet()
        var currentFileIndex: Int?
        var currentTrackIndex: Int?
        var albumGain: Double?
        var albumPeak: Double?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let split = line.firstIndex(where: { $0.isWhitespace })
            let command = String(split.map { line[..<$0] } ?? Substring(line)).uppercased()
            let remainder = split.map {
                String(line[$0...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""

            switch command {
            case "FILE":
                guard let parsed = parseFile(remainder) else { continue }
                sheet.files.append(CueFile(name: parsed.name, type: parsed.type))
                currentFileIndex = sheet.files.count - 1
                currentTrackIndex = nil

            case "TRACK":
                guard let fileIndex = currentFileIndex else { continue }
                let fields = remainder.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 2, let number = Int(fields[0]) else { continue }
                sheet.files[fileIndex].tracks.append(
                    CueTrack(number: number, type: String(fields[1]).uppercased())
                )
                currentTrackIndex = sheet.files[fileIndex].tracks.count - 1

            case "TITLE", "PERFORMER", "SONGWRITER":
                let value = unquote(remainder)
                guard !value.isEmpty else { continue }
                if let fileIndex = currentFileIndex, let trackIndex = currentTrackIndex {
                    switch command {
                    case "TITLE": sheet.files[fileIndex].tracks[trackIndex].title = value
                    case "PERFORMER": sheet.files[fileIndex].tracks[trackIndex].performer = value
                    default: sheet.files[fileIndex].tracks[trackIndex].songwriter = value
                    }
                } else {
                    switch command {
                    case "TITLE": sheet.title = value
                    case "PERFORMER": sheet.performer = value
                    default: sheet.songwriter = value
                    }
                }

            case "INDEX":
                guard let fileIndex = currentFileIndex, let trackIndex = currentTrackIndex else { continue }
                let fields = remainder.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 2, fields[0] == "01",
                      let time = parseTime(String(fields[1])) else { continue }
                sheet.files[fileIndex].tracks[trackIndex].startTime = time

            case "REM":
                let fields = remainder.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard fields.count == 2 else { continue }
                let key = fields[0].uppercased()
                let value = unquote(String(fields[1]))
                if key == "GENRE", !value.isEmpty {
                    sheet.genre = value
                } else if key == "DATE" || key == "YEAR" {
                    sheet.year = Int(value.prefix(4))
                } else if key.hasPrefix("REPLAYGAIN_"), let number = replayGainNumber(value) {
                    // TRACK 之后的是这一轨的,之前的是整张的。
                    let track = currentFileIndex.flatMap { file in currentTrackIndex.map { (file, $0) } }
                    switch key {
                    case "REPLAYGAIN_ALBUM_GAIN": albumGain = number
                    case "REPLAYGAIN_ALBUM_PEAK": albumPeak = number
                    case "REPLAYGAIN_TRACK_GAIN":
                        if let (file, index) = track { sheet.files[file].tracks[index].replayGainTrackGain = number }
                    case "REPLAYGAIN_TRACK_PEAK":
                        if let (file, index) = track { sheet.files[file].tracks[index].replayGainTrackPeak = number }
                    default: break
                    }
                }

            default:
                continue
            }
        }

        // A track ends at the next INDEX 01 only when both entries refer to
        // the same physical FILE. The last track's end is filled from the
        // decoded image duration by the scanner.
        for fileIndex in sheet.files.indices {
            let trackIndices = sheet.files[fileIndex].tracks.indices
            for trackIndex in trackIndices {
                guard sheet.files[fileIndex].tracks[trackIndex].startTime != nil else { continue }
                sheet.files[fileIndex].tracks[trackIndex].endTime = trackIndices
                    .dropFirst(trackIndex + 1)
                    .lazy
                    .compactMap { sheet.files[fileIndex].tracks[$0].startTime }
                    .first
            }
        }

        if albumGain != nil || albumPeak != nil {
            for fileIndex in sheet.files.indices {
                for trackIndex in sheet.files[fileIndex].tracks.indices {
                    sheet.files[fileIndex].tracks[trackIndex].replayGainAlbumGain = albumGain
                    sheet.files[fileIndex].tracks[trackIndex].replayGainAlbumPeak = albumPeak
                }
            }
        }

        let hasPlayableTrack = sheet.files.contains { file in
            file.tracks.contains { $0.type == "AUDIO" && $0.startTime != nil }
        }
        return hasPlayableTrack ? sheet : nil
    }

    /// `-7.21 dB`、`+1.5`、`0.988812` 这类写法;增益限在常见范围内,写坏了的不要。
    static func replayGainNumber(_ value: String) -> Double? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix("db") { text = String(text.dropLast(2)) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(text), number.isFinite, (-60...60).contains(number) else { return nil }
        return number
    }

    public static func parseTime(_ value: String) -> TimeInterval? {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let minutes = Int(fields[0]),
              let seconds = Int(fields[1]),
              let frames = Int(fields[2]),
              minutes >= 0, (0..<60).contains(seconds), (0..<75).contains(frames) else {
            return nil
        }
        return Double(minutes * 60 + seconds) + Double(frames) / 75.0
    }

    private static func parseFile(_ value: String) -> (name: String, type: String)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.first == "\"" {
            var escaped = false
            var closingQuote: String.Index?
            var index = trimmed.index(after: trimmed.startIndex)
            while index < trimmed.endIndex {
                let character = trimmed[index]
                if character == "\"", !escaped {
                    closingQuote = index
                    break
                }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                index = trimmed.index(after: index)
            }
            guard let closingQuote else { return nil }
            let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingQuote])
                .replacingOccurrences(of: "\\\"", with: "\"")
            let type = trimmed[trimmed.index(after: closingQuote)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : (name, type.uppercased())
        }

        let fields = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2 else { return nil }
        return (fields.dropLast().joined(separator: " "), fields.last!.uppercased())
    }

    private static func unquote(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count >= 2, result.first == "\"", result.last == "\"" {
            result.removeFirst()
            result.removeLast()
        }
        return result.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func decode(data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if var utf8 = String(data: data, encoding: .utf8) {
            if utf8.first == "\u{FEFF}" { utf8.removeFirst() }
            return utf8
        }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: gb18030))
    }
}

public extension Song {
    /// 把 CUE 里记的回放增益放到这一轨上。CUE 没写的项不动。
    mutating func applyReplayGain(from track: CueTrack) {
        if let value = track.replayGainTrackGain { replayGainTrackGain = value }
        if let value = track.replayGainTrackPeak, value > 0 { replayGainTrackPeak = value }
        if let value = track.replayGainAlbumGain { replayGainAlbumGain = value }
        if let value = track.replayGainAlbumPeak, value > 0 { replayGainAlbumPeak = value }
    }
}
