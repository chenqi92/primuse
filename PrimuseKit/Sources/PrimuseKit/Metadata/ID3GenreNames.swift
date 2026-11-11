import Foundation

/// ID3 的 TCON 帧（以及 MP4 的 `gnre` 编号）里流派的几种老写法，统一成一个个流派名。
///
/// - ID3v2.4 的多个流派用 NUL 隔开：`Rock\0Pop`
/// - ID3v2.3 用括号里的编号引用 ID3v1 流派表，后面可跟细分文字：`(17)`、`(17)(13)`、`(17)Rock`、`(4)Eurodisco`
/// - `(RX)`、`(CR)` 分别是 Remix、Cover；`((` 开头是转义过的普通括号
/// - ID3v2.4 允许只写编号：`17`
///
/// 斜杠不在这里处理：它算不算分隔符要看用户设置和文件格式，见 `GenreSlashConvention`。
public enum ID3GenreNames {
    /// ID3v1 与 Winamp 扩展的 0...191 号流派。个别历史拼写按现在通行的写法改正
    /// （AlternRock、Psychadelic、Bebob、A capella、Native US），133 号用 Afro-Punk。
    public static let standard: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
        "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap",
        "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
        "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance",
        "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
        "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
        "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi",
        "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin", "Revival",
        "Celtic", "Bluegrass", "Avant-garde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock",
        "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera",
        "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam",
        "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
        "Duet", "Punk Rock", "Drum Solo", "A Cappella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass",
        "Club-House", "Hardcore Techno", "Terror", "Indie", "BritPop", "Afro-Punk", "Polsk Punk", "Beat",
        "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover", "Contemporary Christian", "Christian Rock", "Merengue", "Salsa",
        "Thrash Metal", "Anime", "J-Pop", "Synthpop", "Abstract", "Art Rock", "Baroque", "Bhangra",
        "Big Beat", "Breakbeat", "Chillout", "Downtempo", "Dub", "EBM", "Eclectic", "Electro",
        "Electroclash", "Emo", "Experimental", "Garage", "Global", "IDM", "Illbient", "Industro-Goth",
        "Jam Band", "Krautrock", "Leftfield", "Lounge", "Math Rock", "New Romantic", "Nu-Breakz", "Post-Punk",
        "Post-Rock", "Psytrance", "Shoegaze", "Space Rock", "Trop Rock", "World Music", "Neoclassical", "Audiobook",
        "Audio Theatre", "Neue Deutsche Welle", "Podcast", "Indie Rock", "G-Funk", "Dubstep", "Garage Rock", "Psybient",
    ]

    /// ID3v1 编号（0 起）对应的流派名；表外的编号返回 nil。
    public static func name(forIndex index: Int) -> String? {
        standard.indices.contains(index) ? standard[index] : nil
    }

    /// MP4 `gnre` 存的是 ID3v1 编号加一。
    public static func name(forMP4GenreCode code: Int) -> String? {
        name(forIndex: code - 1)
    }

    /// TCON 的值拆成流派名，去重后按出现先后排。认不出的写法原样当一个流派名。
    public static func names(fromTCON value: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func append(_ candidate: String) {
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  seen.insert(LibraryGenreIndexBuilder.normalizedID(for: name)).inserted else { return }
            result.append(name)
        }

        for rawValue in value.split(separator: "\0", omittingEmptySubsequences: true) {
            var rest = Substring(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !rest.isEmpty else { continue }

            if rest.allSatisfy({ $0.isASCII && $0.isNumber }) {
                append(Int(rest).flatMap(name(forIndex:)) ?? String(rest))
                continue
            }

            var references: [String] = []
            while rest.hasPrefix("("), !rest.hasPrefix("(("),
                  let close = rest.firstIndex(of: ")") {
                let token = rest[rest.index(after: rest.startIndex)..<close]
                let resolved: String?
                switch token {
                case "RX": resolved = "Remix"
                case "CR": resolved = "Cover"
                default:
                    resolved = token.allSatisfy({ $0.isASCII && $0.isNumber })
                        ? Int(token).flatMap(name(forIndex:))
                        : nil
                }
                // 括号里不是编号（比如「(Live) Rock」）：剩下的整段都是文字。
                guard let resolved else { break }
                references.append(resolved)
                rest = rest[rest.index(after: close)...]
            }
            if rest.hasPrefix("((") { rest = rest.dropFirst() }

            references.forEach(append)
            append(String(rest))
        }
        return result
    }

    /// TCON 的值整理成歌曲里存的样子：多个流派用「; 」连起来。
    public static func normalizedTCON(_ value: String?) -> String? {
        guard let value else { return nil }
        let names = names(fromTCON: value)
        return names.isEmpty ? nil : names.joined(separator: "; ")
    }
}
