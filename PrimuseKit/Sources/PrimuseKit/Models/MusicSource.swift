import Foundation
import GRDB

// MARK: - Source Categories

public enum SourceCategory: String, Codable, Sendable, CaseIterable {
    case nas
    case `protocol`
    case mediaServer
    case cloudDrive
    case local

    public var displayName: String {
        switch self {
        case .nas: return "NAS"
        case .protocol: return "Protocol"
        case .mediaServer: return "Media Server"
        case .cloudDrive: return "Cloud Drive"
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

    // Cloud Drives
    case baiduPan
    case aliyunDrive
    case googleDrive
    case oneDrive
    case dropbox

    // Local
    case local

    public var displayName: String {
        switch self {
        case .synology: return "Synology"
        case .qnap: return "QNAP"
        case .ugreen: return "绿联 Ugreen"
        case .fnos: return "飞牛 fnOS"
        case .webdav: return "WebDAV"
        case .smb: return "SMB/CIFS"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .nfs: return "NFS"
        case .upnp: return "UPnP/DLNA"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .s3: return "S3"
        case .baiduPan: return "百度网盘"
        case .aliyunDrive: return "阿里云盘"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .dropbox: return "Dropbox"
        case .local: return "Local"
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
        case .s3: return "cloud"
        case .baiduPan: return "cloud.fill"
        case .aliyunDrive: return "cloud.fill"
        case .googleDrive: return "cloud.fill"
        case .oneDrive: return "cloud.fill"
        case .dropbox: return "cloud.fill"
        case .local: return "iphone"
        }
    }

    public var isMediaServer: Bool {
        self == .jellyfin || self == .emby || self == .plex
    }

    public var category: SourceCategory {
        switch self {
        case .synology, .qnap, .ugreen, .fnos: return .nas
        case .webdav, .smb, .ftp, .sftp, .nfs, .upnp, .s3: return .protocol
        case .jellyfin, .emby, .plex: return .mediaServer
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox: return .cloudDrive
        case .local: return .local
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
        case .s3: return 443
        case .baiduPan: return 0
        case .aliyunDrive: return 0
        case .googleDrive: return 0
        case .oneDrive: return 0
        case .dropbox: return 0
        case .local: return 0
        }
    }

    public var defaultSSL: Bool {
        switch self {
        case .synology, .webdav, .s3, .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox: return true
        default: return false
        }
    }

    public var requiresHost: Bool {
        switch self {
        case .local, .upnp, .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox: return false
        default: return true
        }
    }

    public var isCloudDrive: Bool {
        category == .cloudDrive
    }

    public var requiresOAuth: Bool {
        isCloudDrive
    }

    public var requiresCredentials: Bool {
        switch self {
        case .local, .upnp, .nfs, .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox: return false
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
        case .ugreen: return "UGOS"
        case .fnos: return "飞牛 OS"
        case .webdav: return "HTTPS/HTTP"
        case .smb: return "SMB2/3, CIFS"
        case .ftp: return "FTP/FTPS/FTPES"
        case .sftp: return "SSH, Key Auth"
        case .nfs: return "NFSv3/v4"
        case .upnp: return "Auto Discovery"
        case .jellyfin: return "Open Source"
        case .emby: return "Media Server"
        case .plex: return "Plex Media"
        case .s3: return "AWS S3 / MinIO / R2"
        case .baiduPan: return "百度网盘 OAuth"
        case .aliyunDrive: return "阿里云盘 PDS"
        case .googleDrive: return "Google OAuth"
        case .oneDrive: return "Microsoft Graph"
        case .dropbox: return "Dropbox API v2"
        case .local: return "iPhone Storage"
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
        deletedAt: Date? = nil
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
    }
}

extension MusicSource: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "sources" }
}
