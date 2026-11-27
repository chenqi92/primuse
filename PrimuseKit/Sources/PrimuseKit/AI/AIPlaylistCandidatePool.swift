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

extension AIPlaylistCandidatePoolPolicy {
    private struct Sample {
        let hash: UInt64
        let position: Int

        static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
            lhs.hash == rhs.hash ? lhs.position < rhs.position : lhs.hash < rhs.hash
        }
    }

    public static func songs(
        in songs: [Song], texts: [String], searchIDs: [String], topArtists: [String],
        topSongIDs: [String], salt: UInt64, limit requested: Int, excluding: Set<String> = [],
        excludedPathsBySource: [String: Set<String>] = [:],
        isCancelled: () -> Bool = { false }
    ) -> [Song] {
        let limit = min(requested, poolSize)
        guard limit > 0, !songs.isEmpty, !isCancelled() else { return [] }
        let genreMatches = AIPlaylistPromptHints.genreMatcher(texts)
        let decades = AIPlaylistPromptHints.decades(in: texts.joined(separator: " "))
        let artists = Set(topArtists.compactMap(SongRadioGrouping.artistKey))
        let requestedIDs = Set(searchIDs).union(topSongIDs)
        var positions: [String: Int] = [:]
        // Keep the same six choices per slot before applying the per-artist quotas.
        var genre = TopKBuffer<Sample>(limit: limit * 6, by: Sample.precedes)
        var decade = genre, taste = genre
        var spread = TopKBuffer<Sample>(limit: limit * 4 * 6, by: Sample.precedes)
        do {
            var seen = Set<String>()
            var genreMatchesByRaw: [String: Bool] = [:]
            var artistMatchesByRaw: [String: Bool] = [:]
            func matches(_ raw: String, cache: inout [String: Bool], evaluate: (String) -> Bool) -> Bool {
                if let hit = cache[raw] { return hit }
                let hit = evaluate(raw)
                if cache.count == 32_768 { cache.removeAll(keepingCapacity: true) }
                cache[raw] = hit
                return hit
            }
            for (position, song) in songs.enumerated() {
                if position.isMultiple(of: 256), isCancelled() { return [] }
                guard !song.id.isEmpty, song.isPlayable, !excluding.contains(song.id),
                      excludedPathsBySource[song.sourceID]?.contains(song.filePath) != true,
                      seen.insert(song.id).inserted else { continue }
                if requestedIDs.contains(song.id) { positions[song.id] = position }
                let sample = Sample(hash: stableHash(song.id, salt: salt), position: position)
                spread.insert(sample)
                if let raw = song.genre, matches(raw, cache: &genreMatchesByRaw, evaluate: {
                    SongDiscoveryMatching.genreNames($0).contains(where: genreMatches)
                }) {
                    genre.insert(sample)
                }
                if let year = song.year, decades.contains(where: { $0.contains(year) }) { decade.insert(sample) }
                if !artists.isEmpty, let raw = song.artistName, matches(raw, cache: &artistMatchesByRaw, evaluate: {
                    SongRadioGrouping.artistKey($0).map(artists.contains) == true
                }) {
                    taste.insert(sample)
                }
            }
        }
        guard !isCancelled() else { return [] }
        var artistKeys: [Int: String?] = [:]
        func artist(at position: Int) -> String? {
            if let key = artistKeys[position] { return key }
            let key = SongRadioGrouping.artistKey(songs[position].artistName)
            artistKeys[position] = .some(key)
            return key
        }
        func sample(_ ranked: TopKBuffer<Sample>, count: Int, perArtist: Int) -> [String] {
            var counts: [String: Int] = [:]
            var ids: [String] = []
            for row in ranked.sorted() {
                if let key = artist(at: row.position) {
                    guard counts[key, default: 0] < perArtist else { continue }
                    counts[key, default: 0] += 1
                }
                let id = songs[row.position].id
                positions[id] = row.position
                ids.append(id)
                if ids.count == count { break }
            }
            return ids
        }

        let favoriteIDs = topSongIDs.filter { positions[$0] != nil }.sorted {
            stableHash($0, salt: salt) < stableHash($1, salt: salt)
        }
        let matched = [searchIDs.filter { positions[$0] != nil },
                       sample(genre, count: limit, perArtist: 2), sample(decade, count: limit, perArtist: 2)]
        let favorites = interleave(favoriteIDs, sample(taste, count: limit, perArtist: tastePerArtist))
        let breadth = sample(spread, count: limit * 4, perArtist: 1)
        let ids = compose(matched: matched, taste: favorites, spread: breadth, limit: limit,
                          artist: { id in positions[id].flatMap { artist(at: $0) } })
        var result = ids.compactMap { id in positions[id].map { songs[$0] } }
        // A small number of artists can exhaust the diversity slots while the library
        // still has plenty of playable candidates for the service to choose from.
        if result.count < limit {
            var used = Set(ids)
            for sample in spread.sorted() {
                let song = songs[sample.position]
                if used.insert(song.id).inserted { result.append(song) }
                if result.count == limit { break }
            }
        }
        return isCancelled() ? [] : result
    }

    /// Build the ranking input from exact hits, the library's genre and artist indexes, and a
    /// sample spread across the entire music library. Only an explicit decade needs the year column.
    public static func indexedCandidates(
        in songs: [Song], texts: [String], searchIDs: [String], topArtists: [String],
        topSongIDs: [String], genreGroups: [[String]], artistGroups: [[String]],
        lookup: (String) -> Song?, excluding: Set<String>, salt: UInt64, limit requested: Int,
        excludedPathsBySource: [String: Set<String>] = [:],
        isCancelled: () -> Bool = { false }
    ) -> [Song] {
        let limit = min(requested, poolSize)
        guard limit > 0, !isCancelled() else { return [] }
        var rng = ListeningSeededGenerator(seed: salt)
        var input: [Song] = []
        var seen = Set<String>()
        func eligible(_ song: Song) -> Bool {
            !song.id.isEmpty && song.isPlayable && !excluding.contains(song.id)
                && excludedPathsBySource[song.sourceID]?.contains(song.filePath) != true
        }
        @discardableResult func include(_ song: Song?) -> Bool {
            guard let song, eligible(song) else { return false }
            if seen.insert(song.id).inserted { input.append(song) }
            return true
        }
        for id in searchIDs + topSongIDs where !excluding.contains(id) { include(lookup(id)) }

        // A step coprime to count visits every offset exactly once, even when almost every
        // song is excluded. It needs no shuffled copy or set of visited library positions.
        func sample(count: Int, budget: Int, visit: (Int) -> Bool) {
            guard count > 0, budget > 0 else { return }
            var step = Int.random(in: 1...count, using: &rng)
            while true {
                var a = count, b = step
                while b != 0 { (a, b) = (b, a % b) }
                if a == 1 { break }
                step = step == count ? 1 : step + 1
            }
            var position = Int.random(in: 0..<count, using: &rng)
            var accepted = 0
            for offset in 0..<count {
                if offset.isMultiple(of: 256), isCancelled() { return }
                if visit(position) {
                    accepted += 1
                    if accepted == budget { return }
                }
                position = (position + step) % count
            }
        }
        func sampleGroups(_ groups: [[String]]) {
            var remaining = limit * 6
            for (index, ids) in groups.enumerated() {
                guard remaining > 0, !isCancelled() else { return }
                let left = groups.count - index
                sample(count: ids.count, budget: (remaining + left - 1) / left) { position in
                    guard include(lookup(ids[position])) else { return false }
                    remaining -= 1
                    return true
                }
            }
        }
        sampleGroups(genreGroups)
        sampleGroups(artistGroups)
        sample(count: songs.count, budget: limit * 24) { include(songs[$0]) }

        let decades = AIPlaylistPromptHints.decades(in: texts.joined(separator: " "))
        if !decades.isEmpty {
            sample(count: songs.count, budget: limit * 6) { position in
                let song = songs[position]
                guard let year = song.year, decades.contains(where: { $0.contains(year) }) else { return false }
                return include(song)
            }
        }
        return self.songs(in: input, texts: texts, searchIDs: searchIDs, topArtists: topArtists,
                          topSongIDs: topSongIDs, salt: salt, limit: limit, isCancelled: isCancelled)
    }

    private static func interleave(_ lhs: [String], _ rhs: [String]) -> [String] {
        var output: [String] = []
        for index in 0..<max(lhs.count, rhs.count) {
            if index < lhs.count { output.append(lhs[index]) }
            if index < rhs.count { output.append(rhs[index]) }
        }
        return output
    }

    private static func stableHash(_ id: String, salt: UInt64) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037 ^ salt
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return hash
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
        libraryGenres.filter(genreMatcher(texts))
    }

    public static func genreMatcher(_ texts: [String]) -> (String) -> Bool {
        let prompt = PromptText(texts)
        guard !prompt.isEmpty else { return { _ in false } }
        var wanted = Set<String>()
        for group in genreAliases {
            let keys = group.map(SongDiscoveryMatching.key)
            if keys.contains(where: prompt.mentions) { wanted.formUnion(keys) }
        }
        return { genre in
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

/// Retains the best elements seen so far. Supply a tie-breaker when the input order matters.
public struct TopKBuffer<Element> {
    private var heap: [Element] = []
    private let limit: Int
    private let precedes: (Element, Element) -> Bool
    public private(set) var didDiscard = false

    public init(limit: Int, by precedes: @escaping (Element, Element) -> Bool) {
        self.limit = max(0, limit)
        self.precedes = precedes
    }

    public mutating func insert(_ element: Element) {
        if heap.count < limit {
            var child = heap.count
            heap.append(element)
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(heap[parent], element) else { break }
                heap[child] = heap[parent]
                child = parent
            }
            heap[child] = element
            return
        }

        didDiscard = true
        guard let worst = heap.first, precedes(element, worst) else { return }
        var parent = 0
        while parent * 2 + 1 < heap.count {
            var child = parent * 2 + 1
            if child + 1 < heap.count, precedes(heap[child], heap[child + 1]) { child += 1 }
            guard precedes(element, heap[child]) else { break }
            heap[parent] = heap[child]
            parent = child
        }
        heap[parent] = element
    }

    public func sorted() -> [Element] { heap.sorted(by: precedes) }
}
