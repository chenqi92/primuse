import Foundation

/// AI 歌单交给智能服务挑歌的候选池。
///
/// 智能服务每次只看 100 首候选、挑出最多 30 首(旧版服务只看前 36 首、最多 12 首),
/// 所以歌单好不好几乎全看候选池。
/// 提示词多是心情、场景(「下雨天」「跑步」),按字面在歌名、艺人、专辑里搜不到几首;
/// 所以除了搜索结果,还按提示词提到的风格、年代从曲库里取歌,再放进常听艺人的歌和
/// 覆盖整个曲库的抽样,每位艺人限量,让服务真有得挑。
public enum AIPlaylistCandidatePoolPolicy {
    public static let poolSize = AIRecommendationRequest.maximumCandidates
    /// 搜索、风格、年代再多,也给常听艺人和全库抽样留这么多位置(约五分之一)。
    public static func reservedForBreadth(in limit: Int) -> Int {
        max(8, limit / 5)
    }
    /// 常听艺人那一路,每位艺人最多几首(连同前面已经放进池子的)。
    public static let tastePerArtist = 2

    /// - Parameters:
    ///   - matched: 和提示词直接相关的几路,每一路按相关程度排好(搜索结果、风格、年代)。轮流各取一首。
    ///   - taste: 常听艺人的歌。
    ///   - spread: 全库抽样。先只收池子里还没有的艺人。
    public static func compose(
        matched: [[String]],
        taste: [String],
        spread: [String],
        limit: Int = poolSize,
        artist: (String) -> String?
    ) -> [String] {
        guard limit > 0 else { return [] }
        var pool: [String] = []
        var seen = Set<String>()
        var artistCounts: [String: Int] = [:]

        func add(_ id: String) {
            pool.append(id)
            if let key = artist(id) { artistCounts[key, default: 0] += 1 }
        }

        let hasBreadth = !taste.isEmpty || !spread.isEmpty
        let matchedBudget = hasBreadth ? max(0, limit - reservedForBreadth(in: limit)) : limit
        var cursors = Array(repeating: 0, count: matched.count)
        var progressed = true
        while pool.count < matchedBudget, progressed {
            progressed = false
            for index in matched.indices where pool.count < matchedBudget {
                let list = matched[index]
                while cursors[index] < list.count {
                    let id = list[cursors[index]]
                    cursors[index] += 1
                    guard !id.isEmpty, seen.insert(id).inserted else { continue }
                    add(id)
                    progressed = true
                    break
                }
            }
        }

        var tasteLeft: [String] = []
        for id in taste where pool.count < limit {
            guard !id.isEmpty, !seen.contains(id) else { continue }
            if let key = artist(id), artistCounts[key, default: 0] >= tastePerArtist {
                tasteLeft.append(id)
                continue
            }
            seen.insert(id)
            add(id)
        }
        var spreadLeft: [String] = []
        for id in spread where pool.count < limit {
            guard !id.isEmpty, !seen.contains(id) else { continue }
            if let key = artist(id), artistCounts[key, default: 0] > 0 {
                spreadLeft.append(id)
                continue
            }
            seen.insert(id)
            add(id)
        }

        // 还不满:搜索那几路超出份额的接着放,再放被限量挡下的。
        for index in matched.indices {
            for id in matched[index].dropFirst(cursors[index]) where pool.count < limit {
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                add(id)
            }
        }
        for id in tasteLeft + spreadLeft where pool.count < limit {
            guard seen.insert(id).inserted else { continue }
            add(id)
        }
        return pool
    }
}

/// 从提示词里读出能直接对到曲库标签上的东西:风格和年代。
public enum AIPlaylistPromptHints {
    /// 中英文风格名对照。曲库的风格标签多是英文(「Rock」「Jazz」),提示词多是中文。
    /// 每组里任一写法出现在提示词里,就认这一组的全部写法。
    static let genreAliases: [[String]] = [
        ["流行", "pop"],
        ["摇滚", "搖滾", "rock"],
        ["爵士", "jazz"],
        ["民谣", "民謠", "folk"],
        ["电子", "電子", "electronic", "electronica", "edm", "electro"],
        ["嘻哈", "说唱", "說唱", "饶舌", "饒舌", "hiphop", "rap"],
        ["古典", "classical"],
        ["蓝调", "藍調", "布鲁斯", "blues"],
        ["乡村", "鄉村", "country"],
        ["金属", "金屬", "metal"],
        ["朋克", "龐克", "punk"],
        ["轻音乐", "輕音樂", "newage", "easylistening"],
        ["原声", "原聲", "配乐", "配樂", "影视", "影視", "soundtrack", "ost"],
        ["后摇", "後搖", "postrock"],
        ["独立", "獨立", "indie"],
        ["灵魂乐", "靈魂樂", "soul"],
        ["节奏布鲁斯", "rb", "rnb"],
        ["雷鬼", "reggae"],
        ["放克", "funk"],
        ["氛围", "氛圍", "ambient"],
        ["迪斯科", "disco"],
        ["拉丁", "latin"],
        ["世界音乐", "世界音樂", "worldmusic", "world"],
        ["儿歌", "兒歌", "children", "kids"],
        ["古风", "古風", "国风", "國風", "chinesetraditional"],
        ["粤语", "粵語", "cantopop"],
        ["华语", "華語", "国语", "國語", "mandopop", "cpop"],
        ["日语", "日語", "jpop"],
        ["韩语", "韓語", "kpop"],
        ["动漫", "動漫", "anime", "animesong"],
        ["钢琴", "鋼琴", "piano"],
        ["吉他", "guitar", "acoustic"],
        ["器乐", "器樂", "纯音乐", "純音樂", "instrumental"],
        ["舞曲", "dance"],
        ["硬核", "hardcore"],
        ["灵歌", "gospel"],
        ["歌剧", "歌劇", "opera"],
        ["大乐队", "bigband"],
        ["城市流行", "citypop"],
        ["低保真", "lofi"],
    ]

    /// 提示词与扩展词里提到的风格,对到曲库里实际有的风格名上。返回 `libraryGenres` 里命中的,原顺序。
    public static func matchingGenres(texts: [String], libraryGenres: [String]) -> [String] {
        let prompt = PromptText(texts)
        guard !prompt.isEmpty else { return [] }
        var wanted = Set<String>()
        for group in genreAliases {
            let keys = group.map(SongDiscoveryMatching.key)
            if keys.contains(where: prompt.mentions) { wanted.formUnion(keys) }
        }
        return libraryGenres.filter { genre in
            let key = SongDiscoveryMatching.key(genre)
            guard key.count >= 2 else { return false }
            if wanted.contains(key) { return true }
            // 「中国摇滚」「Punk Rock」:曲库风格名里带着想要的风格。
            if wanted.contains(where: { isDistinctiveInsideGenre($0) && key.contains($0) }) { return true }
            // 提示词原文里就写着这个风格名。
            return prompt.mentions(key)
        }
    }

    /// 曲库的风格名短而规整,里面带着「rock」「pop」就是这一类;再短的(「rb」)只认整个相等。
    static func isDistinctiveInsideGenre(_ key: String) -> Bool {
        key.unicodeScalars.allSatisfy(\.isASCII) ? key.count >= 3 : key.count >= 2
    }

    /// 提示词的两种读法:去掉标点空格的整串(中文按字串找),和拉丁字母的单词(英文按词找)。
    /// 「most relaxing」里有「ost」、「herb」里有「rb」,按字串找就会认错。
    struct PromptText {
        private var compact: [String] = []
        private var words = Set<String>()

        init(_ texts: [String]) {
            for text in texts {
                let key = SongDiscoveryMatching.key(text)
                if !key.isEmpty { compact.append(key) }
                let folded = text.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: nil
                )
                var runs: [String] = []
                var current = String.UnicodeScalarView()
                for scalar in folded.unicodeScalars {
                    if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                        current.append(scalar)
                    } else if !current.isEmpty {
                        runs.append(String(current))
                        current = String.UnicodeScalarView()
                    }
                }
                if !current.isEmpty { runs.append(String(current)) }
                words.formUnion(runs)
                // 「hip hop」「lo-fi」「r&b」「new age」拆成了两段,连起来再认一次。
                for (lhs, rhs) in zip(runs, runs.dropFirst()) { words.insert(lhs + rhs) }
            }
        }

        var isEmpty: Bool { compact.isEmpty }

        func mentions(_ key: String) -> Bool {
            guard !key.isEmpty else { return false }
            if key.unicodeScalars.allSatisfy(\.isASCII) {
                if words.contains(key) { return true }
                return key.count >= 6 && compact.contains { $0.contains(key) }
            }
            return key.count >= 2 && compact.contains { $0.contains(key) }
        }
    }

    private static let chineseDecades: [(String, Int)] = [
        ("五十年代", 1950), ("六十年代", 1960), ("七十年代", 1970), ("八十年代", 1980),
        ("九十年代", 1990), ("零零年代", 2000), ("一零年代", 2010), ("二零年代", 2020),
        ("七零年代", 1970), ("八零年代", 1980), ("九零年代", 1990),
    ]

    /// 「80年代」「八十年代」「90s」「1990s」「2000年代」这类说法对应的年份范围。
    public static func decades(in text: String) -> [ClosedRange<Int>] {
        var starts: [Int] = []
        func append(_ start: Int) {
            guard (1900...2090).contains(start), !starts.contains(start) else { return }
            starts.append(start)
        }
        for (word, start) in chineseDecades where text.contains(word) { append(start) }

        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard isDigit(scalars[index]) else { index += 1; continue }
            var end = index
            while end < scalars.count, isDigit(scalars[end]) { end += 1 }
            let digits = String(String.UnicodeScalarView(scalars[index..<end]))
            // 跳过数字后面的空格和撇号(「90 年代」「80's」)。
            var suffixStart = end
            while suffixStart < scalars.count,
                  scalars[suffixStart] == " " || scalars[suffixStart] == "'" || scalars[suffixStart] == "’" {
                suffixStart += 1
            }
            let suffix = String(String.UnicodeScalarView(scalars[suffixStart..<min(scalars.count, suffixStart + 2)]))
            if let value = Int(digits), digits.hasSuffix("0") {
                // 「90s」后面紧跟英文字母时不算(「80sec」)。
                let isDecadeWord = suffix.hasPrefix("年代")
                    || (suffix.lowercased().hasPrefix("s") && !isASCIILetter(at: suffixStart + 1, in: scalars))
                if isDecadeWord {
                    switch digits.count {
                    case 4: append(value)
                    case 2: append(value >= 30 ? 1900 + value : 2000 + value)
                    default: break
                    }
                }
            }
            index = end
        }
        return starts.map { $0...($0 + 9) }
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func isASCIILetter(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        guard scalars.indices.contains(index) else { return false }
        let scalar = scalars[index]
        return ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}
