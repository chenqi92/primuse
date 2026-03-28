import Foundation
import GRDB

// MARK: - Source Categories

public enum SourceCategory: String, Codable, Sendable, CaseIterable {
    case nas
    case `protocol`
    case mediaServer
    case local

    public var displayName: String {
        switch self {
        case .nas: return "NAS"
        case .protocol: return "Protocol"
        case .mediaServer: return "Media Server"
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

    // Media Servers
    case jellyfin
    case emby
    case plex

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
        case .local: return "iphone"
        }
    }

    public var category: SourceCategory {
        switch self {
        case .synology, .qnap, .ugreen, .fnos: return .nas
        case .webdav, .smb, .ftp, .sftp, .nfs, .upnp: return .protocol
        case .jellyfin, .emby, .plex: return .mediaServer
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
        case .local: return 0
        }
    }

    public var defaultSSL: Bool {
        switch self {
        case .synology, .webdav: return true
        default: return false
        }
    }

    public var requiresHost: Bool {
        switch self {
        case .local, .upnp: return false
        default: return true
        }
    }

    public var requiresCredentials: Bool {
        switch self {
        case .local, .upnp, .nfs: return false
        default: return true
        }
    }

    public var supports2FA: Bool {
        switch self {
        case .synology: return true
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
        extraConfig: String? = nil
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
    }
}

extension MusicSource: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "sources" }
}
