import Foundation

/// 一次保存(歌词、标签、封面)实际落在哪里、为什么。
///
/// 「能不能写」拆成几件互不相干的事分别探测:用户是不是在用 Primuse 里的那一份歌词、这类音乐源本身
/// 收不收、音频文件本身能不能写、歌曲所在的文件夹能不能写、这次连不连得上。写回方式按「歌词保存到」
/// 的设置和这些结果来定,每种情况对应一种说明,说明开头先讲这次落在哪里,后面才是原因。
///
/// 嵌入只需要音频文件可写;歌词文件、封面文件要在歌曲旁边新建或改写,需要所在文件夹可写。
/// 单独添加的文件(没有文件夹授权)因此还能嵌入,只是旁边的文件写不了。
public enum SaveLocationPolicy {
    /// 这次保存落在哪里。
    public enum Destination: String, Sendable, Equatable {
        /// 写进音频文件(嵌入)。
        case audioFile
        /// 写同名歌词文件。
        case lyricsFile
        /// 写同名歌词文件,并嵌入音频文件。
        case lyricsFileAndAudioFile
        /// 交给媒体服务器。
        case mediaServer
        /// 只存在 Primuse(随 iCloud 同步),源上的文件不变。
        case primuseOnly
        /// 这次连不上或探测失败,还不知道。
        case undetermined
    }

    /// 这类音乐源本身收不收修改。
    public enum SourceAcceptance: Sendable, Equatable {
        /// 能改源上的文件:本机文件夹、NAS、网盘等。
        case files
        /// 媒体服务器;有的收歌词,有的不收。
        case mediaServer(writesLyrics: Bool)
        /// Apple Music 资料库、只读源。
        case readOnly
    }

    /// 一个文件或文件夹当前能不能写。
    public enum Access: String, Sendable, Equatable {
        case writable
        /// 没有写入权限。
        case notWritable
        /// 在只读的磁盘或卷上。
        case readOnlyVolume
        /// Primuse 没有它的授权(单独添加的文件所在的文件夹)。
        case noAccess
        /// 没探测(远端源由服务端在写的时候判断)。
        case unknown

        /// 可以试着写:可写,或者要等写的时候才知道。
        public var allowsAttempt: Bool { self == .writable || self == .unknown }
    }

    public enum Reachability: String, Sendable, Equatable {
        case reachable
        /// 这次没连上(超时、连接被占满),源本身可能是可写的。
        case temporarilyUnreachable
        /// 探测失败,源明确不让写。
        case failed
    }

    /// 探测的结果,每一项独立。
    public struct Facts: Sendable, Equatable {
        /// 用户在「歌词来源」里选用了 Primuse 里的那一份(在线歌词、转写文稿、缓存版本)。
        public var usesPrimuseVersion: Bool
        public var source: SourceAcceptance
        public var audioFile: Access
        public var folder: Access
        /// 源和格式参与嵌入(不是 CUE 分轨、串流描述,格式是 MP3 / FLAC / M4A)。
        public var canEmbed: Bool
        public var reachability: Reachability

        public init(
            usesPrimuseVersion: Bool = false,
            source: SourceAcceptance = .files,
            audioFile: Access = .unknown,
            folder: Access = .unknown,
            canEmbed: Bool = false,
            reachability: Reachability = .reachable
        ) {
            self.usesPrimuseVersion = usesPrimuseVersion
            self.source = source
            self.audioFile = audioFile
            self.folder = folder
            self.canEmbed = canEmbed
            self.reachability = reachability
        }
    }

    /// 这次为什么落在这里。`.none` 表示照用户的设置来,没什么要额外说明的。
    public enum Reason: String, Sendable, Equatable {
        case none
        /// 正在用 Primuse 里的那一份歌词。
        case usesPrimuseVersion
        /// 这类音乐源不能改文件。
        case readOnlySource
        /// 媒体服务器不收歌词。
        case serverTakesNoLyrics
        /// 单独添加的文件,没有所在文件夹的权限;要写的又是旁边的文件。
        case noFolderAccess
        /// 单独添加的文件选了「歌词文件并嵌入」:旁边的歌词文件写不了,只嵌入。
        case noFolderAccessEmbedsOnly
        /// 所在文件夹没有写入权限;要写的又是旁边的文件。
        case folderNotWritable
        /// 所在文件夹没有写入权限,选了「歌词文件并嵌入」:只嵌入。
        case folderNotWritableEmbedsOnly
        /// 音频文件没有写入权限。
        case audioFileNotWritable
        /// 在只读的磁盘上。
        case readOnlyVolume
        /// 格式或分轨不能嵌入:歌词写到歌词文件,标签只存在 Primuse。
        case formatCannotEmbed
        case temporarilyUnreachable
        case unavailable
    }

    /// 能一键解决的办法。
    public enum Remedy: String, Sendable, Equatable {
        /// 授权歌曲所在的文件夹。
        case grantFolderAccess
        /// 只把这首歌改成嵌入音频文件。
        case embedThisSong
        /// 把「歌词保存到」改成嵌入音频文件。
        case embedAllSongs
    }

    public struct Plan: Sendable, Equatable {
        public var destination: Destination
        public var reason: Reason
        /// 这首歌实际生效的「歌词保存到」。旁边的文件写不了时,「歌词文件并嵌入」收窄成只嵌入。
        public var embeddingMode: LyricsEmbeddingMode
        public var remedies: [Remedy]

        public init(
            destination: Destination,
            reason: Reason = .none,
            embeddingMode: LyricsEmbeddingMode = .off,
            remedies: [Remedy] = []
        ) {
            self.destination = destination
            self.reason = reason
            self.embeddingMode = embeddingMode
            self.remedies = remedies
        }

        /// 本来要写到源上,这次却只存在 Primuse。
        public var keepsOnlyInPrimuse: Bool { destination == .primuseOnly }
    }

    /// 「歌词保存到」收窄:歌曲旁边的文件写不了时,「歌词文件并嵌入」只剩嵌入那一半。
    /// 「只写歌词文件」不收窄 —— 那是用户明确不要改音频文件。
    public static func effectiveLyricsMode(
        _ mode: LyricsEmbeddingMode,
        folder: Access
    ) -> LyricsEmbeddingMode {
        guard mode == .alongside, !folder.allowsAttempt else { return mode }
        return .embedOnly
    }

    /// 封面同理。
    public static func effectiveCoverMode(
        _ mode: CoverEmbeddingMode,
        folder: Access
    ) -> CoverEmbeddingMode {
        guard mode == .alongside, !folder.allowsAttempt else { return mode }
        return .embedOnly
    }

    /// 歌词这次落在哪里。
    /// - Parameters:
    ///   - requested: 用户为这首歌选的「歌词保存到」(全局设置,或者这首歌单独的)。
    ///   - lyricsDocumentExists: 歌曲旁边已经有歌词文件(「只嵌入」时它照样跟着更新)。
    public static func lyricsPlan(
        _ facts: Facts,
        requested: LyricsEmbeddingMode,
        lyricsDocumentExists: Bool = false
    ) -> Plan {
        if facts.usesPrimuseVersion {
            return Plan(destination: .primuseOnly, reason: .usesPrimuseVersion)
        }
        switch facts.source {
        case .readOnly:
            return Plan(destination: .primuseOnly, reason: .readOnlySource)
        case .mediaServer(let writesLyrics):
            return writesLyrics
                ? Plan(destination: .mediaServer)
                : Plan(destination: .primuseOnly, reason: .serverTakesNoLyrics)
        case .files:
            break
        }
        switch facts.reachability {
        case .reachable: break
        case .temporarilyUnreachable: return Plan(destination: .undetermined, reason: .temporarilyUnreachable)
        case .failed: return Plan(destination: .undetermined, reason: .unavailable)
        }

        let wanted = facts.canEmbed ? requested : .off
        let audioOK = facts.audioFile.allowsAttempt
        let embedRemedies: [Remedy] = facts.canEmbed && audioOK ? [.embedThisSong, .embedAllSongs] : []

        if facts.folder == .readOnlyVolume || facts.audioFile == .readOnlyVolume {
            // 整块盘只读:旁边的文件和音频文件都改不了,换哪种保存方式都一样。
            return Plan(destination: .primuseOnly, reason: .readOnlyVolume)
        }

        if facts.folder.allowsAttempt {
            switch wanted {
            case .off:
                let reason: Reason = requested != .off && !facts.canEmbed ? .formatCannotEmbed : .none
                return Plan(destination: .lyricsFile, reason: reason, embeddingMode: .off)
            case .alongside:
                guard audioOK else {
                    return Plan(destination: .lyricsFile, reason: audioReason(facts.audioFile), embeddingMode: .alongside)
                }
                return Plan(destination: .lyricsFileAndAudioFile, embeddingMode: .alongside)
            case .embedOnly:
                guard audioOK else {
                    return Plan(destination: .primuseOnly, reason: audioReason(facts.audioFile), embeddingMode: .embedOnly)
                }
                return Plan(
                    destination: lyricsDocumentExists ? .lyricsFileAndAudioFile : .audioFile,
                    embeddingMode: .embedOnly
                )
            }
        }

        // 旁边的文件写不了:没有文件夹授权,或文件夹不能写。
        let noAccess = facts.folder == .noAccess
        let grant: [Remedy] = noAccess ? [.grantFolderAccess] : []
        switch wanted {
        case .off:
            return Plan(
                destination: .primuseOnly,
                reason: noAccess ? .noFolderAccess : .folderNotWritable,
                embeddingMode: .off,
                remedies: grant + embedRemedies
            )
        case .alongside, .embedOnly:
            guard audioOK else {
                // 音频文件本身改不了。「歌词文件并嵌入」授权文件夹之后至少能写歌词文件;「只嵌入」授权了也没用。
                let grantHelps = noAccess && wanted == .alongside
                return Plan(
                    destination: .primuseOnly,
                    reason: audioReason(facts.audioFile),
                    embeddingMode: .embedOnly,
                    remedies: grantHelps ? grant : []
                )
            }
            let reason: Reason
            if wanted == .alongside {
                reason = noAccess ? .noFolderAccessEmbedsOnly : .folderNotWritableEmbedsOnly
            } else {
                reason = .none
            }
            return Plan(
                destination: .audioFile,
                reason: reason,
                embeddingMode: .embedOnly,
                remedies: wanted == .alongside ? grant : []
            )
        }
    }

    /// 标签和封面这次落在哪里。嵌入只需要音频文件可写;只收封面文件的格式要写旁边的封面文件。
    public static func tagPlan(
        _ facts: Facts,
        capability: AudioMetadataWritebackCapability
    ) -> Plan {
        switch capability {
        case .localOnly:
            return Plan(destination: .primuseOnly, reason: .readOnlySource)
        case .serverAPI:
            return Plan(destination: .mediaServer)
        case .embedded:
            switch facts.audioFile {
            case .writable, .unknown:
                return Plan(destination: .audioFile)
            case .readOnlyVolume:
                return Plan(destination: .primuseOnly, reason: .readOnlyVolume)
            case .notWritable, .noAccess:
                return Plan(destination: .primuseOnly, reason: .audioFileNotWritable)
            }
        case .sidecarOnly:
            // 文字标签本来就只在 Primuse;换的封面写同名封面文件。
            switch facts.folder {
            case .writable, .unknown:
                return Plan(destination: .primuseOnly, reason: .formatCannotEmbed)
            case .noAccess:
                return Plan(destination: .primuseOnly, reason: .noFolderAccess, remedies: [.grantFolderAccess])
            case .notWritable:
                return Plan(destination: .primuseOnly, reason: .folderNotWritable)
            case .readOnlyVolume:
                return Plan(destination: .primuseOnly, reason: .readOnlyVolume)
            }
        }
    }

    private static func audioReason(_ access: Access) -> Reason {
        access == .readOnlyVolume ? .readOnlyVolume : .audioFileNotWritable
    }
}

extension EmbeddedLyricsCopyPolicy {
    /// 单独为某些歌选的「歌词保存到」,只存在这台设备上。
    public static let songModesDefaultsKey = "primuse.lyrics.embedMode.songs"

    /// 这首歌的「歌词保存到」:单独选过就用它,否则用全局设置。
    public static func mode(forSongID songID: String, defaults: UserDefaults = .standard) -> LyricsEmbeddingMode {
        if let raw = (defaults.dictionary(forKey: songModesDefaultsKey) as? [String: String])?[songID],
           let mode = LyricsEmbeddingMode(rawValue: raw) {
            return mode
        }
        return mode(defaults: defaults)
    }

    /// 只改这首歌;传 nil 回到跟随全局设置。
    public static func setMode(
        _ mode: LyricsEmbeddingMode?,
        forSongID songID: String,
        defaults: UserDefaults = .standard
    ) {
        var stored = defaults.dictionary(forKey: songModesDefaultsKey) as? [String: String] ?? [:]
        stored[songID] = mode?.rawValue
        if stored.isEmpty {
            defaults.removeObject(forKey: songModesDefaultsKey)
        } else {
            defaults.set(stored, forKey: songModesDefaultsKey)
        }
    }
}

/// 标签保存时发现文件在编辑期间被别处改过:重读文件现在的标签之后怎么办。
///
/// 写回只改用户这次改了的字段,其余字段原样留在文件里。所以只看用户改了的那几项:文件里现在的值
/// 还是编辑开始时的值,或者已经就是用户要的值,这一项就不冲突;两样都不是,说明别处也改了这一项,
/// 要用户来选。都不冲突时用新的文件身份自动再写一次。
public enum TagWriteConflictPolicy {
    public struct FieldState<Field: Hashable & Sendable>: Sendable, Equatable {
        public let field: Field
        /// 编辑开始时 Primuse 记的值。
        public let baseline: String?
        /// 文件里现在的值。
        public let fileNow: String?
        /// 用户这次要写的值。
        public let edited: String?

        public init(field: Field, baseline: String?, fileNow: String?, edited: String?) {
            self.field = field
            self.baseline = baseline
            self.fileNow = fileNow
            self.edited = edited
        }
    }

    public enum Resolution<Field: Hashable & Sendable>: Sendable, Equatable {
        /// 别处改的和这次改的不重叠:用新的文件身份再写一次。
        case retry
        /// 这些字段两边都改了,要用户选。
        case askUser([Field])
    }

    /// 只传用户改了的字段。
    public static func resolve<Field>(_ changed: [FieldState<Field>]) -> Resolution<Field> {
        let overlapping = changed.filter { state in
            let now = normalized(state.fileNow)
            return now != normalized(state.baseline) && now != normalized(state.edited)
        }.map(\.field)
        return overlapping.isEmpty ? .retry : .askUser(overlapping)
    }

    /// 封面:用户换了封面、文件又被别处改过,而文件里现在的封面不是用户要的这张,就交给用户选。
    /// 编辑开始时文件里是哪张封面不知道(没有基线),所以「文件变过」就不自动重试。
    public static func coverOverlaps(userChangedCover: Bool, fileCoverIsTheNewOne: Bool) -> Bool {
        userChangedCover && !fileCoverIsTheNewOne
    }

    /// 比较用:去掉首尾空白,空串当没有。
    public static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
