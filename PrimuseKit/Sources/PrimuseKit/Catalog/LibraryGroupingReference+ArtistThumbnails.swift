import Foundation

extension LibraryGroupingReference {
    /// `computeAlbumsAndArtists` 艺人那一段给出的「每个艺人的 id 与 thumbnailPath」,一首一首喂进来算(DL4)。
    ///
    /// iCloud / Apple TV 传输要按艺人 id 和头像引用找艺人封面的缓存文件;以前为此对整库调一次
    /// `computeAlbumsAndArtists`(连专辑、专辑艺人推断一起算,整库的歌还得先全解码在内存里)。这里只留艺人:
    /// 按歌的顺序、每首歌的艺人名顺序登记,头像取这个艺人「第一次出现时的名字」去对每一条出现(按同一顺序)
    /// 找到的第一个,与整库算法逐条相同。内存随艺人数,不随歌数。
    public struct ArtistThumbnailAccumulator {
        public let configuration: ArtistNameConfiguration
        public let unknownArtist: String
        private var artistIDByName: [String: String] = [:]
        private var namesByFields: [DerivedIDMemo.ArtistNames: [String]] = [:]
        private var firstNameByID: [String: String] = [:]
        private var thumbnailByID: [String: String] = [:]

        public init(configuration: ArtistNameConfiguration, unknownArtist: String) {
            self.configuration = configuration
            self.unknownArtist = unknownArtist
        }

        /// 登记过的艺人个数。
        public var artistCount: Int { firstNameByID.count }

        public mutating func include(_ song: Song) {
            let names = artistNames(for: song)
            for name in names {
                let id = artistID(named: name)
                let firstName: String
                if let known = firstNameByID[id] {
                    firstName = known
                } else {
                    firstNameByID[id] = name
                    firstName = name
                }
                guard thumbnailByID[id] == nil else { continue }
                if let automatic = AutomaticArtistArtworkReference.resolve(song.artistArtworkFileName),
                   let artwork = automatic.entry(forArtistName: firstName) {
                    if let path = SourceOwnedArtworkReference.make(
                        sourceID: song.sourceID,
                        reference: artwork.reference,
                        cacheDiscriminator: artwork.cacheDiscriminator
                    ) {
                        thumbnailByID[id] = path
                    }
                } else if names.first.map({ artistID(named: $0) }) == id,
                          let reference = song.artistArtworkFileName,
                          let path = SourceOwnedArtworkReference.make(sourceID: song.sourceID, reference: reference) {
                    thumbnailByID[id] = path
                }
            }
        }

        /// 每个登记过的艺人:id 与头像引用(没有时 nil)。顺序不保证。
        public var artists: [(id: String, thumbnailPath: String?)] {
            firstNameByID.keys.map { ($0, thumbnailByID[$0]) }
        }

        private mutating func artistNames(for song: Song) -> [String] {
            let key = DerivedIDMemo.ArtistNames(artistName: song.artistName, sourceArtistNames: song.sourceArtistNames)
            if let names = namesByFields[key] { return names }
            let names = LibraryGroupingReference.resolvedArtistNames(
                for: song, configuration: configuration, unknownArtist: unknownArtist
            )
            namesByFields[key] = names
            return names
        }

        private mutating func artistID(named name: String) -> String {
            if let id = artistIDByName[name] { return id }
            let id = LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey(name))
            artistIDByName[name] = id
            return id
        }
    }
}
