import Foundation

/// 有声书架的首屏快照。冷启动时曲库还在装载、书还没分好组, 书架先按它摆出上次的样子,
/// 分好组后原地换成真的书架。
///
/// 只存画第一屏要的那几十本书: 身份、书名、作者、封面引用、章数和进度。书架照常按分组结果的
/// 规则(在听、书架、已听完、已归档)和用户拖出来的顺序去排, 所以这里按分组的先后存,
/// 留下来的书在页面上落在和真实书架一样的位置。只在本机, 和曲库的启动缓存放在一起。
public struct SpokenWordShelfStartupSnapshot: Codable, Sendable, Equatable {
    /// 字段变了就加一。读到别的版本当没有快照。
    public static let formatVersion = 1

    /// 书封: 第一章的封面引用, 封面缓存凭它就能找到图, 不用等曲库。
    public struct Cover: Codable, Sendable, Hashable {
        public var songID: String
        public var sourceID: String
        public var filePath: String
        public var fileFormat: String
        public var coverArtFileName: String?
        /// 判断是不是播客(方形封面)要用到的两项, 和真实的那首歌一致。
        public var genre: String?
        public var serverLibraryID: String?

        public init(song: Song) {
            songID = song.id
            sourceID = song.sourceID
            filePath = song.filePath
            fileFormat = song.fileFormat.rawValue
            coverArtFileName = song.coverArtFileName
            genre = song.genre
            serverLibraryID = song.serverLibraryID
        }

        /// 只够画封面的一首歌。不能拿去播放: 时长、标题这些都没有。
        public func makeSong() -> Song {
            Song(
                id: songID,
                title: "",
                fileFormat: AudioFormat(rawValue: fileFormat) ?? .mp3,
                filePath: filePath,
                sourceID: sourceID,
                genre: genre,
                coverArtFileName: coverArtFileName,
                serverLibraryID: serverLibraryID
            )
        }
    }

    /// 书架上一本书看得见的那些量。章节本身不存, 一本几百上千章的书也只占一条。
    public struct Book: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var author: String?
        public var chapterCount: Int
        public var finishedCount: Int
        public var totalDuration: TimeInterval
        /// 每一章的时长都知道: 进度按时长算, 也算得出还剩多久。
        public var durationsKnown: Bool
        public var fractionComplete: Double
        public var lastListenedAt: Date?
        /// 「继续」从哪一章起, 和它在书里是第几章(从 0 数)。
        public var resumeItemID: String?
        public var resumeIndex: Int?
        public var resumeHasPosition: Bool
        public var resumeIsFinished: Bool
        public var isArchived: Bool
        public var cover: Cover?

        public init(book: SpokenWordBook, isArchived: Bool, cover: Cover?) {
            id = book.id
            title = book.title
            author = book.author
            chapterCount = book.chapterCount
            finishedCount = book.finishedCount
            totalDuration = book.totalDuration
            durationsKnown = book.items.allSatisfy { $0.duration > 0 }
            fractionComplete = book.fractionComplete
            lastListenedAt = book.lastListenedAt
            let resumeIndex = book.resumeItemID.flatMap { id in book.items.firstIndex { $0.id == id } }
            let resume = resumeIndex.map { book.items[$0] }
            resumeItemID = resume?.id
            self.resumeIndex = resumeIndex
            resumeHasPosition = resume?.position != nil
            resumeIsFinished = resume?.isFinished ?? false
            self.isArchived = isArchived
            self.cover = cover
        }

        public var isFinished: Bool { chapterCount > 0 && finishedCount >= chapterCount }
        public var isInProgress: Bool { lastListenedAt != nil && !isFinished }

        /// 书架画这本书用的 `SpokenWordBook`: 章数、听完几章、总时长、进度、还剩多久、「继续」那一章
        /// 和存下时一样。章节是按这些量拼出来的, 只能拿来画, 不能拿去播放或改进度。
        public func makeBook() -> SpokenWordBook {
            let count = max(0, chapterCount)
            guard count > 0 else {
                return SpokenWordBook(id: id, title: title, author: author, items: [],
                                      resumeItemID: nil, lastListenedAt: lastListenedAt)
            }
            let resume = resumeIndex.flatMap { (0..<count).contains($0) ? $0 : nil }

            // 听完的章: 「继续」那章听完了在重听时算它一章, 其余先排在它前面的章, 不够再往后排。
            var finished = [Bool](repeating: false, count: count)
            var finishedLeft = min(max(0, finishedCount), count)
            if let resume, resumeIsFinished, finishedLeft > 0 {
                finished[resume] = true
                finishedLeft -= 1
            }
            let fillOrder = resume.map { Array(0..<$0) + Array(($0 + 1)..<count) } ?? Array(0..<count)
            for index in fillOrder where finishedLeft > 0 && !finished[index] {
                finished[index] = true
                finishedLeft -= 1
            }
            let finishedTotal = finished.filter { $0 }.count
            let unfinishedTotal = count - finishedTotal

            var durations = [TimeInterval](repeating: 0, count: count)
            var resumePosition: TimeInterval? = resumeHasPosition ? 0 : nil
            let total = max(0, totalDuration)
            let fraction = min(1, max(0, fractionComplete))

            if durationsKnown, total > 0 {
                // 进度按时长算: 听过的那部分 done 摊给听完的章, 没听完的章分剩下的。
                let done = fraction * total
                let minimum = total * 1e-6
                if unfinishedTotal == 0 {
                    durations = Array(repeating: total / Double(count), count: count)
                } else if finishedTotal > 0 {
                    let doneFinished = min(max(done, minimum * Double(finishedTotal)),
                                           total - minimum * Double(unfinishedTotal))
                    for index in 0..<count {
                        durations[index] = finished[index]
                            ? doneFinished / Double(finishedTotal)
                            : (total - doneFinished) / Double(unfinishedTotal)
                    }
                } else if let resume, resumeHasPosition, count > 1 {
                    // 一章都没听完: 听过的都在「继续」那一章里, 那一章拉得比听过的长一些。
                    let heard = min(done, total * (1 - 1e-6))
                    let resumeLength = heard + (total - heard) / 2
                    for index in 0..<count {
                        durations[index] = index == resume
                            ? resumeLength
                            : (total - resumeLength) / Double(count - 1)
                    }
                    resumePosition = heard
                } else if count == 1 {
                    durations[0] = total
                    if resumeHasPosition { resumePosition = done }
                } else {
                    durations = Array(repeating: total / Double(count), count: count)
                }
            } else if count > 1 {
                // 有章节没有时长: 进度是各章进度的平均。没时长的那一章不挑「继续」那章,
                // 「继续」那章的时长拿来放听了的那一截。
                let unknown = (0..<count).first { $0 != resume } ?? 0
                for index in 0..<count where index != unknown {
                    durations[index] = total / Double(count - 1)
                }
                if let resume, resumeHasPosition, !finished[resume], durations[resume] > 0 {
                    let partial = min(max(0, fraction * Double(count) - Double(finishedTotal)), 0.999)
                    resumePosition = partial * durations[resume]
                }
            }

            let finishedAt = lastListenedAt ?? Date(timeIntervalSince1970: 0)
            let sourceID = cover?.sourceID ?? ""
            let items = (0..<count).map { index -> SpokenWordBookItem in
                let isResume = index == resume
                return SpokenWordBookItem(
                    id: isResume ? (resumeItemID ?? Self.placeholderItemID(bookID: id, index: index))
                        : Self.placeholderItemID(bookID: id, index: index),
                    title: "",
                    duration: durations[index],
                    sourceID: sourceID,
                    position: isResume ? resumePosition : nil,
                    positionUpdatedAt: isResume && resumePosition != nil ? lastListenedAt : nil,
                    finishedAt: finished[index] ? finishedAt : nil
                )
            }
            return SpokenWordBook(
                id: id,
                title: title,
                author: author,
                items: items,
                resumeItemID: resume.map { items[$0].id },
                lastListenedAt: lastListenedAt
            )
        }

        /// 拼出来的章节的 id。带一个控制字符, 不会和真实的歌撞上。
        static func placeholderItemID(bookID: String, index: Int) -> String {
            "\u{1}startup:\(bookID)#\(index)"
        }

        /// 书架排版看得见的那部分: 哪本书、叫什么、封面、在哪一节。进度不在里面。
        struct Structure: Hashable, Sendable {
            let id: String
            let title: String
            let author: String?
            let chapterCount: Int
            let isArchived: Bool
            let isFinished: Bool
            let isInProgress: Bool
            let cover: Cover?
        }

        var structure: Structure {
            Structure(id: id, title: title, author: author, chapterCount: chapterCount,
                      isArchived: isArchived, isFinished: isFinished, isInProgress: isInProgress, cover: cover)
        }
    }

    public var version: Int
    /// 写下时开着的音乐源。和现在开着的不一样(删了、停用了、加了源)就不拿来画。
    public var sourceIDs: [String]
    /// 按分组的先后, 归档的也在里面。
    public var books: [Book]

    public init(sourceIDs: Set<String>, books: [Book]) {
        version = Self.formatVersion
        self.sourceIDs = sourceIDs.sorted()
        self.books = books
    }

    public func matches(sourceIDs current: Set<String>) -> Bool {
        sourceIDs == current.sorted()
    }

    /// 书的集合、顺序、书名封面、在哪一节变了才不一样; 只是听书往前走了不算。听书时进度每隔
    /// 十几秒存一次, 拿它比较, 平时就不必跟着重写。
    public struct Structure: Hashable, Sendable {
        let sourceIDs: [String]
        let books: [Book.Structure]
        let listeningOrder: [String]
    }

    public var structure: Structure {
        let listening = books.filter { $0.isInProgress && !$0.isArchived }.sorted {
            let lhs = $0.lastListenedAt ?? .distantPast
            let rhs = $1.lastListenedAt ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        return Structure(sourceIDs: sourceIDs, books: books.map(\.structure), listeningOrder: listening.map(\.id))
    }

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    private struct Header: Decodable {
        let version: Int
    }

    /// 读不懂(坏文件、旧版本或新版本写的)时为 nil。
    public static func decode(_ data: Data) -> SpokenWordShelfStartupSnapshot? {
        let decoder = PropertyListDecoder()
        guard let header = try? decoder.decode(Header.self, from: data),
              header.version == formatVersion,
              let snapshot = try? decoder.decode(SpokenWordShelfStartupSnapshot.self, from: data) else { return nil }
        return snapshot
    }
}

/// 首屏快照留哪些书。
public enum SpokenWordShelfStartupPolicy {
    /// 书架按显示顺序留前面这些: 手机一屏两三排, iPad 横屏七八列、五六排。
    public static let shelfLimit = 72
    /// 「在听」那一排最多摆的本数(首页布局里能调到的上限也在这以内)。
    public static let listeningLimit = 24
    /// 整份最多的本数。已听完、已归档两节要么整节留下, 要么整节不留: 折起来时标题旁写着本数,
    /// 留一半数字就对不上。
    public static let bookLimit = 240

    /// - Parameters:
    ///   - listening: 「在听」那一排, 从前往后。
    ///   - shelf: 书架这一节, 按页面上的顺序。
    ///   - finished: 已听完, 按页面上的顺序。
    ///   - archived: 已归档。
    public static func keptBookIDs(
        listening: [String],
        shelf: [String],
        finished: [String],
        archived: [String],
        shelfLimit: Int = SpokenWordShelfStartupPolicy.shelfLimit,
        listeningLimit: Int = SpokenWordShelfStartupPolicy.listeningLimit,
        bookLimit: Int = SpokenWordShelfStartupPolicy.bookLimit
    ) -> Set<String> {
        var kept = Set(listening.prefix(max(0, listeningLimit)))
        kept.formUnion(shelf.prefix(max(0, shelfLimit)))
        let finishedSet = Set(finished)
        // 书架整节都在里面, 下面的两节才露得出来。
        guard shelf.count <= shelfLimit else { return kept.subtracting(finishedSet) }
        if kept.union(finishedSet).count <= bookLimit {
            kept.formUnion(finishedSet)
            if kept.count + archived.count <= bookLimit {
                kept.formUnion(archived)
            }
        } else {
            // 已听完这一节不留: 在重听的那本也拿掉, 不然它一本撑出一个「已听完 1」。
            kept.subtract(finishedSet)
        }
        return kept
    }
}
