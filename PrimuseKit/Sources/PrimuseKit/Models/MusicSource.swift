import Foundation
import GRDB

// MARK: - Source Categories

public enum SourceCategory: String, Codable, Sendable, CaseIterable {
    case nas
    case `protocol`
    case mediaServer
    case cloudDrive
    case streaming
    case local

    public var displayName: String {
        switch self {
        case .nas: return "NAS"
        case .protocol: return "Protocol"
        case .mediaServer: return "Media Server"
        case .cloudDrive: return "Cloud Drive"
        case .streaming: return "Streaming"
        case .local: return "Local"
        }
    }

    public var displayNameFallback: String { displayName }
}

// MARK: - Source Types

public enum MusicSourceType: String, Codable, Sendable, CaseIterable {
    // NAS devices
    case synology
    case qnap
    case ugreen
    case fnos

    // Protocols
    case webdav
    case smb
    case ftp
    case sftp
    case nfs
    case upnp
    case s3

    // Media Servers
    case jellyfin
    case emby
    case plex

    // Server-side music libraries (Subsonic / OpenSubsonic 协议)。
    // 三个常用实现单列, 方便预填各自默认端口/图标; .subsonic 作通用兜底
    // (Ampache / Funkwhale / LMS / Astiga 等其它兼容服务)。底层共用同一个
    // SubsonicSource connector(按服务端 ping 上报的能力自适应)。
    case subsonic
    case navidrome
    case airsonic
    case gonic

    // Cloud Drives
    case baiduPan
    case aliyunDrive
    case googleDrive
    case oneDrive
    case dropbox
    case pan115
    case pan123

    // Streaming
    case appleMusic

    // Local
    case local
    /// macOS-only: reads songs from the user's Apple Music / iTunes library
    /// via `iTunesLibrary.framework`. No host / credentials — gated by the
    /// `com.apple.security.assets.music.read-only` sandbox entitlement and
    /// `NSAppleMusicUsageDescription` privacy prompt.
    case appleMusicLibrary

    /// Vendor-specific NAS integrations that are intentionally unavailable
    /// until their manufacturers publish supported public APIs. The existing
    /// connector scaffolding is not a product-ready implementation.
    public var isAwaitingPublicAPI: Bool {
        switch self {
        case .ugreen, .fnos: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .synology: return "Synology"
        case .qnap: return "QNAP"
        case .ugreen:
            return String(localized: "src.displayName.ugreen", bundle: Bundle.primuseKit)
        case .fnos:
            return String(localized: "src.displayName.fnos", bundle: Bundle.primuseKit)
        case .webdav: return "WebDAV"
        case .smb: return "SMB/CIFS"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .nfs: return "NFS"
        case .upnp: return "UPnP/DLNA"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .subsonic: return "Subsonic"
        case .navidrome: return "Navidrome"
        case .airsonic: return "Airsonic"
        case .gonic: return "gonic"
        case .s3: return "S3"
        case .baiduPan:
            return String(localized: "src.displayName.baiduPan", bundle: Bundle.primuseKit)
        case .aliyunDrive:
            return String(localized: "src.displayName.aliyunDrive", bundle: Bundle.primuseKit)
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .dropbox: return "Dropbox"
        case .pan115:
            return String(localized: "src.displayName.pan115", bundle: Bundle.primuseKit)
        case .pan123:
            return String(localized: "src.displayName.pan123", bundle: Bundle.primuseKit)
        case .appleMusic: return "Apple Music"
        case .local: return "Local"
        case .appleMusicLibrary: return "Apple Music 资料库"
        }
    }

    public var iconName: String {
        switch self {
        case .synology: return "xserve"
        case .qnap: return "xserve"
        case .ugreen: return "xserve"
        case .fnos: return "xserve"
        case .webdav: return "globe"
        case .smb: return "network"
        case .ftp: return "arrow.up.arrow.down.circle"
        case .sftp: return "lock.shield"
        case .nfs: return "externaldrive.connected.to.line.below"
        case .upnp: return "dot.radiowaves.left.and.right"
        case .jellyfin: return "play.rectangle.on.rectangle"
        case .emby: return "play.rectangle.on.rectangle"
        case .plex: return "play.rectangle.on.rectangle"
        case .subsonic, .navidrome, .airsonic, .gonic: return "server.rack"
        case .s3: return "cloud"
        case .baiduPan: return "cloud.fill"
        case .aliyunDrive: return "cloud.fill"
        case .googleDrive: return "cloud.fill"
        case .oneDrive: return "cloud.fill"
        case .dropbox: return "cloud.fill"
        case .pan115: return "cloud.fill"
        case .pan123: return "cloud.fill"
        case .appleMusic: return "music.note"
        case .local: return "iphone"
        case .appleMusicLibrary: return "music.note.house"
        }
    }

    public var isMediaServer: Bool {
        self == .jellyfin || self == .emby || self == .plex
    }

    /// Subsonic / OpenSubsonic 协议族(通用 Subsonic + Navidrome/Airsonic/Gonic),
    /// 共用同一个 SubsonicSource connector。
    public var isSubsonicFamily: Bool {
        switch self {
        case .subsonic, .navidrome, .airsonic, .gonic: return true
        default: return false
        }
    }

    /// 服务端整库源：没有"用户选目录"这一步，靠 "/" 哨兵触发 connector
    /// 的全库 `scanSongs(from:)`。媒体服务器(Jellyfin/Emby/Plex) + Subsonic
    /// 系(Navidrome/Airsonic/Gonic)。Apple Music Library 虽也整库扫描, 但
    /// 走 iTunesLibrary 而非 connector "/" 流程, 故不在此列。
    public var isServerLibrary: Bool {
        isMediaServer || isSubsonicFamily
    }

    /// Whether this source exposes a server/file-system operation that really
    /// removes the underlying audio. Read-only catalogue protocols must never
    /// be counted as removable duplicates.
    public var supportsFileDeletion: Bool {
        switch self {
        case .upnp, .subsonic, .navidrome, .airsonic, .gonic,
             .appleMusic, .appleMusicLibrary:
            return false
        default:
            return true
        }
    }

    /// True for sources whose "scope" is the whole source itself, with no
    /// per-folder selection step. Drives the Sources UI to show "scan now"
    /// directly instead of a "connect & pick directories" flow.
    public var scansEntireLibrary: Bool {
        switch self {
        case .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic: return true   // server-side library
        case .local, .appleMusicLibrary: return true // already scoped by basePath / library
        default: return false
        }
    }

    public var category: SourceCategory {
        switch self {
        case .synology, .qnap, .ugreen, .fnos: return .nas
        case .webdav, .smb, .ftp, .sftp, .nfs, .upnp, .s3: return .protocol
        case .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic: return .mediaServer
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123: return .cloudDrive
        case .appleMusic: return .streaming
        case .local, .appleMusicLibrary: return .local
        }
    }

    public var defaultPort: Int {
        switch self {
        case .synology: return 5001
        case .qnap: return 8080
        case .ugreen: return 9999
        case .fnos: return 5666
        case .webdav: return 443
        case .smb: return 445
        case .ftp: return 21
        case .sftp: return 22
        case .nfs: return 2049
        case .upnp: return 0
        case .jellyfin: return 8096
        case .emby: return 8096
        case .plex: return 32400
        case .subsonic: return 4040   // 原生 Subsonic 默认端口
        case .navidrome: return 4533
        case .airsonic: return 4040
        case .gonic: return 4747
        case .s3: return 443
        case .baiduPan: return 0
        case .aliyunDrive: return 0
        case .googleDrive: return 0
        case .oneDrive: return 0
        case .dropbox: return 0
        case .pan115: return 0
        case .pan123: return 0
        case .appleMusic: return 0
        case .local: return 0
        case .appleMusicLibrary: return 0
        }
    }

    /// Returns the conventional port for the selected transport. WebDAV and
    /// S3 follow HTTP(S), while protocol-specific services keep their fixed
    /// default regardless of the SSL toggle shown by some UIs.
    public func defaultPort(useSsl: Bool) -> Int {
        switch self {
        case .webdav, .s3:
            return useSsl ? 443 : 80
        default:
            return defaultPort
        }
    }

    public var defaultSSL: Bool {
        switch self {
        case .synology, .webdav, .s3, .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123: return true
        default: return false
        }
    }

    public var requiresHost: Bool {
        switch self {
        case .local, .appleMusicLibrary, .upnp, .baiduPan, .aliyunDrive,
             .googleDrive, .oneDrive, .dropbox, .pan115, .pan123, .appleMusic: return false
        default: return true
        }
    }

    public var isCloudDrive: Bool {
        category == .cloudDrive
    }

    public var supportsRangeStreaming: Bool {
        category == .cloudDrive
            || self == .webdav
            || self == .synology
            || self == .qnap
            || self == .ugreen
            || self == .fnos
            || self == .s3
            || self == .smb
            || self == .sftp
            || self == .ftp
            || self == .nfs
            || isSubsonicFamily
    }

    public var requiresOAuth: Bool {
        isCloudDrive
    }

    public var requiresCredentials: Bool {
        switch self {
        case .local, .appleMusicLibrary, .upnp, .nfs, .baiduPan, .aliyunDrive,
             .googleDrive, .oneDrive, .dropbox, .pan115, .pan123, .appleMusic: return false
        default: return true
        }
    }

    /// Protocols that allow connecting without a password:
    /// - SMB: guest / anonymous share access
    /// - WebDAV: server-side anonymous PROPFIND
    /// - FTP: standard "anonymous" login
    public var supportsAnonymous: Bool {
        switch self {
        case .smb, .webdav, .ftp: return true
        default: return false
        }
    }

    public var supports2FA: Bool {
        switch self {
        case .synology, .qnap, .ugreen, .fnos: return true
        default: return false
        }
    }

    public var subtitle: String {
        switch self {
        case .synology: return "DSM 6/7, OTP"
        case .qnap: return "QTS/QuTS"
        case .ugreen, .fnos:
            return String(localized: "src.subtitle.awaitingPublicAPI", bundle: Bundle.primuseKit)
        case .webdav: return "HTTPS/HTTP"
        case .smb: return "SMB2/3, CIFS"
        case .ftp: return "FTP/FTPS/FTPES"
        case .sftp: return "SSH, Key Auth"
        case .nfs: return "NFSv3/v4"
        case .upnp: return "Auto Discovery"
        case .jellyfin: return "Open Source"
        case .emby: return "Media Server"
        case .plex: return "Plex Media"
        case .subsonic: return "Subsonic / OpenSubsonic"
        case .navidrome: return "Navidrome"
        case .airsonic: return "Airsonic / Airsonic-Advanced"
        case .gonic: return "gonic"
        case .s3: return "AWS S3 / MinIO / R2"
        case .baiduPan:
            return String(localized: "src.subtitle.baiduPan", bundle: Bundle.primuseKit)
        case .aliyunDrive:
            return String(localized: "src.subtitle.aliyunDrive", bundle: Bundle.primuseKit)
        case .googleDrive: return "Google OAuth"
        case .oneDrive: return "Microsoft Graph"
        case .dropbox: return "Dropbox API v2"
        case .pan115:
            return String(localized: "src.subtitle.pan115", bundle: Bundle.primuseKit)
        case .pan123:
            return String(localized: "src.subtitle.pan123", bundle: Bundle.primuseKit)
        case .appleMusic: return "Apple Music"
        case .local: return "iPhone Storage"
        case .appleMusicLibrary: return "本机 Apple Music / iTunes"
        }
    }

    public static var groupedByCategory: [(SourceCategory, [MusicSourceType])] {
        SourceCategory.allCases.map { cat in
            (cat, MusicSourceType.allCases.filter { $0.category == cat })
        }
    }
}

// MARK: - Auth Types

public enum SourceAuthType: String, Codable, Sendable {
    case password
    case sshKey
    case apiKey
    case cookie
    case oauth
    case none
}

public enum FTPEncryption: String, Codable, Sendable, CaseIterable {
    case none
    case implicitTLS
    case explicitTLS

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .implicitTLS: return "Implicit TLS (FTPS)"
        case .explicitTLS: return "Explicit TLS (FTPES)"
        }
    }
}

public enum NFSVersion: String, Codable, Sendable, CaseIterable {
    case auto
    case v3
    case v4

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .v3: return "NFSv3"
        case .v4: return "NFSv4"
        }
    }
}

// MARK: - Music Source Entity

public struct MusicSource: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var type: MusicSourceType
    public var host: String?
    public var port: Int?
    public var useSsl: Bool
    public var username: String?
    // Password stored in Keychain
    public var basePath: String?
    public var shareName: String? // SMB share name
    public var exportPath: String? // NFS export path
    public var authType: SourceAuthType
    public var ftpEncryption: FTPEncryption?
    public var nfsVersion: NFSVersion?
    public var autoConnect: Bool
    public var rememberDevice: Bool // for 2FA
    public var deviceId: String? // Synology device memory
    public var lastScannedAt: Date?
    public var isEnabled: Bool
    public var songCount: Int
    public var extraConfig: String? // JSON for type-specific config
    /// Wall-clock time of the most recent user edit to this source. Drives
    /// CloudKit conflict resolution: the side with the larger `modifiedAt`
    /// wins on a conflicting save.
    public var modifiedAt: Date
    /// Soft-delete flag. Hidden from the regular UI but kept around so the
    /// 30-day prune can clear it for good once all devices have converged.
    public var isDeleted: Bool
    public var deletedAt: Date?
    /// Links this mount to its owning `CloudAccount` for OAuth-typed
    /// sources. nil for local / NAS / protocol-typed sources whose
    /// identity is already rooted in host+credentials. Populated by the
    /// OAuth flow when `MusicSourceType.requiresOAuth` is true.
    public var cloudAccountID: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        type: MusicSourceType,
        host: String? = nil,
        port: Int? = nil,
        useSsl: Bool? = nil,
        username: String? = nil,
        basePath: String? = nil,
        shareName: String? = nil,
        exportPath: String? = nil,
        authType: SourceAuthType = .password,
        ftpEncryption: FTPEncryption? = nil,
        nfsVersion: NFSVersion? = nil,
        autoConnect: Bool = false,
        rememberDevice: Bool = false,
        deviceId: String? = nil,
        lastScannedAt: Date? = nil,
        isEnabled: Bool = true,
        songCount: Int = 0,
        extraConfig: String? = nil,
        modifiedAt: Date = Date(),
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        cloudAccountID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port ?? type.defaultPort
        self.useSsl = useSsl ?? type.defaultSSL
        self.username = username
        self.basePath = basePath
        self.shareName = shareName
        self.exportPath = exportPath
        self.authType = authType
        self.ftpEncryption = ftpEncryption
        self.nfsVersion = nfsVersion
        self.autoConnect = autoConnect
        self.rememberDevice = rememberDevice
        self.deviceId = deviceId
        self.lastScannedAt = lastScannedAt
        self.isEnabled = isEnabled
        self.songCount = songCount
        self.extraConfig = extraConfig
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.cloudAccountID = cloudAccountID
    }

    public var supportsRangeStreaming: Bool {
        type.supportsRangeStreaming
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(MusicSourceType.self, forKey: .type)
        self.host = try c.decodeIfPresent(String.self, forKey: .host)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
        self.useSsl = try c.decode(Bool.self, forKey: .useSsl)
        self.username = try c.decodeIfPresent(String.self, forKey: .username)
        self.basePath = try c.decodeIfPresent(String.self, forKey: .basePath)
        self.shareName = try c.decodeIfPresent(String.self, forKey: .shareName)
        self.exportPath = try c.decodeIfPresent(String.self, forKey: .exportPath)
        self.authType = try c.decode(SourceAuthType.self, forKey: .authType)
        self.ftpEncryption = try c.decodeIfPresent(FTPEncryption.self, forKey: .ftpEncryption)
        self.nfsVersion = try c.decodeIfPresent(NFSVersion.self, forKey: .nfsVersion)
        self.autoConnect = try c.decode(Bool.self, forKey: .autoConnect)
        self.rememberDevice = try c.decode(Bool.self, forKey: .rememberDevice)
        self.deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        self.lastScannedAt = try c.decodeIfPresent(Date.self, forKey: .lastScannedAt)
        self.isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        self.songCount = try c.decode(Int.self, forKey: .songCount)
        self.extraConfig = try c.decodeIfPresent(String.self, forKey: .extraConfig)
        // Default to .distantPast so any subsequent edit on this device wins
        // over the migration default — but loses to a fresh remote write.
        self.modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
        self.isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        // decodeIfPresent so old JSON snapshots (pre-CloudAccount) decode
        // cleanly with cloudAccountID = nil. The migration in stage 4
        // will populate this for existing OAuth sources.
        self.cloudAccountID = try c.decodeIfPresent(String.self, forKey: .cloudAccountID)
    }
}

// MARK: - extraConfig accessors

/// `extraConfig` is overloaded. Every source persists its user-selected scan
/// directory list there as a bare `[String]` JSON array — *except* S3, which
/// also has to stash its region. For S3 the slot holds a JSON object
/// `{"region":..., "dirs":[...]}` so region and the dir list coexist; every
/// other type keeps a bare array, and these helpers preserve that so old
/// snapshots stay readable. All scan-dir / S3-region access must go through
/// here so the two layouts never collide again.
public extension MusicSource {
    /// User-selected scan directories persisted in `extraConfig`.
    var scannedDirectories: [String] {
        MusicSource.decodeScannedDirectories(extraConfig, type: type)
    }

    /// S3 region persisted in `extraConfig`; nil for non-S3 sources.
    var s3Region: String? {
        guard type == .s3 else { return nil }
        return MusicSource.decodeS3Config(extraConfig).region
    }

    static func decodeScannedDirectories(_ config: String?, type: MusicSourceType) -> [String] {
        if type == .s3 {
            return decodeS3Config(config).dirs ?? []
        }
        guard let config, let data = config.data(using: .utf8),
              let dirs = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return dirs
    }

    /// Write `dirs` back into `extraConfig`, preserving S3's region key.
    static func encodeScannedDirectories(_ dirs: [String], into config: String?, type: MusicSourceType) -> String? {
        if type == .s3 {
            var cfg = decodeS3Config(config)
            cfg.dirs = dirs
            return cfg.encoded()
        }
        return (try? JSONEncoder().encode(dirs)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Write the S3 `region` into `extraConfig`, preserving the dir list.
    static func encodeS3Region(_ region: String, into config: String?) -> String? {
        var cfg = decodeS3Config(config)
        cfg.region = region
        return cfg.encoded()
    }
}

/// S3's `extraConfig` payload — region plus the scanned-directory list. Both
/// fields are optional so an old `{"region":...}` snapshot (no dirs yet) still
/// decodes cleanly and a partially-filled config never drops the other half.
private struct S3ExtraConfig: Codable {
    var region: String?
    var dirs: [String]?

    func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

private extension MusicSource {
    static func decodeS3Config(_ config: String?) -> S3ExtraConfig {
        guard let config, let data = config.data(using: .utf8),
              let cfg = try? JSONDecoder().decode(S3ExtraConfig.self, from: data) else {
            return S3ExtraConfig()
        }
        return cfg
    }
}

extension MusicSource: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "sources" }
}
