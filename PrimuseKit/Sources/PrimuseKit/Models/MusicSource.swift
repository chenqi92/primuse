import Foundation
import GRDB
import Network

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
        case .protocol: return PMString("src.category.protocol")
        case .mediaServer: return PMString("src.category.mediaServer")
        case .cloudDrive: return PMString("src.category.cloudDrive")
        case .streaming: return PMString("src.category.streaming")
        case .local: return PMString("src.category.local")
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

    /// Feiniu Music server catalogue (`trim.music`). This is a music-service
    /// source, kept distinct from the legacy `.fnos` NAS placeholder so synced
    /// source records and connector routing never mix the two protocols.
    case fnMusic

    /// 道理鱼音乐原生 API。它仅暴露服务端曲库，不按 Subsonic 协议解释，
    /// 避免将目前只提供 ping 的兼容路由误当成完整 Subsonic 实现。
    case daoliyu

    // Cloud Drives
    case baiduPan
    case aliyunDrive
    case googleDrive
    case oneDrive
    case dropbox
    case drime
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
        case .fnMusic:
            return String(localized: "src.displayName.fnMusic", bundle: Bundle.primuseKit)
        case .daoliyu:
            return String(localized: "src.displayName.daoliyu", bundle: Bundle.primuseKit)
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
        case .drime: return "Drime"
        case .pan115:
            return String(localized: "src.displayName.pan115", bundle: Bundle.primuseKit)
        case .pan123:
            return String(localized: "src.displayName.pan123", bundle: Bundle.primuseKit)
        case .appleMusic: return "Apple Music"
        case .local:
            return PMString("src.displayName.local")
        case .appleMusicLibrary:
            return PMString("src.displayName.appleMusicLibrary")
        }
    }

    public var iconName: String {
        switch self {
        case .synology: return "xserve"
        case .qnap: return "xserve"
        case .ugreen: return "xserve"
        case .fnos: return "xserve"
        case .fnMusic: return "music.note.list"
        case .daoliyu: return "music.note.house"
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
        case .drime: return "cloud.fill"
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
    /// 的全库 `scanSongs(from:)`。媒体服务器(Jellyfin/Emby/Plex)、Subsonic
    /// 系(Navidrome/Airsonic/Gonic)以及飞牛音乐。Apple Music Library 虽也
    /// 整库扫描, 但走 iTunesLibrary 而非 connector "/" 流程, 故不在此列。
    public var isServerLibrary: Bool {
        isMediaServer || isSubsonicFamily || self == .fnMusic || self == .daoliyu
    }

    /// Whether this source exposes a server/file-system operation that really
    /// removes the underlying audio. Read-only catalogue protocols must never
    /// be counted as removable duplicates.
    public var supportsFileDeletion: Bool {
        switch self {
        case .upnp, .subsonic, .navidrome, .airsonic, .gonic, .fnMusic, .daoliyu,
             .appleMusic, .appleMusicLibrary:
            return false
        default:
            return true
        }
    }

    /// Whether scraped cover art and lyrics can be written beside the source
    /// audio file. Read-only catalogues such as DaoLiYu keep scraped assets in
    /// Primuse's local metadata cache instead.
    public var supportsSidecarWriting: Bool {
        switch self {
        case .synology, .smb, .oneDrive, .dropbox, .googleDrive, .baiduPan,
             .aliyunDrive, .pan123, .drime:
            return true
        default:
            return false
        }
    }

    /// True for sources whose "scope" is the whole source itself, with no
    /// per-folder selection step. Drives the Sources UI to show "scan now"
    /// directly instead of a "connect & pick directories" flow.
    public var scansEntireLibrary: Bool {
        switch self {
        case .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic, .fnMusic, .daoliyu: return true   // server-side library
        case .local, .appleMusicLibrary: return true // already scoped by basePath / library
        default: return false
        }
    }

    public var category: SourceCategory {
        switch self {
        case .synology, .qnap, .ugreen, .fnos: return .nas
        case .webdav, .smb, .ftp, .sftp, .nfs, .upnp, .s3: return .protocol
        case .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic, .fnMusic, .daoliyu:
            return .mediaServer
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .drime, .pan115, .pan123: return .cloudDrive
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
        case .fnMusic: return 5666
        case .daoliyu: return 4000
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
        case .drime: return 0
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
        case .fnMusic:
            return useSsl ? 5667 : 5666
        default:
            return defaultPort
        }
    }

    public var defaultSSL: Bool {
        switch self {
        case .synology, .webdav, .s3, .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .drime, .pan115, .pan123: return true
        default: return false
        }
    }

    public var requiresHost: Bool {
        switch self {
        case .local, .appleMusicLibrary, .upnp, .baiduPan, .aliyunDrive,
             .googleDrive, .oneDrive, .dropbox, .drime, .pan115, .pan123, .appleMusic: return false
        default: return true
        }
    }

    /// Address-backed sources whose service can legitimately expose different
    /// LAN and Internet endpoints. Cloud accounts, discovery-only sources and
    /// unpublished vendor placeholders keep their existing single-entry flow.
    public var supportsAdaptiveConnections: Bool {
        switch self {
        case .synology, .qnap, .ugreen, .webdav, .smb, .ftp, .sftp, .nfs, .s3,
             .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic,
             .fnMusic, .daoliyu:
            return true
        default:
            return false
        }
    }

    /// HTTP service prefixes may differ when the public route is exposed by a
    /// reverse proxy. Filesystem roots and shares remain source-wide because a
    /// song path must keep the same identity whichever route is active.
    public var supportsEndpointSpecificPath: Bool {
        switch self {
        case .synology, .qnap, .ugreen, .webdav, .jellyfin, .emby, .plex,
             .subsonic, .navidrome, .airsonic, .gonic,
             .fnMusic, .daoliyu:
            return true
        default:
            return false
        }
    }

    /// Connection URLs that may include a route-specific HTTP prefix. S3 is
    /// intentionally separate from `supportsEndpointSpecificPath`: its legacy
    /// `basePath` stores the bucket, while a reverse-proxy prefix belongs to
    /// the LAN/public endpoint itself.
    public var supportsEndpointPathPrefix: Bool {
        supportsEndpointSpecificPath || self == .s3
    }

    public var supportsVendorRemoteAccess: Bool {
        self == .synology || self == .fnMusic
    }

    public var isCloudDrive: Bool {
        category == .cloudDrive
    }

    public var supportsRangeStreaming: Bool {
        category == .cloudDrive
            || isMediaServer
            || self == .webdav
            || self == .synology
            || self == .qnap
            || self == .ugreen
            || self == .fnos
            || self == .fnMusic
            || self == .daoliyu
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
             .googleDrive, .oneDrive, .dropbox, .drime, .pan115, .pan123, .appleMusic: return false
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
        case .fnMusic:
            return String(localized: "src.subtitle.fnMusic", bundle: Bundle.primuseKit)
        case .daoliyu:
            return String(localized: "src.subtitle.daoliyu", bundle: Bundle.primuseKit)
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
        case .drime: return "Drime API"
        case .pan115:
            return String(localized: "src.subtitle.pan115", bundle: Bundle.primuseKit)
        case .pan123:
            return String(localized: "src.subtitle.pan123", bundle: Bundle.primuseKit)
        case .appleMusic: return "Apple Music"
        case .local:
            return PMString("src.subtitle.local")
        case .appleMusicLibrary:
            return PMString("src.subtitle.appleMusicLibrary")
        }
    }

    public static var groupedByCategory: [(SourceCategory, [MusicSourceType])] {
        SourceCategory.allCases.map { cat in
            (cat, MusicSourceType.allCases.filter { $0.category == cat })
        }
    }
}

/// Decides whether a persisted cloud-sync cursor is still safe to reuse after
/// the app's supported source types change. An older build can consume a
/// CloudKit change for a source type it cannot decode; without a cursor reset,
/// upgrading that device never delivers the skipped record again.
public enum CloudSourceTypeCompatibilityPolicy {
    public enum PersistedStateAction: Equatable, Sendable {
        case preserve
        case resetAndRefetch
    }

    public static var currentFingerprint: String {
        fingerprint(for: MusicSourceType.allCases.map(\.rawValue))
    }

    public static func fingerprint(for rawValues: [String]) -> String {
        Array(Set(rawValues)).sorted().joined(separator: "\u{1F}")
    }

    public static func action(
        storedFingerprint: String?,
        currentFingerprint: String = currentFingerprint
    ) -> PersistedStateAction {
        storedFingerprint == currentFingerprint ? .preserve : .resetAndRefetch
    }
}

/// The source-audio part of a destructive song deletion. Sidecar cleanup is
/// deliberately not represented as a failure here: once the audio is gone (or
/// was already absent), keeping an unplayable library row would be worse than
/// reporting a best-effort sidecar warning.
public enum SourceAudioDeletionStatus: Equatable, Sendable {
    case deleted
    case alreadyMissing
    case failed
}

/// Pure policy shared by row, Now Playing, macOS and duplicate-cleanup entry
/// points. Keeping the decision here makes it impossible for a view to treat a
/// transport error as a successful library deletion.
public enum SourceFileDeletionPolicy {
    public static func shouldShowDeleteAction(for sourceType: MusicSourceType?) -> Bool {
        sourceType?.supportsFileDeletion == true
    }

    public static func shouldRemoveLibraryRecord(
        after audioStatus: SourceAudioDeletionStatus,
        sidecarWarningCount: Int = 0
    ) -> Bool {
        switch audioStatus {
        case .deleted, .alreadyMissing:
            return true
        case .failed:
            return false
        }
    }
}

/// A missing-file error from a multi-file provider request describes at least
/// one path, not necessarily every path in the chunk. Retrying individually is
/// required before any library row can be classified as already missing.
public enum SourceBatchDeletionFailurePolicy {
    public static func shouldRetryIndividually(
        batchCount: Int,
        aggregateErrorIndicatesMissing: Bool
    ) -> Bool {
        batchCount > 1 && aggregateErrorIndicatesMissing
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

    /// Ordered protocol attempts used by the connector. Auto deliberately
    /// prefers v3 for broad NAS compatibility, then falls back to v4.
    public var connectionAttemptOrder: [NFSVersion] {
        switch self {
        case .auto: return [.v3, .v4]
        case .v3: return [.v3]
        case .v4: return [.v4]
        }
    }

    /// Whether a v3-only client can make this mode's first connection attempt.
    /// Auto qualifies because it deliberately starts with v3, but the caller
    /// must not claim that it can perform Auto's v4 fallback.
    public var canStartWithV3OnlyBackend: Bool {
        connectionAttemptOrder.first == .v3
    }

    /// Returns the other protocol only for Auto. This also covers a connector
    /// that is already on v4 and later encounters a path or protocol error.
    public func fallbackVersion(after attemptedVersion: NFSVersion) -> NFSVersion? {
        guard self == .auto else { return nil }

        switch attemptedVersion {
        case .v3: return .v4
        case .v4: return .v3
        case .auto: return nil
        }
    }

    /// Commits a fallback protocol only after its operation has succeeded.
    /// A failed candidate leaves the currently active protocol unchanged so a
    /// retry starts from the same deterministic state.
    public func versionAfterFallback(to candidateVersion: NFSVersion, succeeded: Bool) -> NFSVersion {
        succeeded ? candidateVersion : self
    }
}

// MARK: - Adaptive connection routes

/// Synology QuickConnect and Feiniu FN Connect are remote discovery/relay
/// methods, not ordinary URLs. Only one remote method is active at a time, but
/// both the direct endpoint and vendor identifier remain persisted.
public enum SourceRemoteAccessMode: String, Codable, Sendable, CaseIterable {
    case direct
    case vendor
}

/// A complete address entry. Port and transport belong to the endpoint rather
/// than the source so a LAN service port and a public reverse-proxy port never
/// overwrite each other. `pathPrefix` is used only by HTTP-style source types.
public struct SourceConnectionEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var useSsl: Bool
    public var pathPrefix: String?

    public init(host: String, port: Int, useSsl: Bool, pathPrefix: String? = nil) {
        self.host = host
        self.port = port
        self.useSsl = useSsl
        self.pathPrefix = pathPrefix
    }

    /// Canonicalizes a full URL or `host:port` entry into the fields consumed
    /// by every connector. A URL's explicit scheme, port and path win over the
    /// adjacent form controls; this keeps reverse-proxy URLs working in older
    /// resolvers that only understand a host plus a separate base path.
    public var normalized: SourceConnectionEndpoint {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.isEmpty == false else { return self }

        let components: URLComponents? = {
            if address.contains("://") {
                return URLComponents(string: address)
            }
            return URLComponents(string: "http://\(address)")
        }()
        guard let parsedHost = components?.host, parsedHost.isEmpty == false else {
            var copy = self
            copy.host = address
            copy.pathPrefix = Self.normalizedPath(pathPrefix)
            return copy
        }

        let explicitScheme = address.contains("://")
            ? components?.scheme?.lowercased()
            : nil
        let normalizedSSL: Bool
        switch explicitScheme {
        case "https", "wss", "ftps": normalizedSSL = true
        case "http", "ws", "ftp": normalizedSSL = false
        default: normalizedSSL = useSsl
        }

        let urlPath = Self.normalizedPath(components?.percentEncodedPath.removingPercentEncoding)
        return SourceConnectionEndpoint(
            host: parsedHost,
            port: components?.port ?? port,
            useSsl: normalizedSSL,
            pathPrefix: urlPath ?? Self.normalizedPath(pathPrefix)
        )
    }

    public var isUsable: Bool {
        let endpoint = normalized
        return endpoint.host.isEmpty == false && (1...65_535).contains(endpoint.port)
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false,
              trimmed != "/" else {
            return nil
        }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }
}

/// Persisted multi-route configuration. A filled endpoint is a usable route, and
/// filling both lets the router pick. Empty inactive fields are retained so
/// switching between a public URL and QuickConnect/FN Connect is lossless.
public struct SourceConnectionConfiguration: Codable, Hashable, Sendable {
    public var localEndpoint: SourceConnectionEndpoint?
    public var publicEndpoint: SourceConnectionEndpoint?
    public var remoteAccessMode: SourceRemoteAccessMode
    public var vendorIdentifier: String?

    /// Older sources persisted an explicit local-only / remote-only choice.
    /// It is no longer editable — filling in an address is the choice — but it
    /// is still decoded and re-encoded so an untouched source keeps its exact
    /// behavior, and so a peer device on the previous build does not see its
    /// selection disappear. Cleared on the first save from the new form; drop
    /// this once the previous build is out of circulation.
    public private(set) var legacyRouteRestriction: LegacyRouteRestriction?

    public enum LegacyRouteRestriction: String, Codable, Sendable {
        case localOnly
        case remoteOnly
    }

    public init(
        localEndpoint: SourceConnectionEndpoint? = nil,
        publicEndpoint: SourceConnectionEndpoint? = nil,
        remoteAccessMode: SourceRemoteAccessMode = .direct,
        vendorIdentifier: String? = nil
    ) {
        self.localEndpoint = localEndpoint
        self.publicEndpoint = publicEndpoint
        self.remoteAccessMode = remoteAccessMode
        self.vendorIdentifier = vendorIdentifier
        self.legacyRouteRestriction = nil
    }

    private enum CodingKeys: String, CodingKey {
        case localEndpoint, publicEndpoint, remoteAccessMode, vendorIdentifier
        case preference
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localEndpoint = try c.decodeIfPresent(SourceConnectionEndpoint.self, forKey: .localEndpoint)
        publicEndpoint = try c.decodeIfPresent(SourceConnectionEndpoint.self, forKey: .publicEndpoint)
        remoteAccessMode = try c.decodeIfPresent(
            SourceRemoteAccessMode.self,
            forKey: .remoteAccessMode
        ) ?? .direct
        vendorIdentifier = try c.decodeIfPresent(String.self, forKey: .vendorIdentifier)
        // Decoded as a raw String rather than an enum so an unrecognized value
        // means "no restriction" instead of failing the whole decode.
        switch try c.decodeIfPresent(String.self, forKey: .preference) {
        case "localOnly": legacyRouteRestriction = .localOnly
        case "remoteOnly": legacyRouteRestriction = .remoteOnly
        default: legacyRouteRestriction = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(localEndpoint, forKey: .localEndpoint)
        try c.encodeIfPresent(publicEndpoint, forKey: .publicEndpoint)
        try c.encode(remoteAccessMode, forKey: .remoteAccessMode)
        try c.encodeIfPresent(vendorIdentifier, forKey: .vendorIdentifier)
        switch legacyRouteRestriction {
        case .localOnly: try c.encode("localOnly", forKey: .preference)
        case .remoteOnly: try c.encode("remoteOnly", forKey: .preference)
        case nil: break
        }
    }

    /// The new form always writes an unrestricted configuration: whatever the
    /// user left filled in is what gets used.
    public mutating func clearLegacyRouteRestriction() {
        legacyRouteRestriction = nil
    }
}

public enum SourceConnectionCandidateKind: String, Codable, Hashable, Sendable {
    case localAddress
    case publicAddress
    case vendorRemote
}

/// Runtime-only candidate produced from a persisted configuration.
public struct SourceConnectionCandidate: Hashable, Sendable, Identifiable {
    public let kind: SourceConnectionCandidateKind
    public let endpoint: SourceConnectionEndpoint?
    public let vendorIdentifier: String?

    public init(
        kind: SourceConnectionCandidateKind,
        endpoint: SourceConnectionEndpoint? = nil,
        vendorIdentifier: String? = nil
    ) {
        self.kind = kind
        self.endpoint = endpoint
        self.vendorIdentifier = vendorIdentifier
    }

    public var id: String { kind.rawValue }
}

/// Device-local route memory shared by scanners and stream resolvers. It never
/// enters source JSON or CloudKit; a network-path change invalidates it so the
/// next request can prefer a newly available LAN route again.
public actor SourceConnectionRuntime {
    public static let shared = SourceConnectionRuntime()

    private var activeKinds: [String: SourceConnectionCandidateKind] = [:]
    private var generation: UInt64 = 0

    public init() {
        _ = SourceConnectionNetworkObserver.shared
    }

    public func orderedCandidates(for source: MusicSource) -> [SourceConnectionCandidate] {
        let candidates = source.connectionCandidates
        guard let activeKind = activeKinds[source.id],
              let activeIndex = candidates.firstIndex(where: { $0.kind == activeKind }),
              activeIndex > 0 else {
            return candidates
        }
        var ordered = candidates
        let active = ordered.remove(at: activeIndex)
        ordered.insert(active, at: 0)
        return ordered
    }

    public func activeKind(for sourceID: String) -> SourceConnectionCandidateKind? {
        activeKinds[sourceID]
    }

    public func record(_ kind: SourceConnectionCandidateKind, for sourceID: String) {
        activeKinds[sourceID] = kind
    }

    public func invalidate(sourceID: String) {
        activeKinds.removeValue(forKey: sourceID)
    }

    public func invalidateAll() {
        activeKinds.removeAll()
        generation &+= 1
    }

    public func routeGeneration() -> UInt64 {
        generation
    }
}

private final class SourceConnectionNetworkObserver: @unchecked Sendable {
    static let shared = SourceConnectionNetworkObserver()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.primuse.connection-routes.network")
    private let lock = NSLock()
    private var receivedInitialPath = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    private func handle(_: NWPath) {
        lock.lock()
        let shouldInvalidate = receivedInitialPath
        receivedInitialPath = true
        lock.unlock()

        // NWPathMonitor invokes this handler for path changes. Do not collapse
        // two Wi-Fi paths merely because both are unmetered IPv4: moving from
        // one WLAN to another must make the next operation probe LAN first.
        guard shouldInvalidate else { return }
        Task { await SourceConnectionRuntime.shared.invalidateAll() }
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
    /// Synology connection entry chosen by the user. `nil` means a legacy
    /// direct host record, so snapshots from older releases keep their exact
    /// connection behavior instead of being reinterpreted as QuickConnect.
    public var synologyConnectionMode: SynologyConnectionMode?
    /// Feiniu Music connection entry chosen by the user. `nil` means a legacy
    /// direct address so sources created before FN Connect support never change
    /// transport behavior after an upgrade.
    public var fnMusicConnectionMode: FnMusicConnectionMode?
    /// Optional adaptive routing configuration. A missing value means a legacy
    /// single-route record and is projected without changing its behavior.
    public var connectionConfiguration: SourceConnectionConfiguration?
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
        synologyConnectionMode: SynologyConnectionMode? = nil,
        fnMusicConnectionMode: FnMusicConnectionMode? = nil,
        connectionConfiguration: SourceConnectionConfiguration? = nil,
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
        let resolvedUseSSL = useSsl ?? type.defaultSSL
        self.port = port ?? type.defaultPort(useSsl: resolvedUseSSL)
        self.useSsl = resolvedUseSSL
        self.synologyConnectionMode = synologyConnectionMode
        self.fnMusicConnectionMode = fnMusicConnectionMode
        self.connectionConfiguration = connectionConfiguration
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
        self.synologyConnectionMode = try c.decodeIfPresent(
            SynologyConnectionMode.self,
            forKey: .synologyConnectionMode
        )
        self.fnMusicConnectionMode = try c.decodeIfPresent(
            FnMusicConnectionMode.self,
            forKey: .fnMusicConnectionMode
        )
        self.connectionConfiguration = try c.decodeIfPresent(
            SourceConnectionConfiguration.self,
            forKey: .connectionConfiguration
        )
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

public extension MusicSource {
    /// Legacy Synology sources had only host/port/SSL, so they remain direct.
    var effectiveSynologyConnectionMode: SynologyConnectionMode {
        if let synologyConnectionMode { return synologyConnectionMode }
        return .address
    }

    /// Legacy Feiniu Music sources stored a concrete host/port and remain
    /// direct. Only an explicit new field enables FN Connect resolution.
    var effectiveFnMusicConnectionMode: FnMusicConnectionMode {
        if let fnMusicConnectionMode { return fnMusicConnectionMode }
        return .address
    }

    /// Explicit multi-route data when present; otherwise a compatibility view
    /// over the legacy host/port fields. Legacy direct hosts are classified only
    /// to choose a UI slot — with one candidate their actual behavior is exact.
    var effectiveConnectionConfiguration: SourceConnectionConfiguration? {
        guard type.supportsAdaptiveConnections else { return nil }
        if let connectionConfiguration { return connectionConfiguration }

        let trimmedHost = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedHost.isEmpty == false else {
            return SourceConnectionConfiguration()
        }

        if type == .synology, effectiveSynologyConnectionMode == .quickConnect {
            return SourceConnectionConfiguration(
                remoteAccessMode: .vendor,
                vendorIdentifier: trimmedHost
            )
        }
        if type == .fnMusic, effectiveFnMusicConnectionMode == .fnConnect {
            return SourceConnectionConfiguration(
                remoteAccessMode: .vendor,
                vendorIdentifier: trimmedHost
            )
        }

        let endpoint = SourceConnectionEndpoint(
            host: trimmedHost,
            port: port ?? type.defaultPort(useSsl: useSsl),
            useSsl: useSsl,
            pathPrefix: type.supportsEndpointSpecificPath ? basePath : nil
        ).normalized
        if Self.isLikelyLocalEndpoint(trimmedHost) {
            return SourceConnectionConfiguration(localEndpoint: endpoint)
        }
        return SourceConnectionConfiguration(publicEndpoint: endpoint)
    }

    /// Ordered candidates for a connection attempt: LAN first, then the
    /// selected remote method. A configured route is always eligible — filling
    /// in an address is what enables it. Sources saved before the strategy
    /// picker was removed keep their recorded restriction until next saved.
    var connectionCandidates: [SourceConnectionCandidate] {
        guard let configuration = effectiveConnectionConfiguration else { return [] }

        let local = configuration.localEndpoint.flatMap { endpoint in
            let normalized = endpoint.normalized
            return normalized.isUsable
                ? SourceConnectionCandidate(kind: .localAddress, endpoint: normalized)
                : nil
        }

        let remote: SourceConnectionCandidate?
        if configuration.remoteAccessMode == .vendor, type.supportsVendorRemoteAccess {
            let identifier = configuration.vendorIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            remote = identifier.isEmpty
                ? nil
                : SourceConnectionCandidate(kind: .vendorRemote, vendorIdentifier: identifier)
        } else {
            remote = configuration.publicEndpoint.flatMap { endpoint in
                let normalized = endpoint.normalized
                return normalized.isUsable
                    ? SourceConnectionCandidate(kind: .publicAddress, endpoint: normalized)
                    : nil
            }
        }

        switch configuration.legacyRouteRestriction {
        case .localOnly:
            return [local].compactMap { $0 }
        case .remoteOnly:
            return [remote].compactMap { $0 }
        case nil:
            return [local, remote].compactMap { $0 }
        }
    }

    /// Applies one candidate to the legacy fields consumed by existing source
    /// connectors and stream resolvers. The full configuration stays attached.
    func applyingConnectionCandidate(_ candidate: SourceConnectionCandidate) -> MusicSource {
        var projected = self
        switch candidate.kind {
        case .localAddress, .publicAddress:
            guard let endpoint = candidate.endpoint else { return projected }
            if (type == .synology || type == .qnap || type == .ugreen || type == .s3),
               endpoint.pathPrefix != nil {
                projected.host = Self.addressEmbeddingPath(for: endpoint)
            } else {
                projected.host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            projected.port = endpoint.port
            projected.useSsl = endpoint.useSsl
            if type.supportsEndpointSpecificPath {
                projected.basePath = endpoint.pathPrefix
            }
            if type == .synology { projected.synologyConnectionMode = .address }
            if type == .fnMusic { projected.fnMusicConnectionMode = .address }
        case .vendorRemote:
            guard let identifier = candidate.vendorIdentifier else { return projected }
            projected.host = identifier
            projected.port = type.defaultPort(useSsl: true)
            projected.useSsl = true
            if type == .synology {
                projected.synologyConnectionMode = .quickConnect
            } else if type == .fnMusic {
                projected.fnMusicConnectionMode = .fnConnect
                projected.basePath = nil
            }
        }
        return projected
    }

    /// Keeps legacy consumers functional by mirroring the first enabled route
    /// into host/port/useSsl while retaining every configured route.
    func projectingPreferredConnectionForLegacy() -> MusicSource {
        guard let candidate = connectionCandidates.first else { return self }
        return applyingConnectionCandidate(candidate)
    }

    /// Compact user-facing summary of the currently enabled routes. Each
    /// endpoint always includes its own port so different LAN/WAN mappings are
    /// visible without opening the edit form.
    var connectionSummary: String? {
        guard connectionConfiguration != nil else {
            guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines),
                  host.isEmpty == false else {
                return nil
            }
            guard let port, port > 0 else { return host }
            return Self.endpointDescription(
                SourceConnectionEndpoint(
                    host: host,
                    port: port,
                    useSsl: useSsl,
                    pathPrefix: basePath
                )
            )
        }

        let parts = connectionCandidates.compactMap { candidate -> String? in
            switch candidate.kind {
            case .localAddress:
                guard let endpoint = candidate.endpoint else { return nil }
                return "\(PMString("source_connection_local")) \(Self.endpointDescription(endpoint))"
            case .publicAddress:
                guard let endpoint = candidate.endpoint else { return nil }
                return "\(PMString("source_connection_public_direct")) \(Self.endpointDescription(endpoint))"
            case .vendorRemote:
                guard let identifier = candidate.vendorIdentifier else { return nil }
                let label = type == .synology
                    ? PMString("synology_connection_quickconnect")
                    : PMString("fnmusic_connection_fnconnect")
                return "\(label) \(identifier)"
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func endpointDescription(_ endpoint: SourceConnectionEndpoint) -> String {
        let normalized = endpoint.normalized
        return endpointDescription(
            host: normalized.host,
            port: normalized.port,
            pathPrefix: normalized.pathPrefix
        )
    }

    private static func endpointDescription(
        host: String,
        port: Int,
        pathPrefix: String?
    ) -> String {
        let hostPart = host.contains(":") && host.hasPrefix("[") == false
            ? "[\(host)]"
            : host
        let path = pathPrefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPath = path.isEmpty || path == "/"
            ? ""
            : (path.hasPrefix("/") ? path : "/\(path)")
        return "\(hostPart):\(port)\(normalizedPath)"
    }

    private static func addressEmbeddingPath(for endpoint: SourceConnectionEndpoint) -> String {
        let endpoint = endpoint.normalized
        var components = URLComponents()
        components.scheme = endpoint.useSsl ? "https" : "http"
        components.host = endpoint.host
        components.port = endpoint.port
        components.path = endpoint.pathPrefix ?? ""
        return components.url?.absoluteString ?? endpoint.host
    }

    private static func isLikelyLocalEndpoint(_ rawHost: String) -> Bool {
        let host: String
        if let components = URLComponents(string: rawHost), let parsedHost = components.host {
            host = parsedHost
        } else if let components = URLComponents(string: "http://\(rawHost)"),
                  let parsedHost = components.host {
            host = parsedHost
        } else {
            host = rawHost
        }
        return InsecureHTTPHostPolicy.isLocalNetworkHost(host)
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
